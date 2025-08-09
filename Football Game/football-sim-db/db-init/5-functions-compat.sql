-- =========================================
-- Compat / convenience functions & wrappers
-- Works with tables in 1-schema.sql and sim in 4-functions-sim.sql
-- =========================================

-- Use the same extension policy as schema
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- -------------------------
-- PUBLIC WRAPPERS (stable)
-- -------------------------

-- Mirror name used by API/UI: public.simulate_game(uuid)
CREATE OR REPLACE FUNCTION public.simulate_game(p_game_id UUID)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM simulate_game(p_game_id);
END;
$$;

-- public.simulate_week(season_id, week)
CREATE OR REPLACE FUNCTION public.simulate_week(p_season_id UUID, p_week INT)
RETURNS int
LANGUAGE plpgsql AS $$
BEGIN
  RETURN simulate_week(p_season_id, p_week);
END;
$$;

-- public.simulate_season(season_id)
CREATE OR REPLACE FUNCTION public.simulate_season(p_season_id UUID)
RETURNS int
LANGUAGE plpgsql AS $$
BEGIN
  RETURN simulate_season(p_season_id);
END;
$$;

-- ---------------------------------------
-- Season helpers (create/get/upsert rows)
-- ---------------------------------------

-- Return season_id for a league/year; create if missing
CREATE OR REPLACE FUNCTION get_or_create_season(p_league_id UUID, p_year INT, p_mark_current BOOLEAN DEFAULT true)
RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM seasons WHERE league_id = p_league_id AND year = p_year;
  IF v_id IS NULL THEN
    INSERT INTO seasons (league_id, year, current)
    VALUES (p_league_id, p_year, COALESCE(p_mark_current, true))
    RETURNING id INTO v_id;
  ELSIF p_mark_current IS TRUE THEN
    UPDATE seasons SET current = FALSE WHERE league_id = p_league_id AND id <> v_id;
    UPDATE seasons SET current = TRUE  WHERE id = v_id;
  END IF;

  -- Ensure standings rows for all league teams
  INSERT INTO standings (season_id, team_id)
  SELECT v_id, t.id
  FROM teams t
  WHERE t.league_id = p_league_id
  ON CONFLICT (season_id, team_id) DO NOTHING;

  RETURN v_id;
END;
$$;

-- Get current season by league_id (or NULL)
CREATE OR REPLACE FUNCTION current_season_id(p_league_id UUID)
RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT id FROM seasons WHERE league_id = p_league_id AND current = TRUE LIMIT 1;
$$;

-- Get a league id by level label (HighSchool/College/Pro) — tolerant to common aliases
CREATE OR REPLACE FUNCTION league_id_by_level(p_level TEXT)
RETURNS UUID
LANGUAGE sql STABLE AS $$
  WITH norm AS (
    SELECT CASE
      WHEN LOWER($1) IN ('hs','highschool','high school') THEN 'HighSchool'
      WHEN LOWER($1) IN ('college','ncaa') THEN 'College'
      WHEN LOWER($1) IN ('pro','nfl','professional') THEN 'Pro'
      ELSE $1
    END AS lvl
  )
  SELECT id FROM leagues WHERE level = (SELECT lvl FROM norm) LIMIT 1;
$$;

-- Ensure standings rows exist for all teams in a season (idempotent)
CREATE OR REPLACE FUNCTION upsert_season_standings(p_season_id UUID)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE v_league UUID; v_cnt INT := 0;
BEGIN
  SELECT league_id INTO v_league FROM seasons WHERE id = p_season_id;
  IF v_league IS NULL THEN
    RAISE EXCEPTION 'Season % not found', p_season_id;
  END IF;

  INSERT INTO standings (season_id, team_id)
  SELECT p_season_id, t.id
  FROM teams t
  WHERE t.league_id = v_league
  ON CONFLICT (season_id, team_id) DO NOTHING;

  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  RETURN v_cnt;
END;
$$;

-- ---------------------------------------
-- Scheduling helpers (simple generators)
-- ---------------------------------------

/*
  schedule_round_robin(p_season_id, p_shuffle, p_weeks_hint)
  - Creates a single round-robin (each pair meets once)
  - Home team is first item in pairing for that “round”
  - Weeks allocated sequentially; if p_weeks_hint is NULL, uses minimal weeks
*/
CREATE OR REPLACE FUNCTION schedule_round_robin(
  p_season_id UUID,
  p_shuffle BOOLEAN DEFAULT TRUE,
  p_weeks_hint INT DEFAULT NULL
) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  v_league UUID;
  v_team_ids UUID[];
  v_n INT;
  v_rounds INT;
  v_weeks INT;
  r INT;
  i INT;
  home UUID;
  away UUID;
  created INT := 0;
