-- =========================================
-- Helpers
-- =========================================

-- Random integer in [lo, hi]
CREATE OR REPLACE FUNCTION rnd_int(lo INT, hi INT)
RETURNS INT
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT lo + FLOOR(random() * GREATEST(0, hi - lo + 1))::int;
$$;

-- Clamp int to [lo, hi]
CREATE OR REPLACE FUNCTION clampi(x INT, lo INT, hi INT)
RETURNS INT
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT GREATEST(lo, LEAST(hi, x));
$$;

-- Ensure a standings row exists
CREATE OR REPLACE FUNCTION ensure_standing(p_season UUID, p_team UUID)
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO standings (season_id, team_id)
  VALUES (p_season, p_team)
  ON CONFLICT (season_id, team_id) DO NOTHING;
END;
$$;

-- =========================================
-- Team rating snapshots
-- =========================================
-- Weighted team overall from player ratings (favor top players)
CREATE OR REPLACE FUNCTION team_overall_rating(p_team UUID)
RETURNS INT
LANGUAGE sql STABLE AS $$
  WITH ranked AS (
    SELECT rating, ROW_NUMBER() OVER (ORDER BY rating DESC NULLS LAST) AS r
    FROM players
    WHERE team_id = p_team
  ),
  w AS (
    SELECT
      CASE WHEN r = 1 THEN rating * 1.25
           WHEN r <= 5 THEN rating * 1.10
           WHEN r <= 11 THEN rating * 1.00
           ELSE rating * 0.85 END AS wr
    FROM ranked
  )
  SELECT COALESCE(ROUND(AVG(wr))::int, 60) FROM w;
$$;

-- Role-targeted “unit” ratings using attributes when available
CREATE OR REPLACE FUNCTION unit_rating(p_team UUID, p_role TEXT)
RETURNS INT
LANGUAGE sql STABLE AS $$
  -- p_role in ('QB','RB','WR','TE','OL','DL','LB','CB','S','K','P','OFF','DEF')
  WITH base AS (
    SELECT p.id, p.rating,
           pa.speed, pa.agility, pa.awareness, pa.throw_power, pa.throw_accuracy,
           pa.catching, pa.tackling, pa.strength, pa.stamina
    FROM players p
    LEFT JOIN player_attributes pa ON pa.player_id = p.id
    WHERE p.team_id = p_team
  ),
  calc AS (
    SELECT
      CASE
        WHEN p_role = 'QB' THEN COALESCE(throw_power,50)*0.35 + COALESCE(throw_accuracy,50)*0.45 + COALESCE(awareness,50)*0.2
        WHEN p_role = 'RB' THEN COALESCE(speed,50)*0.35 + COALESCE(agility,50)*0.4 + COALESCE(awareness,50)*0.15 + COALESCE(strength,50)*0.1
        WHEN p_role IN ('WR','TE') THEN COALESCE(speed,50)*0.35 + COALESCE(agility,50)*0.25 + COALESCE(catching,50)*0.30 + COALESCE(awareness,50)*0.1
        WHEN p_role IN ('CB','S') THEN COALESCE(speed,50)*0.35 + COALESCE(agility,50)*0.25 + COALESCE(awareness,50)*0.2 + COALESCE(tackling,50)*0.2
        WHEN p_role = 'LB' THEN COALESCE(tackling,50)*0.35 + COALESCE(strength,50)*0.25 + COALESCE(awareness,50)*0.25 + COALESCE(agility,50)*0.15
        WHEN p_role = 'DL' THEN COALESCE(strength,50)*0.45 + COALESCE(tackling,50)*0.35 + COALESCE(awareness,50)*0.2
        WHEN p_role = 'OL' THEN COALESCE(strength,50)*0.45 + COALESCE(awareness,50)*0.3 + COALESCE(stamina,50)*0.25
        WHEN p_role = 'K'  THEN p.rating
        WHEN p_role = 'P'  THEN p.rating
        WHEN p_role = 'OFF' THEN p.rating
        WHEN p_role = 'DEF' THEN p.rating
        ELSE p.rating
      END AS r
    FROM base
  )
  SELECT COALESCE(ROUND(AVG(r))::int, 60) FROM calc;
$$;

-- =========================================
-- Player selection helpers
-- =========================================

