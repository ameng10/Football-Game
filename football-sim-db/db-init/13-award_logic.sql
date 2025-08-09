-- db-init/13-award_logic.sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

SET client_min_messages = NOTICE;

-- =========================================================
-- Safety helpers
-- =========================================================

-- Safe division for NUMERIC
CREATE OR REPLACE FUNCTION award_safe_div(n NUMERIC, d NUMERIC, z NUMERIC DEFAULT 0)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE WHEN d IS NULL OR d = 0 THEN z ELSE n/d END;
$$;

-- Resolve league + level from a season
CREATE OR REPLACE FUNCTION award_season_level(p_season_id UUID)
RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT l.level
  FROM seasons s
  JOIN leagues l ON l.id = s.league_id
  WHERE s.id = $1;
$$;

-- Create or fetch an award id by name + level
CREATE OR REPLACE FUNCTION award_get_or_create(p_name TEXT, p_level TEXT, p_desc TEXT DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM awards WHERE name = p_name AND level = p_level LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO awards (name, description, level)
    VALUES (p_name, COALESCE(p_desc, ''))
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END;
$$;

-- =========================================================
-- Storage for weekly awards & all-league teams
-- =========================================================

-- Weekly awards (e.g., Offensive/Defensive Player of the Week)
CREATE TABLE IF NOT EXISTS weekly_awards (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  season_id UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
  week INT NOT NULL,
  award_id UUID NOT NULL REFERENCES awards(id) ON DELETE CASCADE,
  player_id UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  UNIQUE (season_id, week, award_id)
);
CREATE INDEX IF NOT EXISTS idx_weekly_awards_season_week ON weekly_awards(season_id, week);

-- Monthly awards (optional; created for future use)
CREATE TABLE IF NOT EXISTS monthly_awards (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  season_id UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
  month INT NOT NULL CHECK (month BETWEEN 1 AND 12),
  award_id UUID NOT NULL REFERENCES awards(id) ON DELETE CASCADE,
  player_id UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  UNIQUE (season_id, month, award_id)
);

-- All-League Teams (First/Second)
CREATE TABLE IF NOT EXISTS all_league_team (
  season_id UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
  team_name TEXT NOT NULL,                      -- 'First Team' | 'Second Team'
  pos_code TEXT NOT NULL REFERENCES positions(code),
  rank INT NOT NULL,                            -- 1..N per position
  player_id UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  PRIMARY KEY (season_id, team_name, pos_code, rank)
);
CREATE INDEX IF NOT EXISTS idx_all_league_team_season ON all_league_team(season_id);

-- =========================================================
-- Scoring models
-- =========================================================

-- Game-level offensive score for POTW selection (passing + rushing + receiving)
CREATE OR REPLACE FUNCTION award_offense_game_score(
  pass_yards INT, pass_tds INT, interceptions INT,
  rush_yards INT, rush_tds INT,
  rec_yards INT,  rec_tds INT
) RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT
    COALESCE(pass_yards,0) * 0.05  + COALESCE(pass_tds,0) * 6
  + COALESCE(rush_yards,0) * 0.10  + COALESCE(rush_tds,0) * 6
  + COALESCE(rec_yards,0)  * 0.10  + COALESCE(rec_tds,0)  * 6
  - COALESCE(interceptions,0) * 3;
$$;

-- Game-level defensive score (simplified using available stats)
CREATE OR REPLACE FUNCTION award_defense_game_score(
  tackles INT, sacks INT, forced_fumbles INT, fumbles_recovered INT
) RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT
    COALESCE(tackles,0) * 0.8
  + COALESCE(sacks,0) * 6
  + (COALESCE(forced_fumbles,0) + COALESCE(fumbles_recovered,0)) * 5;
$$;

-- Season-level MVP score (blend of offense totals with slight weighting)
CREATE OR REPLACE FUNCTION award_mvp_season_score(
  pass_yards INT, pass_tds INT, interceptions INT,
  rush_yards INT, rush_tds INT,
  rec_yards INT,  rec_tds INT
) RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT
    COALESCE(pass_yards,0) * 0.04 + COALESCE(pass_tds,0) * 5
  + COALESCE(rush_yards,0) * 0.08 + COALESCE(rush_tds,0) * 6
  + COALESCE(rec_yards,0)  * 0.08 + COALESCE(rec_tds,0)  * 6
  - COALESCE(interceptions,0) * 3;
$$;

-- Season-level defensive POY score
CREATE OR REPLACE FUNCTION award_defense_season_score(
  tackles INT, sacks INT, forced_fumbles INT, fumbles_recovered INT
) RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(tackles,0) * 0.8
       + COALESCE(sacks,0) * 6
       + (COALESCE(forced_fumbles,0) + COALESCE(fumbles_recovered,0)) * 5;
$$;

-- =========================================================
-- WEEKLY AWARDS
-- =========================================================
/*
  assign_weekly_awards(season_id, week)
  - Creates (or replaces) Offensive & Defensive Player of the Week
  - Scope restricted to players who appeared in a game that week in the season
*/
CREATE OR REPLACE FUNCTION assign_weekly_awards(p_season_id UUID, p_week INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
  v_level TEXT := award_season_level(p_season_id);
  v_aw_off UUID;
  v_aw_def UUID;
  v_created INT := 0;

  rec_off RECORD;
  rec_def RECORD;
BEGIN
  -- Ensure canonical weekly awards exist for this level
  v_aw_off := award_get_or_create('Offensive Player of the Week', v_level, 'Top weekly offensive performance');
  v_aw_def := award_get_or_create('Defensive Player of the Week', v_level, 'Top weekly defensive performance');

  -- Offensive POTW: best single-game offense_score in week
  SELECT gs.player_id,
         award_offense_game_score(gs.pass_yards, gs.pass_tds, gs.interceptions,
                                  gs.rush_yards, gs.rush_tds, gs.rec_yards, gs.rec_tds) AS score
  INTO rec_off
  FROM game_stats gs
  JOIN games g ON g.id = gs.game_id
  WHERE g.season_id = p_season_id
    AND g.week = p_week
    AND g.played = TRUE
  ORDER BY score DESC NULLS LAST
  LIMIT 1;

  -- Defensive POTW
  SELECT gs.player_id,
         award_defense_game_score(gs.tackles, gs.sacks, gs.forced_fumbles, gs.fumbles_recovered) AS score
  INTO rec_def
  FROM game_stats gs
  JOIN games g ON g.id = gs.game_id
  WHERE g.season_id = p_season_id
    AND g.week = p_week
    AND g.played = TRUE
  ORDER BY score DESC NULLS LAST
  LIMIT 1;

  -- Upsert weekly awards (replace if already there)
  IF rec_off.player_id IS NOT NULL THEN
    INSERT INTO weekly_awards (season_id, week, award_id, player_id)
    VALUES (p_season_id, p_week, v_aw_off, rec_off.player_id)
    ON CONFLICT (season_id, week, award_id)
    DO UPDATE SET player_id = EXCLUDED.player_id;
    v_created := v_created + 1;
  END IF;

  IF rec_def.player_id IS NOT NULL THEN
    INSERT INTO weekly_awards (season_id, week, award_id, player_id)
    VALUES (p_season_id, p_week, v_aw_def, rec_def.player_id)
    ON CONFLICT (season_id, week, award_id)
    DO UPDATE SET player_id = EXCLUDED.player_id;
    v_created := v_created + 1;
  END IF;

  RETURN v_created;
END;
$$;

-- Convenience: assign awards for ALL weeks that have games
CREATE OR REPLACE FUNCTION assign_weekly_awards_all(p_season_id UUID)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
  w RECORD;
  total INT := 0;
BEGIN
  FOR w IN
    SELECT DISTINCT week FROM games WHERE season_id = p_season_id AND played = TRUE ORDER BY week
  LOOP
    total := total + assign_weekly_awards(p_season_id, w.week);
  END LOOP;
  RETURN total;
END;
$$;

-- =========================================================
-- SEASON AWARDS
-- =========================================================
/*
  assign_season_awards(season_id)
  - MVP (overall offense-weighted)
  - Best QB, RB, WR
  - Defensive Player of the Year
  - Writes to awards_assigned (replacing existing rows for this season)
*/
CREATE OR REPLACE FUNCTION assign_season_awards(p_season_id UUID)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
  v_level TEXT := award_season_level(p_season_id);
  v_mvp UUID;
  v_qb  UUID;
  v_rb  UUID;
  v_wr  UUID;
  v_dpoy UUID;

  rec RECORD;
  v_count INT := 0;
BEGIN
  -- Ensure canonical awards
  v_mvp  := award_get_or_create('League MVP', v_level, 'Most valuable player');
  v_qb   := award_get_or_create('Best QB',   v_level, 'Top quarterback');
  v_rb   := award_get_or_create('Best RB',   v_level, 'Top running back');
  v_wr   := award_get_or_create('Best WR',   v_level, 'Top wide receiver');
  v_dpoy := award_get_or_create('Defensive Player of the Year', v_level, 'Top defender');

  -- Clean existing rows for this season_id
  DELETE FROM awards_assigned WHERE season_id = p_season_id AND award_id IN (v_mvp, v_qb, v_rb, v_wr, v_dpoy);

  -- MVP
  SELECT s.player_id
  INTO rec
  FROM season_stats s
  JOIN players p ON p.id = s.player_id
  WHERE s.season_id = p_season_id
  ORDER BY award_mvp_season_score(s.pass_yards, s.pass_tds, s.interceptions,
                                  s.rush_yards, s.rush_tds, s.rec_yards, s.rec_tds) DESC NULLS LAST,
           s.games_played DESC
  LIMIT 1;
  IF rec.player_id IS NOT NULL THEN
    INSERT INTO awards_assigned (award_id, season_id, player_id)
    VALUES (v_mvp, p_season_id, rec.player_id);
    v_count := v_count + 1;
  END IF;

  -- Best QB
  SELECT s.player_id
  INTO rec
  FROM season_stats s
  JOIN players p ON p.id = s.player_id
  WHERE s.season_id = p_season_id AND p.pos_code = 'QB'
  ORDER BY (COALESCE(s.pass_yards,0) * 0.06 + COALESCE(s.pass_tds,0) * 6 - COALESCE(s.interceptions,0) * 4) DESC NULLS LAST
  LIMIT 1;
  IF rec.player_id IS NOT NULL THEN
    INSERT INTO awards_assigned (award_id, season_id, player_id)
    VALUES (v_qb, p_season_id, rec.player_id);
    v_count := v_count + 1;
  END IF;

  -- Best RB
  SELECT s.player_id
  INTO rec
  FROM season_stats s
  JOIN players p ON p.id = s.player_id
  WHERE s.season_id = p_season_id AND p.pos_code = 'RB'
  ORDER BY (COALESCE(s.rush_yards,0) * 0.1 + COALESCE(s.rush_tds,0) * 6 + COALESCE(s.rec_yards,0) * 0.04 + COALESCE(s.rec_tds,0) * 3) DESC NULLS LAST
  LIMIT 1;
  IF rec.player_id IS NOT NULL THEN
    INSERT INTO awards_assigned (award_id, season_id, player_id)
    VALUES (v_rb, p_season_id, rec.player_id);
    v_count := v_count + 1;
  END IF;

  -- Best WR
  SELECT s.player_id
  INTO rec
  FROM season_stats s
  JOIN players p ON p.id = s.player_id
  WHERE s.season_id = p_season_id AND p.pos_code IN ('WR','TE')
  ORDER BY (COALESCE(s.rec_yards,0) * 0.1 + COALESCE(s.rec_tds,0) * 6) DESC NULLS LAST
  LIMIT 1;
  IF rec.player_id IS NOT NULL THEN
    INSERT INTO awards_assigned (award_id, season_id, player_id)
    VALUES (v_wr, p_season_id, rec.player_id);
    v_count := v_count + 1;
  END IF;

  -- Defensive POY
  SELECT s.player_id
  INTO rec
  FROM season_stats s
  JOIN players p ON p.id = s.player_id
  WHERE s.season_id = p_season_id AND p.pos_code IN ('DL','LB','CB','S')
  ORDER BY award_defense_season_score(s.tackles, s.sacks, s.forced_fumbles, s.fumbles_recovered) DESC NULLS LAST
  LIMIT 1;
  IF rec.player_id IS NOT NULL THEN
    INSERT INTO awards_assigned (award_id, season_id, player_id)
    VALUES (v_dpoy, p_season_id, rec.player_id);
    v_count := v_count + 1;
  END IF;

  RETURN v_count;
END;
$$;

-- =========================================================
-- ALL-LEAGUE TEAMS (First & Second)
-- =========================================================
/*
  assign_all_league_teams(season_id)
  - Builds First Team & Second Team using position slot map
  - Order by stat-weighted score when available, fall back to rating
*/
CREATE OR REPLACE FUNCTION assign_all_league_teams(p_season_id UUID)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
  -- slot map per position
  -- QB:1, RB:2, WR:3, TE:1, OL:5, DL:4, LB:3, CB:2, S:2, K:1, P:1
  posmap JSONB := '{
    "QB":1, "RB":2, "WR":3, "TE":1,
    "OL":5, "DL":4, "LB":3, "CB":2, "S":2,
    "K":1, "P":1
  }'::jsonb;

  v_level TEXT := award_season_level(p_season_id);
  k TEXT;
  slots INT;
  placed INT := 0;

  -- helper CTE results
  rec RECORD;

  -- temp table to stage rankings per position
BEGIN
  -- wipe existing team selections for the season
  DELETE FROM all_league_team WHERE season_id = p_season_id;

  -- iterate positions
  FOR k, slots IN
    SELECT key, (posmap->>key)::INT
    FROM jsonb_object_keys(posmap) AS key
  LOOP
    -- Select ranking list depending on position family
    -- For OL (no counting stats), rank by player rating
    IF k IN ('OL','K','P') THEN
      FOR rec IN
        SELECT p.id AS player_id, p.rating, 0::numeric AS score
        FROM players p
        JOIN teams t ON t.id = p.team_id
        WHERE p.pos_code = k
          AND t.league_id = (SELECT league_id FROM seasons WHERE id = p_season_id)
        ORDER BY p.rating DESC, p.id
        LIMIT (slots * 2)  -- take enough for First+Second
      LOOP
        NULL; -- collection by per-team insertion below
      END LOOP;

      -- First Team
      INSERT INTO all_league_team (season_id, team_name, pos_code, rank, player_id)
      SELECT p_season_id, 'First Team', k, ROW_NUMBER() OVER (ORDER BY rating DESC, id), id
      FROM (
        SELECT p.id, p.rating
        FROM players p
        JOIN teams t ON t.id = p.team_id
        WHERE p.pos_code = k
          AND t.league_id = (SELECT league_id FROM seasons WHERE id = p_season_id)
        ORDER BY p.rating DESC, p.id
        LIMIT slots
      ) x;

      -- Second Team
      INSERT INTO all_league_team (season_id, team_name, pos_code, rank, player_id)
      SELECT p_season_id, 'Second Team', k, ROW_NUMBER() OVER (ORDER BY rating DESC, id), id
      FROM (
        SELECT p.id, p.rating
        FROM players p
        JOIN teams t ON t.id = p.team_id
        WHERE p.pos_code = k
          AND t.league_id = (SELECT league_id FROM seasons WHERE id = p_season_id)
        ORDER BY p.rating DESC, p.id
        OFFSET slots LIMIT slots
      ) y;

      placed := placed + slots * 2;

    -- Skill & defense positions: rank by season stat scores with fallbacks
    ELSE
      -- First Team
      INSERT INTO all_league_team (season_id, team_name, pos_code, rank, player_id)
      SELECT
        p_season_id,
        'First Team',
        k,
        ROW_NUMBER() OVER (ORDER BY score DESC, coalesce(ss.games_played,0) DESC, p.rating DESC, p.id),
        p.id
      FROM players p
      JOIN teams t ON t.id = p.team_id
      LEFT JOIN season_stats ss ON ss.player_id = p.id AND ss.season_id = p_season_id
      CROSS JOIN LATERAL (
        SELECT CASE
          WHEN k = 'QB' THEN (COALESCE(ss.pass_yards,0) * 0.06 + COALESCE(ss.pass_tds,0) * 6 - COALESCE(ss.interceptions,0) * 4)
          WHEN k = 'RB' THEN (COALESCE(ss.rush_yards,0) * 0.1 + COALESCE(ss.rush_tds,0) * 6 + COALESCE(ss.rec_yards,0) * 0.04 + COALESCE(ss.rec_tds,0) * 3)
          WHEN k IN ('WR','TE') THEN (COALESCE(ss.rec_yards,0) * 0.1 + COALESCE(ss.rec_tds,0) * 6)
          WHEN k IN ('DL','LB','CB','S') THEN award_defense_season_score(ss.tackles, ss.sacks, ss.forced_fumbles, ss.fumbles_recovered)
          ELSE p.rating
        END AS score
      ) s
      WHERE p.pos_code = k
        AND t.league_id = (SELECT league_id FROM seasons WHERE id = p_season_id)
      ORDER BY score DESC, COALESCE(ss.games_played,0) DESC, p.rating DESC, p.id
      LIMIT slots;

      -- Second Team
      INSERT INTO all_league_team (season_id, team_name, pos_code, rank, player_id)
      SELECT
        p_season_id,
        'Second Team',
        k,
        ROW_NUMBER() OVER (ORDER BY score DESC, coalesce(ss.games_played,0) DESC, p.rating DESC, p.id),
        p.id
      FROM players p
      JOIN teams t ON t.id = p.team_id
      LEFT JOIN season_stats ss ON ss.player_id = p.id AND ss.season_id = p_season_id
      CROSS JOIN LATERAL (
        SELECT CASE
          WHEN k = 'QB' THEN (COALESCE(ss.pass_yards,0) * 0.06 + COALESCE(ss.pass_tds,0) * 6 - COALESCE(ss.interceptions,0) * 4)
          WHEN k = 'RB' THEN (COALESCE(ss.rush_yards,0) * 0.1 + COALESCE(ss.rush_tds,0) * 6 + COALESCE(ss.rec_yards,0) * 0.04 + COALESCE(ss.rec_tds,0) * 3)
          WHEN k IN ('WR','TE') THEN (COALESCE(ss.rec_yards,0) * 0.1 + COALESCE(ss.rec_tds,0) * 6)
          WHEN k IN ('DL','LB','CB','S') THEN award_defense_season_score(ss.tackles, ss.sacks, ss.forced_fumbles, ss.fumbles_recovered)
          ELSE p.rating
        END AS score
      ) s
      WHERE p.pos_code = k
        AND t.league_id = (SELECT league_id FROM seasons WHERE id = p_season_id)
      ORDER BY score DESC, COALESCE(ss.games_played,0) DESC, p.rating DESC, p.id
      OFFSET slots LIMIT slots;

      placed := placed + slots * 2;
    END IF;
  END LOOP;

  RETURN placed;
END;
$$;

-- =========================================================
-- Orchestrator: end-of-regular-season pass
-- =========================================================
/*
  assign_all_awards(season_id)
  - Runs weekly awards for all played weeks
  - Runs major season awards
  - Builds All-League First/Second Teams
*/
CREATE OR REPLACE FUNCTION assign_all_awards(p_season_id UUID)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_weekly INT := 0;
  v_major  INT := 0;
  v_teams  INT := 0;
BEGIN
  v_weekly := assign_weekly_awards_all(p_season_id);
  v_major  := assign_season_awards(p_season_id);
  v_teams  := assign_all_league_teams(p_season_id);

  RETURN jsonb_build_object(
    'weekly_rows', v_weekly,
    'season_awards', v_major,
    'all_league_slots', v_teams
  );
END;
$$;

-- =========================================================
-- Convenience views for UI
-- =========================================================

-- Season awards (major) with names
CREATE OR REPLACE VIEW v_season_awards AS
SELECT
  aa.season_id,
  a.name AS award_name,
  a.level,
  aa.player_id,
  p.first_name || ' ' || p.last_name AS player_name,
  p.pos_code,
  p.team_id,
  t.name AS team_name
FROM awards_assigned aa
JOIN awards a  ON a.id = aa.award_id
LEFT JOIN players p ON p.id = aa.player_id
LEFT JOIN teams t   ON t.id = p.team_id;

-- Weekly awards view
CREATE OR REPLACE VIEW v_weekly_awards AS
SELECT
  w.season_id,
  se.year AS season_year,
  w.week,
  a.name AS award_name,
  a.level,
  w.player_id,
  p.first_name || ' ' || p.last_name AS player_name,
  p.pos_code,
  p.team_id,
  t.name AS team_name
FROM weekly_awards w
JOIN awards a  ON a.id = w.award_id
JOIN seasons se ON se.id = w.season_id
LEFT JOIN players p ON p.id = w.player_id
LEFT JOIN teams t   ON t.id = p.team_id
ORDER BY w.week, award_name;

-- All-league listing (joined)
CREATE OR REPLACE VIEW v_all_league AS
SELECT
  al.season_id,
  se.year AS season_year,
  al.team_name,
  al.pos_code,
  al.rank,
  al.player_id,
  p.first_name || ' ' || p.last_name AS player_name,
  p.team_id,
  t.name AS team_name
FROM all_league_team al
JOIN seasons se ON se.id = al.season_id
LEFT JOIN players p ON p.id = al.player_id
LEFT JOIN teams t   ON t.id = p.team_id
ORDER BY al.team_name, al.pos_code, al.rank;

-- =========================================================
-- Quick test helper (optional)
-- =========================================================
-- DO $$
-- DECLARE v_season UUID;
-- BEGIN
--   -- pick current HS season
--   SELECT s.id INTO v_season
--   FROM seasons s JOIN leagues l ON l.id = s.league_id
--   WHERE l.level = 'HighSchool' AND s.current = TRUE
--   LIMIT 1;
--   IF v_season IS NULL THEN RAISE NOTICE 'No current HS season'; RETURN; END IF;
--
--   RAISE NOTICE '%', assign_all_awards(v_season);
-- END$$;
