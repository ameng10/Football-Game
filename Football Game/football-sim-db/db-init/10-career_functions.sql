-- db-init/10-career_functions.sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =========================================================
-- Utility helpers
-- =========================================================

-- Map numeric grade (9..12) to players.class_year text
CREATE OR REPLACE FUNCTION grade_to_class_year(p_grade INT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_grade
    WHEN 9  THEN 'Freshman'
    WHEN 10 THEN 'Sophomore'
    WHEN 11 THEN 'Junior'
    WHEN 12 THEN 'Senior'
    ELSE 'Freshman'
  END;
$$;

-- Normalize level strings to canonical values from schema (HighSchool/College/Pro)
CREATE OR REPLACE FUNCTION normalize_level(p_level TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN LOWER($1) IN ('hs','highschool','high school') THEN 'HighSchool'
    WHEN LOWER($1) IN ('college','ncaa') THEN 'College'
    WHEN LOWER($1) IN ('pro','nfl','professional') THEN 'Pro'
    ELSE $1
  END;
$$;

-- Clamp int
CREATE OR REPLACE FUNCTION career_clampi(x INT, lo INT, hi INT)
RETURNS INT LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT GREATEST(lo, LEAST(hi, x));
$$;

-- =========================================================
-- Career: create save & player
-- =========================================================
/*
 career_create(
   p_save_name TEXT,
   p_first TEXT,
   p_last  TEXT,
   p_pos   TEXT,     -- must exist in positions.code
   p_stars INT       -- 0..5 (we clamp)
 ) RETURNS UUID (save_id)
 - Ensures a HighSchool league + current season exists
 - Ensures at least 8 HS teams; creates "Your High School" if missing
 - Creates a player + attributes (rating based on stars & pos)
 - Creates career_save, career_player (grade=9), career_state (week 0)
*/
CREATE OR REPLACE FUNCTION career_create(
  p_save_name TEXT,
  p_first TEXT,
  p_last  TEXT,
  p_pos   TEXT,
  p_stars INT
) RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE
  v_save UUID;
  v_league UUID;
  v_year INT := EXTRACT(YEAR FROM CURRENT_DATE)::INT;
  v_season UUID;
  v_team UUID;
  v_player UUID;
  v_stars INT := career_clampi(COALESCE(p_stars,3),0,5);
  v_rating INT;
  v_birth DATE := make_date(v_year-15, 7, 1); -- ~15 y/o freshman
BEGIN
  -- Ensure HS league
  SELECT id INTO v_league FROM leagues WHERE level='HighSchool' LIMIT 1;
  IF v_league IS NULL THEN
    INSERT INTO leagues (name, level) VALUES ('State High School League','HighSchool')
    RETURNING id INTO v_league;
  END IF;

  -- Current season (mark current)
  v_season := get_or_create_season(v_league, v_year, TRUE);

  -- Ensure at least 8 teams (placeholder names if needed)
  PERFORM 1;
  WITH c AS (SELECT COUNT(*) AS n FROM teams WHERE league_id=v_league)
  SELECT CASE WHEN n>=8 THEN 0 ELSE 8-n END FROM c;
  IF (SELECT COUNT(*) FROM teams WHERE league_id=v_league) < 8 THEN
    INSERT INTO teams (league_id, name, city, mascot, prestige)
    SELECT v_league, 'HS Team '||i::text, 'City '||i::text, 'Hawks', 35 + (random()*30)::int
    FROM generate_series(1, 8 - (SELECT COUNT(*) FROM teams WHERE league_id=v_league)) AS i;
  END IF;

  -- Ensure "Your High School" exists and pick it as the player's team
  SELECT id INTO v_team FROM teams WHERE league_id=v_league AND name='Your High School' LIMIT 1;
  IF v_team IS NULL THEN
    INSERT INTO teams (league_id, name, city, mascot, prestige)
    VALUES (v_league, 'Your High School', 'Hometown', 'Warriors', 55)
    RETURNING id INTO v_team;
  END IF;

  -- Base rating by stars & position bias
  v_rating := career_clampi(55 + v_stars*6, 40, 90);
  IF UPPER(p_pos)='QB' THEN v_rating := v_rating + 3; END IF;
  IF UPPER(p_pos) IN ('WR','RB','TE') THEN v_rating := v_rating + 1; END IF;

  -- Create player in public.players
  INSERT INTO players (team_id, first_name, last_name, pos_code, birth_date, stars, rating, potential, class_year, followers)
  VALUES (
    v_team, p_first, p_last, UPPER(p_pos), v_birth, v_stars,
    v_rating, career_clampi(v_rating + 15, 55, 95),
    grade_to_class_year(9), 50
  )
  RETURNING id INTO v_player;

  -- Attributes tuned by position
  INSERT INTO player_attributes (player_id,
    speed, strength, agility, throw_power, throw_accuracy, catching, tackling, awareness, stamina, training_points)
  VALUES (
    v_player,
    /* speed */         career_clampi(45 + v_stars*8 + CASE WHEN UPPER(p_pos) IN ('WR','RB','DB','CB','S') THEN 8 ELSE 0 END, 30, 95),
    /* strength */      career_clampi(45 + v_stars*6 + CASE WHEN UPPER(p_pos) IN ('DL','OL','LB','TE') THEN 8 ELSE 0 END, 30, 95),
    /* agility */       career_clampi(45 + v_stars*7 + CASE WHEN UPPER(p_pos) IN ('WR','RB','DB','CB','S') THEN 6 ELSE 0 END, 30, 95),
    /* throw_power */   career_clampi(35 + v_stars*7 + CASE WHEN UPPER(p_pos)='QB' THEN 20 ELSE 0 END, 20, 95),
    /* throw_accuracy */career_clampi(35 + v_stars*7 + CASE WHEN UPPER(p_pos)='QB' THEN 20 ELSE 0 END, 20, 95),
    /* catching */      career_clampi(35 + v_stars*6 + CASE WHEN UPPER(p_pos) IN ('WR','TE','RB') THEN 15 ELSE 0 END, 20, 95),
    /* tackling */      career_clampi(35 + v_stars*6 + CASE WHEN UPPER(p_pos) IN ('LB','DL','S','CB','DB') THEN 15 ELSE 0 END, 20, 95),
    /* awareness */     career_clampi(40 + v_stars*6, 20, 95),
    /* stamina */       career_clampi(45 + v_stars*5, 20, 95),
    0
  );

  -- Save + career link
  INSERT INTO career_save (name) VALUES (p_save_name) RETURNING id INTO v_save;

  INSERT INTO career_player (save_id, player_id, stage, star_rating, position_goal, grade_level, followers)
  VALUES (v_save, v_player, 'HS', v_stars, UPPER(p_pos), 9, 50);

  INSERT INTO career_state (save_id, season_id, team_id, calendar)
  VALUES (v_save, v_season, v_team, jsonb_build_object('phase','preseason','week',0,'date',CURRENT_DATE));

  INSERT INTO career_event (save_id, kind, payload)
  VALUES (v_save, 'create', jsonb_build_object('player_id',v_player,'pos',UPPER(p_pos),'stars',v_stars));

  RETURN v_save;
END;
$$;

-- =========================================================
-- Career: customize (position/stars) and retune attributes
-- =========================================================
CREATE OR REPLACE FUNCTION career_customize(
  p_save_id UUID,
  p_pos TEXT,
  p_stars INT
) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
  v_player UUID;
  v_stars INT := career_clampi(COALESCE(p_stars,3),0,5);
  v_rating INT;
BEGIN
  SELECT player_id INTO v_player FROM career_player WHERE save_id=p_save_id;
  IF v_player IS NULL THEN RAISE EXCEPTION 'Save % not found', p_save_id; END IF;

  v_rating := career_clampi(55 + v_stars*6 + CASE WHEN UPPER(p_pos)='QB' THEN 3 WHEN UPPER(p_pos) IN ('WR','RB','TE') THEN 1 ELSE 0 END, 40, 92);

  UPDATE players
  SET pos_code = UPPER(p_pos),
      stars = v_stars,
      rating = v_rating,
      potential = career_clampi(v_rating+15, 55, 96)
  WHERE id = v_player;

  UPDATE player_attributes
  SET speed         = career_clampi(speed + CASE WHEN UPPER(p_pos) IN ('WR','RB','DB','CB','S') THEN 3 ELSE 0 END, 30, 99),
      strength      = career_clampi(strength + CASE WHEN UPPER(p_pos) IN ('DL','OL','LB','TE') THEN 3 ELSE 0 END, 30, 99),
      agility       = career_clampi(agility + 2, 30, 99),
      throw_power   = career_clampi(throw_power + CASE WHEN UPPER(p_pos)='QB' THEN 10 ELSE 0 END, 20, 99),
      throw_accuracy= career_clampi(throw_accuracy + CASE WHEN UPPER(p_pos)='QB' THEN 10 ELSE 0 END, 20, 99),
      catching      = career_clampi(catching + CASE WHEN UPPER(p_pos) IN ('WR','TE','RB') THEN 8 ELSE 0 END, 20, 99),
      tackling      = career_clampi(tackling + CASE WHEN UPPER(p_pos) IN ('LB','DL','S','CB','DB') THEN 8 ELSE 0 END, 20, 99),
      awareness     = career_clampi(awareness + 2, 20, 99)
  WHERE player_id = v_player;

  UPDATE career_player
  SET position_goal = UPPER(p_pos),
      star_rating   = v_stars,
      updated_at    = now()
  WHERE save_id = p_save_id;

  INSERT INTO career_event (save_id, kind, payload)
  VALUES (p_save_id, 'customize', jsonb_build_object('pos',UPPER(p_pos),'stars',v_stars));
END;
$$;

-- =========================================================
-- Career: schedule HS season (round robin among HS teams)
-- =========================================================
CREATE OR REPLACE FUNCTION career_schedule_hs_season(p_save_id UUID)
RETURNS UUID  -- returns season_id
LANGUAGE plpgsql AS $$
DECLARE
  v_league UUID;
  v_state RECORD;
  v_year INT := EXTRACT(YEAR FROM CURRENT_DATE)::INT;
  v_season UUID;
BEGIN
  SELECT cs.season_id, cs.team_id INTO v_state FROM career_state cs WHERE cs.save_id=p_save_id;
  IF v_state.season_id IS NULL THEN
    SELECT id INTO v_league FROM leagues WHERE level='HighSchool' LIMIT 1;
    IF v_league IS NULL THEN
      INSERT INTO leagues (name, level) VALUES ('State High School League','HighSchool') RETURNING id INTO v_league;
    END IF;
    v_season := get_or_create_season(v_league, v_year, TRUE);
    UPDATE career_state SET season_id = v_season WHERE save_id=p_save_id;
  ELSE
    v_season := v_state.season_id;
  END IF;

  -- Always (re)build a schedule for this sample
  PERFORM reschedule_round_robin(v_season, TRUE, NULL);
  PERFORM upsert_season_standings(v_season);

  INSERT INTO career_event (save_id, kind, payload)
  VALUES (p_save_id, 'system', jsonb_build_object('scheduled_season', v_season));

  RETURN v_season;
END;
$$;

-- =========================================================
-- Career: simulate current HS week for player's team (and award TP + followers)
-- =========================================================
CREATE OR REPLACE FUNCTION career_simulate_hs_week(p_save_id UUID)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
  v_state RECORD;
  v_week INT;
  v_sid UUID;
  v_tid UUID;
  v_games INT := 0;
  v_tp INT := 0;
  v_followers INT := 0;
  v_player UUID;
  v_pos TEXT;
  v_win BOOLEAN := FALSE;
  g RECORD;
BEGIN
  SELECT cs.season_id AS sid, cs.team_id AS tid, (cs.calendar->>'week')::INT AS wk,
         p.id AS player_id, p.pos_code AS pos
  INTO v_sid, v_tid, v_week, v_player, v_pos
  FROM career_state cs
  JOIN career_player cp ON cp.save_id = cs.save_id
  JOIN players p ON p.id = cp.player_id
  WHERE cs.save_id = p_save_id;

  IF v_sid IS NULL THEN
    RAISE EXCEPTION 'No season bound to save % (run career_schedule_hs_season)', p_save_id;
  END IF;

  -- Simulate all scheduled games for this team at this week
  FOR g IN
    SELECT id, home_team_id, away_team_id FROM games
    WHERE season_id=v_sid AND week=v_week AND played=FALSE
      AND (home_team_id=v_tid OR away_team_id=v_tid)
  LOOP
    PERFORM simulate_game(g.id);
    v_games := v_games + 1;

    -- detect win
    IF (SELECT (home_score > away_score) FROM games WHERE id=g.id) AND g.home_team_id=v_tid THEN
      v_win := TRUE;
    ELSIF (SELECT (away_score > home_score) FROM games WHERE id=g.id) AND g.away_team_id=v_tid THEN
      v_win := TRUE;
    END IF;
  END LOOP;

  -- Award training points based on position and whether we won, modest scale
  v_tp := 6 + (CASE WHEN v_win THEN 4 ELSE 0 END) + (CASE WHEN v_pos='QB' THEN 2 ELSE 1 END);
  v_followers := 10 + CASE WHEN v_win THEN 15 ELSE 5 END;

  -- Log training baseline into training_log (aggregate) and training_session (detail)
  INSERT INTO training_log (player_id, points_earned, method)
  VALUES (v_player, v_tp, 'Simulated');

  INSERT INTO training_session (save_id, mode, score, points)
  VALUES (p_save_id, 'generic', 0, v_tp);

  UPDATE player_attributes
  SET training_points = training_points + v_tp
  WHERE player_id = v_player;

  UPDATE career_player
  SET followers = followers + v_followers,
      updated_at = now()
  WHERE save_id = p_save_id;

  -- Advance week + phase
  UPDATE career_state
  SET calendar = jsonb_set(
      jsonb_set(calendar, '{week}', to_jsonb((calendar->>'week')::INT + 1)),
      '{phase}', to_jsonb(CASE WHEN (calendar->>'phase')='preseason' THEN 'regular' ELSE 'regular' END)
    ),
      updated_at = now()
  WHERE save_id = p_save_id;

  INSERT INTO career_event (save_id, kind, payload)
  VALUES (p_save_id, 'game', jsonb_build_object('week', v_week, 'games', v_games, 'tp_gain', v_tp, 'followers_gain', v_followers, 'win', v_win));

  RETURN jsonb_build_object('week', v_week, 'games', v_games, 'tp_gain', v_tp, 'followers_gain', v_followers, 'win', v_win);
END;
$$;

-- =========================================================
-- Career: mini-game result → training points
-- =========================================================
CREATE OR REPLACE FUNCTION career_award_training(
  p_save_id UUID,
  p_mode TEXT,
  p_score INT,
  p_simulate BOOLEAN DEFAULT FALSE
) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  v_player UUID;
  v_pts INT;
BEGIN
  SELECT player_id INTO v_player FROM career_player WHERE save_id=p_save_id;
  IF v_player IS NULL THEN RAISE EXCEPTION 'Save % not found', p_save_id; END IF;

  v_pts := CASE WHEN p_simulate THEN 6 ELSE GREATEST(3, LEAST(20, 4 + (p_score/5))) END;

  INSERT INTO training_session (save_id, mode, score, points)
  VALUES (p_save_id, COALESCE(p_mode,'generic'), GREATEST(0,p_score), v_pts);

  INSERT INTO training_log (player_id, points_earned, method)
  VALUES (v_player, v_pts, CASE WHEN p_simulate THEN 'Simulated' ELSE 'MiniGame' END);

  UPDATE player_attributes
  SET training_points = training_points + v_pts
  WHERE player_id = v_player;

  INSERT INTO career_event (save_id, kind, payload)
  VALUES (p_save_id, 'train', jsonb_build_object('mode',p_mode,'score',p_score,'points',v_pts,'simulate',p_simulate));

  RETURN v_pts;
END;
$$;

-- =========================================================
-- Career: spend training points → bump an attribute
-- =========================================================
CREATE OR REPLACE FUNCTION career_apply_training(
  p_save_id UUID,
  p_attribute TEXT,
  p_points INT
) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
  v_player UUID;
  v_attr RECORD;
  v_before INT;
  v_after  INT;
  v_left   INT;
  v_field  TEXT := LOWER(p_attribute);
BEGIN
  IF p_points <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','points<=0');
  END IF;

  SELECT player_id INTO v_player FROM career_player WHERE save_id=p_save_id;
  IF v_player IS NULL THEN RETURN jsonb_build_object('ok',false,'error','save not found'); END IF;

  -- fetch current training points
  SELECT training_points INTO v_left FROM player_attributes WHERE player_id=v_player;
  IF v_left IS NULL THEN RETURN jsonb_build_object('ok',false,'error','no attributes row'); END IF;
  IF v_left < p_points THEN RETURN jsonb_build_object('ok',false,'error','insufficient training points'); END IF;

  -- allowed attribute columns
  IF v_field NOT IN ('speed','strength','agility','throw_power','throw_accuracy','catching','tackling','awareness','stamina','rating') THEN
    RETURN jsonb_build_object('ok',false,'error','invalid attribute');
  END IF;

  -- read current value
  EXECUTE format('SELECT %I FROM player_attributes WHERE player_id = $1', v_field)
    INTO v_before
    USING v_player;

  IF v_before IS NULL THEN v_before := 40; END IF;

  -- diminishing returns: higher stat → less gain per point
  v_after := v_before + GREATEST(1, p_points / (8 + v_before/10));
  v_after := career_clampi(v_after, 30, 99);

  -- write back attribute
  EXECUTE format('UPDATE player_attributes SET %I = $1 WHERE player_id = $2', v_field)
    USING v_after, v_player;

  -- deduct points
  UPDATE player_attributes
  SET training_points = training_points - p_points
  WHERE player_id = v_player;

  INSERT INTO career_event (save_id, kind, payload)
  VALUES (p_save_id, 'train', jsonb_build_object('apply_attr', v_field, 'before', v_before, 'after', v_after, 'spent', p_points));

  RETURN jsonb_build_object('ok',true,'attribute',v_field,'before',v_before,'after',v_after);
END;
$$;

-- =========================================================
-- Career: compute HS rankings (class-based)
-- =========================================================
CREATE OR REPLACE FUNCTION career_compute_rankings(p_save_id UUID)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  v_sid UUID; v_pid UUID; v_grade INT; v_class TEXT;
  v_upserted INT := 0;
BEGIN
  SELECT cs.season_id, cp.player_id, cp.grade_level
  INTO v_sid, v_pid, v_grade
  FROM career_state cs
  JOIN career_player cp ON cp.save_id = cs.save_id
  WHERE cs.save_id = p_save_id;

  IF v_sid IS NULL OR v_pid IS NULL THEN
    RAISE EXCEPTION 'Missing season/player for save %', p_save_id;
  END IF;

  v_class := grade_to_class_year(v_grade);

  -- Build pool: existing hs_pool_player for season + ensure the career player is included
  PERFORM 1 FROM hs_pool_player WHERE season_id=v_sid AND player_id=v_pid;
  IF NOT FOUND THEN
    INSERT INTO hs_pool_player (season_id, class_year, player_id)
    VALUES (v_sid, v_grade, v_pid);
  END IF;

  -- Score function: blend rating + key attributes
  WITH pool AS (
    SELECT hp.player_id,
           p.pos_code,
           p.rating,
           pa.speed, pa.agility, pa.awareness, pa.throw_accuracy, pa.throw_power, pa.catching, pa.tackling
    FROM hs_pool_player hp
    JOIN players p ON p.id = hp.player_id
    LEFT JOIN player_attributes pa ON pa.player_id = p.id
    WHERE hp.season_id = v_sid
      AND hp.class_year = v_grade
  ),
  scored AS (
    SELECT player_id,
      (COALESCE(rating,60)) * 0.45
      + (COALESCE(speed,50)) * 0.12
      + (COALESCE(agility,50)) * 0.10
      + (COALESCE(awareness,50)) * 0.10
      + (COALESCE(catching,50)) * CASE WHEN pos_code IN ('WR','TE','RB') THEN 0.10 ELSE 0.02 END
      + (COALESCE(throw_accuracy,50)) * CASE WHEN pos_code = 'QB' THEN 0.12 ELSE 0.02 END
      + (COALESCE(throw_power,50)) * CASE WHEN pos_code = 'QB' THEN 0.08 ELSE 0.02 END
      + (COALESCE(tackling,50)) * CASE WHEN pos_code IN ('LB','DL','S','CB') THEN 0.11 ELSE 0.02 END
      AS score_raw
    FROM pool
  ),
  ranked AS (
    SELECT player_id,
           ROUND(score_raw::numeric,2) AS score,
           ROW_NUMBER() OVER (ORDER BY score_raw DESC) AS rnk
    FROM scored
  )
  INSERT INTO player_ranking (season_id, player_id, class_year, rank_overall, score)
  SELECT v_sid, player_id, v_grade, rnk, score
  FROM ranked
  ON CONFLICT (season_id, player_id)
  DO UPDATE SET rank_overall = EXCLUDED.rank_overall, score = EXCLUDED.score;

  GET DIAGNOSTICS v_upserted = ROW_COUNT;
  RETURN v_upserted;
END;
$$;

-- =========================================================
-- Recruiting: generate college offers for the career player
-- =========================================================
CREATE OR REPLACE FUNCTION career_generate_offers(p_save_id UUID)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  v_pid UUID;
  v_player RECORD;
  v_college_league UUID;
  v_created INT := 0;
BEGIN
  SELECT cp.player_id INTO v_pid FROM career_player cp WHERE cp.save_id=p_save_id;
  IF v_pid IS NULL THEN RAISE EXCEPTION 'Save/player not found'; END IF;

  -- Fetch player details
  SELECT p.id, p.rating, COALESCE(pa.awareness,50) AS awareness
  INTO v_player
  FROM players p
  LEFT JOIN player_attributes pa ON pa.player_id = p.id
  WHERE p.id = v_pid;

  -- Ensure College league exists
  SELECT id INTO v_college_league FROM leagues WHERE level='College' LIMIT 1;
  IF v_college_league IS NULL THEN
    INSERT INTO leagues (name, level) VALUES ('NCAA Generic','College') RETURNING id INTO v_college_league;
  END IF;

  -- Choose up to ~6 colleges ranked by prestige and some randomness
  WITH c AS (
    SELECT id AS team_id, prestige
    FROM teams
    WHERE league_id = v_college_league
    ORDER BY prestige DESC NULLS LAST, random()
    LIMIT 12
  )
  INSERT INTO recruiting_offers (player_id, college_team_id, committed)
  SELECT v_pid, c.team_id, FALSE
  FROM c
  WHERE random() < LEAST(0.9, 0.35 + (v_player.rating-60)/80.0 + (v_player.awareness-50)/200.0)
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_created = ROW_COUNT;
  INSERT INTO career_event (save_id, kind, payload)
  VALUES (p_save_id, 'offer', jsonb_build_object('count', v_created));

  RETURN v_created;
END;
$$;

-- Commit to a college (does not yet advance stage)
CREATE OR REPLACE FUNCTION career_commit_college(p_save_id UUID, p_team_id UUID)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE v_pid UUID;
BEGIN
  SELECT player_id INTO v_pid FROM career_player WHERE save_id=p_save_id;
  IF v_pid IS NULL THEN RAISE EXCEPTION 'Save not found'; END IF;

  UPDATE recruiting_offers
  SET committed = TRUE
  WHERE player_id = v_pid AND college_team_id = p_team_id;

  INSERT INTO career_event (save_id, kind, payload)
  VALUES (p_save_id, 'commit', jsonb_build_object('college_team_id', p_team_id));
END;
$$;

-- Done.
