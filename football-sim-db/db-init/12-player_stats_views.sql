-- db-init/12-player_stats_views.sql
SET client_min_messages = NOTICE;

-- =========================================================
-- Utility: Safe division (NUMERIC) to avoid /0
-- =========================================================
CREATE OR REPLACE FUNCTION safe_div(n NUMERIC, d NUMERIC, z NUMERIC DEFAULT 0)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE WHEN d IS NULL OR d = 0 THEN z ELSE n/d END;
$$;

-- =========================================================
-- 1) Per-game box scores (one row per player per game)
-- =========================================================
CREATE OR REPLACE VIEW v_game_box_player AS
SELECT
  gs.id                AS game_stat_id,
  gs.game_id,
  g.season_id,
  g.week,
  g.date,
  g.status,
  g.played,
  gs.player_id,
  p.first_name,
  p.last_name,
  p.pos_code,
  p.team_id,
  t.name               AS team_name,
  CASE
    WHEN p.team_id = g.home_team_id THEN at.name
    ELSE ht.name
  END                  AS opponent_name,
  CASE
    WHEN p.team_id = g.home_team_id THEN 'H' ELSE 'A'
  END                  AS home_away,
  g.home_team_id, g.away_team_id,
  g.home_score, g.away_score,
  -- Outcome from player's team perspective
  CASE
    WHEN p.team_id = g.home_team_id AND g.home_score > g.away_score THEN 'W'
    WHEN p.team_id = g.away_team_id AND g.away_score > g.home_score THEN 'W'
    WHEN g.home_score = g.away_score THEN 'T'
    ELSE 'L'
  END                  AS result,
  -- Basic lines
  gs.pass_attempts, gs.pass_completions, gs.pass_yards, gs.pass_tds, gs.interceptions,
  gs.rush_attempts, gs.rush_yards, gs.rush_tds,
  gs.receptions, gs.rec_yards, gs.rec_tds,
  gs.tackles, gs.sacks, gs.forced_fumbles, gs.fumbles_recovered,
  gs.field_goals_made, gs.field_goals_attempted,
  gs.punts, gs.punt_yards,
  -- Simple derived
  safe_div(gs.pass_completions::numeric, NULLIF(gs.pass_attempts,0), 0)::numeric(6,3) AS comp_pct,
  safe_div(gs.pass_yards::numeric, NULLIF(gs.pass_attempts,0), 0)::numeric(6,3)       AS pass_ypa,
  safe_div(gs.rush_yards::numeric, NULLIF(gs.rush_attempts,0), 0)::numeric(6,3)       AS rush_ypc,
  safe_div(gs.rec_yards::numeric, NULLIF(gs.receptions,0), 0)::numeric(6,3)           AS rec_ypr
FROM game_stats gs
JOIN games g   ON g.id = gs.game_id
JOIN players p ON p.id = gs.player_id
JOIN teams t   ON t.id = p.team_id
JOIN teams ht  ON ht.id = g.home_team_id
JOIN teams at  ON at.id = g.away_team_id;

CREATE INDEX IF NOT EXISTS idx_v_game_box_player_game ON game_stats(game_id);
CREATE INDEX IF NOT EXISTS idx_v_game_box_player_player ON game_stats(player_id);

-- =========================================================
-- 2) Player game log (ordered by week/date)
-- =========================================================
CREATE OR REPLACE VIEW v_player_game_log AS
SELECT
  v.player_id,
  v.first_name, v.last_name, v.pos_code,
  v.team_id, v.team_name,
  v.game_id, v.season_id, v.week, v.date, v.home_away, v.opponent_name, v.result,
  v.pass_attempts, v.pass_completions, v.pass_yards, v.pass_tds, v.interceptions,
  v.rush_attempts, v.rush_yards, v.rush_tds,
  v.receptions, v.rec_yards, v.rec_tds,
  v.tackles, v.sacks, v.forced_fumbles, v.fumbles_recovered,
  v.field_goals_made, v.field_goals_attempted,
  v.punts, v.punt_yards,
  v.comp_pct, v.pass_ypa, v.rush_ypc, v.rec_ypr
FROM v_game_box_player v
ORDER BY v.date NULLS LAST, v.week, v.game_id;