BEGIN
  SELECT league_id INTO v_league FROM seasons WHERE id = p_season_id;
  IF v_league IS NULL THEN RAISE EXCEPTION 'Season % not found', p_season_id; END IF;

  SELECT array_agg(id ORDER BY name) INTO v_team_ids FROM teams WHERE league_id = v_league;
  v_n := COALESCE(array_length(v_team_ids,1),0);
  IF v_n < 2 THEN RETURN 0; END IF;

  -- If odd, add a BYE (null)
  IF (v_n % 2) = 1 THEN
    v_team_ids := v_team_ids || NULL;
    v_n := v_n + 1;
  END IF;

  -- Number of rounds needed (n-1)
  v_rounds := v_n - 1;
  v_weeks := COALESCE(p_weeks_hint, v_rounds);

  -- Optionally shuffle the initial order for variety
  IF p_shuffle THEN
    SELECT array_agg(x ORDER BY random()) INTO v_team_ids FROM unnest(v_team_ids) AS x;
  END IF;

  -- Circle method scheduling
  FOR r IN 1..v_rounds LOOP
    FOR i IN 1..(v_n/2) LOOP
      home := v_team_ids[i];
      away := v_team_ids[v_n - i + 1];

      IF home IS NOT NULL AND away IS NOT NULL THEN
        INSERT INTO games (season_id, week, date, home_team_id, away_team_id, status, played)
        VALUES (p_season_id, r, (CURRENT_DATE + (r||' days')::interval)::date, home, away, 'Scheduled', FALSE);
        created := created + 1;
      END IF;
    END LOOP;

    -- rotate (keep first fixed)
    v_team_ids := ARRAY[
      v_team_ids[1]
    ] || ARRAY[
      v_team_ids[v_n]
    ] || v_team_ids[2:(v_n-1)];
  END LOOP;

  -- Ensure standings exist
  PERFORM upsert_season_standings(p_season_id);

  RETURN created;
END;
$$;

-- Quick utility: wipe and reschedule round robin for a season
CREATE OR REPLACE FUNCTION reschedule_round_robin(
  p_season_id UUID,
  p_shuffle BOOLEAN DEFAULT TRUE,
  p_weeks_hint INT DEFAULT NULL
) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE v_cnt INT;
BEGIN
  DELETE FROM games WHERE season_id = p_season_id;
  v_cnt := schedule_round_robin(p_season_id, p_shuffle, p_weeks_hint);
  RETURN v_cnt;
END;
$$;

-- ---------------------------------------
-- Small info helpers
-- ---------------------------------------

-- Next unplayed game id in a season (NULL if none)
CREATE OR REPLACE FUNCTION next_unplayed_game(p_season_id UUID)
RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT id FROM games
  WHERE season_id = $1 AND played = FALSE
  ORDER BY week, date NULLS LAST, id
  LIMIT 1;
$$;

-- Count remaining games in a season
CREATE OR REPLACE FUNCTION remaining_games(p_season_id UUID)
RETURNS INT
LANGUAGE sql STABLE AS $$
  SELECT COUNT(*)::int FROM games WHERE season_id = $1 AND played = FALSE;
$$;

-- Safe mark game final with score (invokes triggers for standings)
CREATE OR REPLACE FUNCTION finalize_game(p_game_id UUID, p_home INT, p_away INT)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE games
  SET home_score = p_home,
      away_score = p_away,
      played = TRUE,
      status = 'Final'
  WHERE id = p_game_id;
END;
$$;

-- ---------------------------------------
-- “One-liners” for scripts/dev
-- ---------------------------------------

/*
  create_and_schedule(league_level, year):
  - resolves league by level label ('HighSchool','College','Pro' or hs/college/pro aliases)
  - creates/returns season_id
  - schedules a round robin among all league teams
*/
CREATE OR REPLACE FUNCTION create_and_schedule(p_level TEXT, p_year INT)
RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE v_league UUID; v_season UUID;
BEGIN
  v_league := league_id_by_level(p_level);
  IF v_league IS NULL THEN
    RAISE EXCEPTION 'League with level % not found', p_level;
  END IF;

  v_season := get_or_create_season(v_league, p_year, TRUE);
  PERFORM reschedule_round_robin(v_season, TRUE, NULL);
  RETURN v_season;
END;
$$;

-- Simulate through a specific week (inclusive)
CREATE OR REPLACE FUNCTION simulate_through_week(p_season_id UUID, p_week INT)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE w INT; total INT := 0;
BEGIN
  FOR w IN 1..p_week LOOP
    total := total + simulate_week(p_season_id, w);
  END LOOP;
  RETURN total;
END;
$$;