-- Best player for a team at a position (by rating)
CREATE OR REPLACE FUNCTION best_player_at(p_team UUID, p_pos TEXT)
RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT id
  FROM players
  WHERE team_id = p_team AND (pos_code = p_pos OR p_pos IN ('WR','TE') AND pos_code IN ('WR','TE'))
  ORDER BY rating DESC NULLS LAST
  LIMIT 1;
$$;

-- =========================================
-- Game Simulator (time-based, attributes impact)
-- =========================================

/*
  simulate_game(p_game_id):
  - Pull game + teams
  - Derive pace and efficiency from team_overall + unit ratings
  - Run a time-based loop (4x 15-minute quarters), stochastic drives (not fixed count)
  - Insert per-game stats for top QB/RB/WR on each team
  - Update game row (scores, played, status='Final')
  - Triggers will aggregate season stats; standings are ensured via ensure_standing
*/
CREATE OR REPLACE FUNCTION simulate_game(p_game_id UUID)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
  g RECORD;
  home_o INT; away_o INT;
  home_qb INT; away_qb INT;
  home_rb INT; away_rb INT;
  home_wr INT; away_wr INT;
  home_def INT; away_def INT;

  quarter INT := 1;
  clock_seconds INT := 900; -- per quarter
  home_score INT := 0;
  away_score INT := 0;

  -- dynamic pace (plays per minute) driven by overall & randomness
  base_pace NUMERIC;
  drive_time INT;
  poss BOOLEAN; -- TRUE = home ball, FALSE = away ball

  -- per-drive outcomes
  yards NUMERIC;
  td_prob NUMERIC;
  fg_prob NUMERIC;

  -- picked players (ids)
  home_qb_id UUID;
  home_rb_id UUID;
  home_wr_id UUID;
  away_qb_id UUID;
  away_rb_id UUID;
  away_wr_id UUID;

  -- per-game stat accumulators
  h_qb_att INT := 0; h_qb_cmp INT := 0; h_qb_yds INT := 0; h_qb_td INT := 0; h_qb_int INT := 0;
  h_rb_att INT := 0; h_rb_yds INT := 0; h_rb_td INT := 0;
  h_wr_rec INT := 0; h_wr_yds INT := 0; h_wr_td INT := 0;

  a_qb_att INT := 0; a_qb_cmp INT := 0; a_qb_yds INT := 0; a_qb_td INT := 0; a_qb_int INT := 0;
  a_rb_att INT := 0; a_rb_yds INT := 0; a_rb_td INT := 0;
  a_wr_rec INT := 0; a_wr_yds INT := 0; a_wr_td INT := 0;

  -- convenience
  season_id UUID;