-- =========================================================
-- 3) Season totals per player (already stored) + derived metrics
-- =========================================================
CREATE OR REPLACE VIEW v_player_season_totals AS
SELECT
  s.player_id,
  p.first_name, p.last_name, p.pos_code,
  p.team_id, t.name AS team_name,
  s.season_id, se.year AS season_year,
  s.games_played,
  s.pass_attempts, s.pass_completions, s.pass_yards, s.pass_tds, s.interceptions,
  s.rush_attempts, s.rush_yards, s.rush_tds,
  s.receptions, s.rec_yards, s.rec_tds,
  s.tackles, s.sacks, s.forced_fumbles, s.fumbles_recovered,
  s.field_goals_made, s.field_goals_attempted, s.punts, s.punt_yards,
  -- rates
  safe_div(s.pass_completions::numeric, NULLIF(s.pass_attempts,0), 0)::numeric(6,3) AS comp_pct,
  safe_div(s.pass_yards::numeric, NULLIF(s.pass_attempts,0), 0)::numeric(6,3)       AS pass_ypa,
  safe_div(s.rush_yards::numeric, NULLIF(s.rush_attempts,0), 0)::numeric(6,3)       AS rush_ypc,
  safe_div(s.rec_yards::numeric, NULLIF(s.receptions,0), 0)::numeric(6,3)           AS rec_ypr,
  -- NFL-style passer rating (approx; capped 0..158.3)
  GREATEST(0, LEAST(2.375, safe_div(s.pass_completions::numeric, NULLIF(s.pass_attempts,0), 0) - 0.3) * 5)::numeric(6,3) AS pr_a,
  GREATEST(0, LEAST(2.375, safe_div(s.pass_yards::numeric, NULLIF(s.pass_attempts,0), 0) - 3) * 0.25)::numeric(6,3)     AS pr_b,
  GREATEST(0, LEAST(2.375, safe_div(s.pass_tds::numeric, NULLIF(s.pass_attempts,0), 0) * 20))::numeric(6,3)             AS pr_c,
  GREATEST(0, LEAST(2.375, 2.375 - safe_div(s.interceptions::numeric, NULLIF(s.pass_attempts,0), 0) * 25))::numeric(6,3) AS pr_d,
  ROUND( ( ( GREATEST(0, LEAST(2.375, safe_div(s.pass_completions::numeric, NULLIF(s.pass_attempts,0), 0) - 0.3) * 5)
            + GREATEST(0, LEAST(2.375, safe_div(s.pass_yards::numeric, NULLIF(s.pass_attempts,0), 0) - 3) * 0.25)
            + GREATEST(0, LEAST(2.375, safe_div(s.pass_tds::numeric, NULLIF(s.pass_attempts,0), 0) * 20))
            + GREATEST(0, LEAST(2.375, 2.375 - safe_div(s.interceptions::numeric, NULLIF(s.pass_attempts,0), 0) * 25))
           ) / 6 * 100 )::numeric, 1) AS passer_rating,
  -- ANY/A (Adjusted Net Yards per Attempt): (PassYds + 20*TD - 45*INT) / (Att)
  safe_div( (s.pass_yards + 20*s.pass_tds - 45*s.interceptions)::numeric,
            NULLIF(s.pass_attempts,0), 0)::numeric(8,3) AS any_a
FROM season_stats s
JOIN players p ON p.id = s.player_id
LEFT JOIN teams t ON t.id = p.team_id
JOIN seasons se ON se.id = s.season_id;

CREATE INDEX IF NOT EXISTS idx_season_totals_season ON season_stats(season_id);
CREATE INDEX IF NOT EXISTS idx_season_totals_player ON season_stats(player_id);

-- =========================================================
-- 4) Career totals per player (sum across seasons)
-- =========================================================
CREATE OR REPLACE VIEW v_player_career_totals AS
SELECT
  s.player_id,
  p.first_name, p.last_name, p.pos_code,
  p.team_id, t.name AS last_known_team,
  COUNT(DISTINCT s.season_id) AS seasons_played,
  SUM(s.games_played)         AS games_played,
  SUM(s.pass_attempts)        AS pass_attempts,
  SUM(s.pass_completions)     AS pass_completions,
  SUM(s.pass_yards)           AS pass_yards,
  SUM(s.pass_tds)             AS pass_tds,
  SUM(s.interceptions)        AS interceptions,
  SUM(s.rush_attempts)        AS rush_attempts,
  SUM(s.rush_yards)           AS rush_yards,
  SUM(s.rush_tds)             AS rush_tds,
  SUM(s.receptions)           AS receptions,
  SUM(s.rec_yards)            AS rec_yards,
  SUM(s.rec_tds)              AS rec_tds,
  SUM(s.tackles)              AS tackles,
  SUM(s.sacks)                AS sacks,
  SUM(s.forced_fumbles)       AS forced_fumbles,
  SUM(s.fumbles_recovered)    AS fumbles_recovered,
  SUM(s.field_goals_made)     AS field_goals_made,
  SUM(s.field_goals_attempted)AS field_goals_attempted,
  SUM(s.punts)                AS punts,
  SUM(s.punt_yards)           AS punt_yards,
  -- derived
  safe_div(SUM(s.pass_completions)::numeric, NULLIF(SUM(s.pass_attempts),0),0)::numeric(6,3) AS comp_pct,
  safe_div(SUM(s.pass_yards)::numeric, NULLIF(SUM(s.pass_attempts),0),0)::numeric(6,3)       AS pass_ypa,
  safe_div(SUM(s.rush_yards)::numeric, NULLIF(SUM(s.rush_attempts),0),0)::numeric(6,3)       AS rush_ypc,
  safe_div(SUM(s.rec_yards)::numeric, NULLIF(SUM(s.receptions),0),0)::numeric(6,3)           AS rec_ypr,
  safe_div( (SUM(s.pass_yards) + 20*SUM(s.pass_tds) - 45*SUM(s.interceptions))::numeric,
            NULLIF(SUM(s.pass_attempts),0), 0)::numeric(8,3) AS any_a_career
FROM season_stats s
JOIN players p ON p.id = s.player_id
LEFT JOIN teams t ON t.id = p.team_id
GROUP BY s.player_id, p.first_name, p.last_name, p.pos_code, p.team_id, t.name;

-- =========================================================
-- 5) Player splits (home/away & win/loss) per season
-- =========================================================
CREATE OR REPLACE VIEW v_player_splits_home_away AS
SELECT
  v.player_id,
  v.first_name, v.last_name, v.pos_code,
  v.season_id,
  SUM(CASE WHEN v.home_away='H' THEN 1 ELSE 0 END) AS games_home,
  SUM(CASE WHEN v.home_away='A' THEN 1 ELSE 0 END) AS games_away,
  -- Passing
  SUM(CASE WHEN v.home_away='H' THEN v.pass_attempts ELSE 0 END) AS pass_att_home,
  SUM(CASE WHEN v.home_away='H' THEN v.pass_completions ELSE 0 END) AS pass_cmp_home,
  SUM(CASE WHEN v.home_away='H' THEN v.pass_yards ELSE 0 END) AS pass_yds_home,
  SUM(CASE WHEN v.home_away='H' THEN v.pass_tds ELSE 0 END) AS pass_td_home,
  SUM(CASE WHEN v.home_away='H' THEN v.interceptions ELSE 0 END) AS int_home,
  SUM(CASE WHEN v.home_away='A' THEN v.pass_attempts ELSE 0 END) AS pass_att_away,
  SUM(CASE WHEN v.home_away='A' THEN v.pass_completions ELSE 0 END) AS pass_cmp_away,
  SUM(CASE WHEN v.home_away='A' THEN v.pass_yards ELSE 0 END) AS pass_yds_away,
  SUM(CASE WHEN v.home_away='A' THEN v.pass_tds ELSE 0 END) AS pass_td_away,
  SUM(CASE WHEN v.home_away='A' THEN v.interceptions ELSE 0 END) AS int_away,
  -- Rushing
  SUM(CASE WHEN v.home_away='H' THEN v.rush_attempts ELSE 0 END) AS rush_att_home,
  SUM(CASE WHEN v.home_away='H' THEN v.rush_yards ELSE 0 END) AS rush_yds_home,
  SUM(CASE WHEN v.home_away='H' THEN v.rush_tds ELSE 0 END) AS rush_td_home,
  SUM(CASE WHEN v.home_away='A' THEN v.rush_attempts ELSE 0 END) AS rush_att_away,
  SUM(CASE WHEN v.home_away='A' THEN v.rush_yards ELSE 0 END) AS rush_yds_away,
  SUM(CASE WHEN v.home_away='A' THEN v.rush_tds ELSE 0 END) AS rush_td_away,
  -- Receiving
  SUM(CASE WHEN v.home_away='H' THEN v.receptions ELSE 0 END) AS rec_home,
  SUM(CASE WHEN v.home_away='H' THEN v.rec_yards ELSE 0 END) AS rec_yds_home,
  SUM(CASE WHEN v.home_away='H' THEN v.rec_tds ELSE 0 END) AS rec_td_home,
  SUM(CASE WHEN v.home_away='A' THEN v.receptions ELSE 0 END) AS rec_away,
  SUM(CASE WHEN v.home_away='A' THEN v.rec_yards ELSE 0 END) AS rec_yds_away,
  SUM(CASE WHEN v.home_away='A' THEN v.rec_tds ELSE 0 END) AS rec_td_away