BEGIN
  -- Load game
  SELECT * INTO g FROM games WHERE id = p_game_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'simulate_game: game % not found', p_game_id;
  END IF;
  IF g.played THEN
    RETURN;
  END IF;

  season_id := g.season_id;

  -- Ensure standings rows exist (safe no-ops if present)
  PERFORM ensure_standing(season_id, g.home_team_id);
  PERFORM ensure_standing(season_id, g.away_team_id);

  -- Ratings
  home_o := team_overall_rating(g.home_team_id);
  away_o := team_overall_rating(g.away_team_id);
  home_qb := unit_rating(g.home_team_id, 'QB');
  away_qb := unit_rating(g.away_team_id, 'QB');
  home_rb := unit_rating(g.home_team_id, 'RB');
  away_rb := unit_rating(g.away_team_id, 'RB');
  home_wr := unit_rating(g.home_team_id, 'WR');
  away_wr := unit_rating(g.away_team_id, 'WR');
  home_def := clampi(ROUND((unit_rating(g.home_team_id, 'DL')*0.35 + unit_rating(g.home_team_id, 'LB')*0.35 + unit_rating(g.home_team_id, 'CB')*0.15 + unit_rating(g.home_team_id,'S')*0.15)::numeric), 30, 99);
  away_def := clampi(ROUND((unit_rating(g.away_team_id, 'DL')*0.35 + unit_rating(g.away_team_id, 'LB')*0.35 + unit_rating(g.away_team_id, 'CB')*0.15 + unit_rating(g.away_team_id,'S')*0.15)::numeric), 30, 99);

  -- Starters
  home_qb_id := best_player_at(g.home_team_id, 'QB');
  home_rb_id := best_player_at(g.home_team_id, 'RB');
  home_wr_id := best_player_at(g.home_team_id, 'WR');

  away_qb_id := best_player_at(g.away_team_id, 'QB');
  away_rb_id := best_player_at(g.away_team_id, 'RB');
  away_wr_id := best_player_at(g.away_team_id, 'WR');

  -- Who receives first: random
  poss := (rnd_int(0,1) = 1);

  -- Pace baseline: ~ 2.2–2.8 drives per quarter per team influenced by team_overall
  base_pace := 2.2 + (home_o + away_o - 120) / 200.0; -- small bump if teams are strong
  base_pace := GREATEST(1.8, LEAST(3.2, base_pace));

  FOR quarter IN 1..4 LOOP
    clock_seconds := 900;

    WHILE clock_seconds > 20 LOOP
      -- variable drive length (60–160s) modulated by pace
      drive_time := clampi( ROUND( (110 + rnd_int(-50, 50)) / base_pace ) , 60, 160 );
      drive_time := LEAST(drive_time, clock_seconds);

      -- Offensive & defensive matchup for this possession
      IF poss THEN
        -- home offense vs away defense
        yards := (home_qb*0.25 + home_rb*0.20 + home_wr*0.20 + home_o*0.15) - (away_def*0.8) + rnd_int(-25, 25);
        td_prob := GREATEST(0.05, LEAST(0.45, (home_qb - away_def)/120.0 + 0.18));
        fg_prob := GREATEST(0.05, LEAST(0.35, (home_o - away_def)/160.0 + 0.10));
      ELSE
        yards := (away_qb*0.25 + away_rb*0.20 + away_wr*0.20 + away_o*0.15) - (home_def*0.8) + rnd_int(-25, 25);
        td_prob := GREATEST(0.05, LEAST(0.45, (away_qb - home_def)/120.0 + 0.18));
        fg_prob := GREATEST(0.05, LEAST(0.35, (away_o - home_def)/160.0 + 0.10));
      END IF;

      -- Decide outcome: TD, FG, or nothing (punt/turnover)
      IF random() < td_prob THEN
        IF poss THEN
          home_score := home_score + 7;
          -- QB line (passing TD heavy), RB/WR shares
          h_qb_att := h_qb_att + rnd_int(3,6);
          h_qb_cmp := h_qb_cmp + rnd_int(2,5);
          h_qb_yds := h_qb_yds + rnd_int(15,40);
          h_qb_td  := h_qb_td + 1;

          IF random() < 0.45 THEN
            h_wr_rec := h_wr_rec + rnd_int(1,2);
            h_wr_yds := h_wr_yds + rnd_int(10,25);
            h_wr_td  := h_wr_td + 1;
          ELSE
            h_rb_att := h_rb_att + rnd_int(1,3);
            h_rb_yds := h_rb_yds + rnd_int(5,15);
            h_rb_td  := h_rb_td + 1;
          END IF;
        ELSE
          away_score := away_score + 7;

          a_qb_att := a_qb_att + rnd_int(3,6);
          a_qb_cmp := a_qb_cmp + rnd_int(2,5);
          a_qb_yds := a_qb_yds + rnd_int(15,40);
          a_qb_td  := a_qb_td + 1;

          IF random() < 0.45 THEN
            a_wr_rec := a_wr_rec + rnd_int(1,2);
            a_wr_yds := a_wr_yds + rnd_int(10,25);
            a_wr_td  := a_wr_td + 1;
          ELSE
            a_rb_att := a_rb_att + rnd_int(1,3);
            a_rb_yds := a_rb_yds + rnd_int(5,15);
            a_rb_td  := a_rb_td + 1;
          END IF;
        END IF;

      ELSIF random() < fg_prob THEN
        IF poss THEN
          home_score := home_score + 3;
        ELSE
          away_score := away_score + 3;
        END IF;

        -- small generic yardage
        IF poss THEN
          h_qb_att := h_qb_att + rnd_int(2,4);
          h_qb_cmp := h_qb_cmp + rnd_int(1,3);
          h_qb_yds := h_qb_yds + rnd_int(8,20);
          IF random() < 0.08 THEN h_qb_int := h_qb_int + 1; END IF;
          h_rb_att := h_rb_att + rnd_int(1,2);
          h_rb_yds := h_rb_yds + rnd_int(3,8);
          h_wr_rec := h_wr_rec + rnd_int(1,2);
          h_wr_yds := h_wr_yds + rnd_int(6,12);
        ELSE
          a_qb_att := a_qb_att + rnd_int(2,4);
          a_qb_cmp := a_qb_cmp + rnd_int(1,3);
          a_qb_yds := a_qb_yds + rnd_int(8,20);
          IF random() < 0.08 THEN a_qb_int := a_qb_int + 1; END IF;
          a_rb_att := a_rb_att + rnd_int(1,2);
          a_rb_yds := a_rb_yds + rnd_int(3,8);
          a_wr_rec := a_wr_rec + rnd_int(1,2);
          a_wr_yds := a_wr_yds + rnd_int(6,12);
        END IF;

      ELSE
        -- empty drive; maybe turnover hurts QB stats a bit
        IF poss THEN
          IF random() < 0.10 THEN h_qb_att := h_qb_att + 1; h_qb_int := h_qb_int + 1; END IF;
        ELSE
          IF random() < 0.10 THEN a_qb_att := a_qb_att + 1; a_qb_int := a_qb_int + 1; END IF;
        END IF;
      END IF;

      -- Consume time and swap possession
      clock_seconds := clock_seconds - drive_time;
      poss := NOT poss;
    END WHILE;
  END LOOP;

  -- Update game row
  UPDATE games
  SET home_score = home_score,
      away_score = away_score,
      status = 'Final',
      played = TRUE
  WHERE id = p_game_id;

  -- Insert per-game stats for top skill players (if present)
  IF home_qb_id IS NOT NULL THEN
    INSERT INTO game_stats (game_id, player_id, pass_attempts, pass_completions, pass_yards, pass_tds, interceptions)
    VALUES (p_game_id, home_qb_id, h_qb_att, h_qb_cmp, GREATEST(0,h_qb_yds), h_qb_td, h_qb_int);
  END IF;
  IF home_rb_id IS NOT NULL THEN
    INSERT INTO game_stats (game_id, player_id, rush_attempts, rush_yards, rush_tds)
    VALUES (p_game_id, home_rb_id, h_rb_att, GREATEST(0,h_rb_yds), h_rb_td);
  END IF;
  IF home_wr_id IS NOT NULL THEN
    INSERT INTO game_stats (game_id, player_id, receptions, rec_yards, rec_tds)
    VALUES (p_game_id, home_wr_id, h_wr_rec, GREATEST(0,h_wr_yds), h_wr_td);
  END IF;

  IF away_qb_id IS NOT NULL THEN
    INSERT INTO game_stats (game_id, player_id, pass_attempts, pass_completions, pass_yards, pass_tds, interceptions)
    VALUES (p_game_id, away_qb_id, a_qb_att, a_qb_cmp, GREATEST(0,a_qb_yds), a_qb_td, a_qb_int);
  END IF;
  IF away_rb_id IS NOT NULL THEN
    INSERT INTO game_stats (game_id, player_id, rush_attempts, rush_yards, rush_tds)
    VALUES (p_game_id, away_rb_id, a_rb_att, GREATEST(0,a_rb_yds), a_rb_td);
  END IF;
  IF away_wr_id IS NOT NULL THEN
    INSERT INTO game_stats (game_id, player_id, receptions, rec_yards, rec_tds)
    VALUES (p_game_id, away_wr_id, a_wr_rec, GREATEST(0,a_wr_yds), a_wr_td);
  END IF;
END;
$$;

-- =========================================
-- Batch simulators
-- =========================================

-- Simulate a specific week of a season
CREATE OR REPLACE FUNCTION simulate_week(p_season_id UUID, p_week INT)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  rec RECORD;
  cnt INT := 0;
BEGIN
  FOR rec IN
    SELECT id FROM games
    WHERE season_id = p_season_id
      AND week = p_week
      AND played = FALSE
    ORDER BY date NULLS LAST, id
  LOOP
    PERFORM simulate_game(rec.id);
    cnt := cnt + 1;
  END LOOP;
  RETURN cnt;
END;
$$;

-- Simulate all remaining games in a season
CREATE OR REPLACE FUNCTION simulate_season(p_season_id UUID)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  rec RECORD;
  cnt INT := 0;
BEGIN
  FOR rec IN
    SELECT id FROM games
    WHERE season_id = p_season_id
      AND played = FALSE
    ORDER BY week, date NULLS LAST, id
  LOOP
    PERFORM simulate_game(rec.id);
    cnt := cnt + 1;
  END LOOP;
  RETURN cnt;
END;
$$;