FROM v_game_box_player v
GROUP BY v.player_id, v.first_name, v.last_name, v.pos_code, v.season_id;

CREATE OR REPLACE VIEW v_player_splits_win_loss AS
SELECT
  v.player_id,
  v.first_name, v.last_name, v.pos_code,
  v.season_id,
  SUM(CASE WHEN v.result='W' THEN 1 ELSE 0 END) AS games_won,
  SUM(CASE WHEN v.result='L' THEN 1 ELSE 0 END) AS games_lost,
  SUM(CASE WHEN v.result='T' THEN 1 ELSE 0 END) AS games_tied,
  -- Offense totals in wins
  SUM(CASE WHEN v.result='W' THEN v.pass_yards ELSE 0 END) AS pass_yds_wins,
  SUM(CASE WHEN v.result='W' THEN v.pass_tds ELSE 0 END)   AS pass_td_wins,
  SUM(CASE WHEN v.result='W' THEN v.interceptions ELSE 0 END) AS int_wins,
  SUM(CASE WHEN v.result='W' THEN v.rush_yards ELSE 0 END) AS rush_yds_wins,
  SUM(CASE WHEN v.result='W' THEN v.rush_tds ELSE 0 END)   AS rush_td_wins,
  SUM(CASE WHEN v.result='W' THEN v.rec_yards ELSE 0 END)  AS rec_yds_wins,
  SUM(CASE WHEN v.result='W' THEN v.rec_tds ELSE 0 END)    AS rec_td_wins,
  -- Offense totals in losses
  SUM(CASE WHEN v.result='L' THEN v.pass_yards ELSE 0 END) AS pass_yds_losses,
  SUM(CASE WHEN v.result='L' THEN v.pass_tds ELSE 0 END)   AS pass_td_losses,
  SUM(CASE WHEN v.result='L' THEN v.interceptions ELSE 0 END) AS int_losses,
  SUM(CASE WHEN v.result='L' THEN v.rush_yards ELSE 0 END) AS rush_yds_losses,
  SUM(CASE WHEN v.result='L' THEN v.rush_tds ELSE 0 END)   AS rush_td_losses,
  SUM(CASE WHEN v.result='L' THEN v.rec_yards ELSE 0 END)  AS rec_yds_losses,
  SUM(CASE WHEN v.result='L' THEN v.rec_tds ELSE 0 END)    AS rec_td_losses
FROM v_game_box_player v
GROUP BY v.player_id, v.first_name, v.last_name, v.pos_code, v.season_id;

-- =========================================================
-- 6) Advanced QB season view (ANY/A, rate stats clustered)
-- =========================================================
CREATE OR REPLACE VIEW v_qb_advanced_season AS
SELECT
  s.player_id,
  p.first_name, p.last_name,
  s.season_id, se.year AS season_year,
  s.games_played,
  s.pass_attempts, s.pass_completions, s.pass_yards, s.pass_tds, s.interceptions,
  safe_div(s.pass_completions::numeric, NULLIF(s.pass_attempts,0),0)::numeric(6,3) AS comp_pct,
  safe_div(s.pass_yards::numeric, NULLIF(s.pass_attempts,0),0)::numeric(6,3)       AS ypa,
  safe_div(s.pass_tds::numeric, NULLIF(s.pass_attempts,0),0)::numeric(6,3)         AS td_rate,
  safe_div(s.interceptions::numeric, NULLIF(s.pass_attempts,0),0)::numeric(6,3)    AS int_rate,
  safe_div((s.pass_yards + 20*s.pass_tds - 45*s.interceptions)::numeric, NULLIF(s.pass_attempts,0),0)::numeric(7,3) AS any_a,
  -- Reuse passer_rating from v_player_season_totals via inline formula for independence
  ROUND( ( ( GREATEST(0, LEAST(2.375, safe_div(s.pass_completions::numeric, NULLIF(s.pass_attempts,0), 0) - 0.3) * 5)
            + GREATEST(0, LEAST(2.375, safe_div(s.pass_yards::numeric, NULLIF(s.pass_attempts,0), 0) - 3) * 0.25)
            + GREATEST(0, LEAST(2.375, safe_div(s.pass_tds::numeric, NULLIF(s.pass_attempts,0), 0) * 20))
            + GREATEST(0, LEAST(2.375, 2.375 - safe_div(s.interceptions::numeric, NULLIF(s.pass_attempts,0), 0) * 25))
           ) / 6 * 100 )::numeric, 1) AS passer_rating
FROM season_stats s
JOIN players p ON p.id = s.player_id
JOIN seasons se ON se.id = s.season_id
WHERE p.pos_code = 'QB';

-- =========================================================
-- 7) Generic season leaderboard helper
--     SELECT * FROM season_leaders('<season-uuid>', 'pass_yards', 10);
-- =========================================================
CREATE OR REPLACE FUNCTION season_leaders(p_season_id UUID, p_stat TEXT, p_limit INT DEFAULT 10)
RETURNS TABLE (
  rank INT,
  player_id UUID,
  first_name TEXT,
  last_name TEXT,
  team_id UUID,
  team_name TEXT,
  value NUMERIC
)
LANGUAGE plpgsql STABLE AS $$
DECLARE col TEXT;
BEGIN
  -- Validate allowed stat column (season_stats)
  col := LOWER(p_stat);
  IF col NOT IN (
    'games_played',
    'pass_attempts','pass_completions','pass_yards','pass_tds','interceptions',
    'rush_attempts','rush_yards','rush_tds',
    'receptions','rec_yards','rec_tds',
    'tackles','sacks','forced_fumbles','fumbles_recovered',
    'field_goals_made','field_goals_attempted','punts','punt_yards'
  ) THEN
    RAISE EXCEPTION 'Unsupported stat: %', p_stat;
  END IF;

  RETURN QUERY EXECUTE format($f$
    SELECT
      ROW_NUMBER() OVER (ORDER BY s.%I DESC NULLS LAST) AS rank,
      s.player_id,
      p.first_name, p.last_name,
      p.team_id,
      t.name AS team_name,
      s.%I::numeric AS value
    FROM season_stats s
    JOIN players p ON p.id = s.player_id
    LEFT JOIN teams t ON t.id = p.team_id
    WHERE s.season_id = $1
    ORDER BY s.%I DESC NULLS LAST
    LIMIT $2
  $f$, col, col, col)
  USING p_season_id, p_limit;
END;
$$;

-- =========================================================
-- 8) Team offense/defense rollups per season (for dashboards)
-- =========================================================
CREATE OR REPLACE VIEW v_team_season_scoring AS
WITH g AS (
  SELECT season_id, home_team_id AS team_id, home_score AS points_for, away_score AS points_against
  FROM games WHERE played = TRUE
  UNION ALL
  SELECT season_id, away_team_id, away_score, home_score
  FROM games WHERE played = TRUE
)
SELECT
  g.season_id,
  t.id AS team_id,
  t.name AS team_name,
  COUNT(*)                          AS games,
  SUM(g.points_for)                 AS points_for,
  SUM(g.points_against)             AS points_against,
  ROUND(AVG(g.points_for)::numeric, 2)     AS ppg,
  ROUND(AVG(g.points_against)::numeric, 2) AS opp_ppg
FROM g
JOIN teams t ON t.id = g.team_id
GROUP BY g.season_id, t.id, t.name;

-- =========================================================
-- 9) Opponent splits per player (season, opponent)
-- =========================================================
CREATE OR REPLACE VIEW v_player_vs_opponent AS
SELECT
  v.player_id,
  v.season_id,
  CASE WHEN v.team_id = v.home_team_id THEN v.away_team_id ELSE v.home_team_id END AS opponent_id,
  MIN(v.opponent_name) AS opponent_name,
  COUNT(*) AS games,
  -- Totals
  SUM(v.pass_yards) AS pass_yards,
  SUM(v.pass_tds)   AS pass_tds,
  SUM(v.interceptions) AS interceptions,
  SUM(v.rush_yards) AS rush_yards,
  SUM(v.rush_tds)   AS rush_tds,
  SUM(v.rec_yards)  AS rec_yards,
  SUM(v.rec_tds)    AS rec_tds
FROM v_game_box_player v
GROUP BY v.player_id, v.season_id, opponent_id;

-- End of file.
