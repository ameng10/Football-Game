-- db-init/11-hs_generation.sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

SET client_min_messages = NOTICE;

-- =========================================================
-- Helpers
-- =========================================================

-- Random int in [lo, hi]
CREATE OR REPLACE FUNCTION hs_rnd_int(lo INT, hi INT)
RETURNS INT LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT lo + FLOOR(random() * GREATEST(0, hi - lo + 1))::int;
$$;

-- Clamp
CREATE OR REPLACE FUNCTION hs_clampi(x INT, lo INT, hi INT)
RETURNS INT LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT GREATEST(lo, LEAST(hi, x));
$$;

-- Pick weighted class (9..12) with realistic HS distribution
-- Seniors/Junior slightly more numerous among starters
CREATE OR REPLACE FUNCTION hs_pick_grade()
RETURNS INT LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE r NUMERIC := random();
BEGIN
  IF r < 0.22 THEN RETURN 9;       -- Freshman
  ELSIF r < 0.47 THEN RETURN 10;   -- Sophomore
  ELSIF r < 0.76 THEN RETURN 11;   -- Junior
  ELSE RETURN 12;                  -- Senior
  END IF;
END;
$$;

-- Convert grade to class year text (uses function from 10 if present; falls back)
CREATE OR REPLACE FUNCTION hs_grade_to_class_year(p_grade INT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_grade
    WHEN 9 THEN 'Freshman'
    WHEN 10 THEN 'Sophomore'
    WHEN 11 THEN 'Junior'
    WHEN 12 THEN 'Senior'
    ELSE 'Freshman'
  END;
$$;

-- Position list (canonical codes from 1-schema.sql)
-- (Use as a table-valued function for easy joining)
CREATE OR REPLACE FUNCTION hs_positions_distribution(p_roster INT)
RETURNS TABLE(pos_code TEXT, target INT) LANGUAGE plpgsql AS $$
BEGIN
  -- Base template totals ~49; we scale to requested roster size
  RETURN QUERY
  WITH base AS (
    SELECT * FROM (VALUES
      ('QB',3), ('RB',5), ('WR',7), ('TE',3),
      ('OL',8), ('DL',8), ('LB',6), ('CB',4), ('S',3),
      ('K',1), ('P',1)
    ) AS t(pos_code, cnt)
  ),
  total AS (
    SELECT SUM(cnt)::NUMERIC AS tot FROM base
  )
  SELECT b.pos_code,
         GREATEST(1, ROUND((b.cnt / (SELECT tot FROM total)) * p_roster))::INT AS target
  FROM base b;
END;
$$;

-- Synthetic name banks for HS players/teams
CREATE OR REPLACE FUNCTION hs_pick_name(p_kind TEXT)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE arr TEXT[]; idx INT;
BEGIN
  IF p_kind = 'first' THEN
    arr := ARRAY['Jake','Ethan','Liam','Noah','Aiden','Mason','Logan','Lucas','Caleb','Owen',
                 'Jayden','Carter','Elijah','Michael','Benjamin','Daniel','Henry','Jack','Ryan','Tyler'];
  ELSIF p_kind = 'last' THEN
    arr := ARRAY['Anderson','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez','Martinez',
                 'Hernandez','Lopez','Gonzalez','Wilson','Moore','Taylor','Thomas','Jackson','White','Harris'];
  ELSIF p_kind = 'city' THEN
    arr := ARRAY['Springfield','Fairview','Oakwood','Riverton','Maplewood','Brookfield','Hillcrest','Lakeview','Crestwood','Summit'];
  ELSIF p_kind = 'mascot' THEN
    arr := ARRAY['Tigers','Eagles','Knights','Bulldogs','Hawks','Panthers','Lions','Wolves','Spartans','Patriots'];
  ELSE
    arr := ARRAY['Generic'];
  END IF;
  idx := hs_rnd_int(1, array_length(arr,1));
  RETURN arr[idx];
END;
$$;

-- =========================================================
-- League / season ensure
-- =========================================================

CREATE OR REPLACE FUNCTION hs_ensure_league()
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_league UUID;
BEGIN
  SELECT id INTO v_league FROM leagues WHERE level='HighSchool' LIMIT 1;
  IF v_league IS NULL THEN
    INSERT INTO leagues (name, level) VALUES ('State High School League', 'HighSchool')
    RETURNING id INTO v_league;
    RAISE NOTICE 'Created HighSchool league: %', v_league;
  END IF;
  RETURN v_league;
END;
$$;

CREATE OR REPLACE FUNCTION hs_get_or_create_current_season(p_league UUID, p_year INT DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INT)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_season UUID;
BEGIN
  v_season := get_or_create_season(p_league, p_year, TRUE);
  RETURN v_season;
END;
$$;

-- =========================================================
-- Team generation
-- =========================================================

CREATE OR REPLACE FUNCTION hs_generate_teams(p_league UUID, p_needed INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE existing INT; i INT := 1; created INT := 0;
BEGIN
  SELECT COUNT(*) INTO existing FROM teams WHERE league_id=p_league;
  IF existing >= p_needed THEN
    RETURN 0;
  END IF;

  WHILE i <= (p_needed - existing) LOOP
    INSERT INTO teams (league_id, name, city, mascot, prestige)
    VALUES (
      p_league,
      hs_pick_name('city') || ' High',
      hs_pick_name('city'),
      hs_pick_name('mascot'),
      hs_rnd_int(30, 70)
    );
    created := created + 1;
    i := i + 1;
  END WHILE;

  RETURN created;
END;
$$;

-- =========================================================
-- Player & attribute generation (by position)
-- =========================================================

CREATE OR REPLACE FUNCTION hs_generate_player(
  p_team UUID,
  p_pos TEXT,
  p_year INT
) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE
  v_grade INT := hs_pick_grade();
  v_class TEXT := hs_grade_to_class_year(v_grade);
  v_stars INT; v_rating INT; v_potential INT;
  v_player UUID;
  v_birth DATE := make_date(p_year - (18 - v_grade), hs_rnd_int(1,12), hs_rnd_int(1,28));
  -- base star distro: 5★ rare, 4★ uncommon, many 2–3★
  r NUMERIC := random();
BEGIN
  v_stars := CASE
    WHEN r < 0.03 THEN 5
    WHEN r < 0.12 THEN 4
    WHEN r < 0.40 THEN 3
    WHEN r < 0.78 THEN 2
    ELSE 1
  END;

  v_rating := hs_clampi(45 + v_stars*7 + CASE WHEN p_pos='QB' THEN 3 WHEN p_pos IN ('WR','RB','TE','CB','S') THEN 1 ELSE 0 END + hs_rnd_int(-5,5), 40, 88);
  v_potential := hs_clampi(v_rating + hs_rnd_int(8,20), 55, 96);

  INSERT INTO players (team_id, first_name, last_name, pos_code, birth_date, stars, rating, potential, class_year, followers)
  VALUES (
    p_team,
    hs_pick_name('first'),
    hs_pick_name('last'),
    p_pos,
    v_birth,
    v_stars,
    v_rating,
    v_potential,
    v_class,
    hs_rnd_int(0, 500)
  ) RETURNING id INTO v_player;

  -- Attribute bias by position
  INSERT INTO player_attributes (
    player_id, speed, strength, agility, throw_power, throw_accuracy, catching, tackling, awareness, stamina, training_points
  )
  SELECT v_player,
         CASE WHEN p_pos IN ('WR','RB','CB','S') THEN hs_clampi(55 + v_stars*8 + hs_rnd_int(-3,6), 35, 95)
              WHEN p_pos IN ('QB') THEN hs_clampi(50 + v_stars*6 + hs_rnd_int(-3,5), 35, 95)
              ELSE hs_clampi(45 + v_stars*5 + hs_rnd_int(-4,5), 30, 95) END AS speed,
         CASE WHEN p_pos IN ('OL','DL','LB','TE') THEN hs_clampi(55 + v_stars*8 + hs_rnd_int(-3,6), 35, 95)
              ELSE hs_clampi(45 + v_stars*5 + hs_rnd_int(-4,5), 30, 95) END AS strength,
         hs_clampi(45 + v_stars*6 + hs_rnd_int(-3,5), 30, 95) AS agility,
         CASE WHEN p_pos='QB' THEN hs_clampi(45 + v_stars*8 + hs_rnd_int(0,10), 25, 95) ELSE hs_clampi(30 + v_stars*3 + hs_rnd_int(0,8), 20, 80) END AS throw_power,
         CASE WHEN p_pos='QB' THEN hs_clampi(45 + v_stars*8 + hs_rnd_int(0,10), 25, 95) ELSE hs_clampi(25 + v_stars*2 + hs_rnd_int(0,6), 15, 80) END AS throw_accuracy,
         CASE WHEN p_pos IN ('WR','TE','RB') THEN hs_clampi(45 + v_stars*7 + hs_rnd_int(0,8), 25, 95) ELSE hs_clampi(25 + v_stars*2 + hs_rnd_int(0,6), 15, 85) END AS catching,
         CASE WHEN p_pos IN ('LB','DL','S','CB') THEN hs_clampi(45 + v_stars*7 + hs_rnd_int(0,8), 25, 95) ELSE hs_clampi(20 + v_stars*2 + hs_rnd_int(0,6), 10, 85) END AS tackling,
         hs_clampi(40 + v_stars*5 + hs_rnd_int(-2,5), 20, 95) AS awareness,
         hs_clampi(45 + v_stars*4 + hs_rnd_int(-2,5), 20, 95) AS stamina,
         0;

  RETURN v_player;
END;
$$;

-- Generate a roster for a given team (target size with positional distribution)
CREATE OR REPLACE FUNCTION hs_generate_roster(p_team UUID, p_roster_size INT, p_year INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
  created INT := 0;
  rec RECORD;
  already INT;
  to_make INT;
BEGIN
  FOR rec IN
    SELECT * FROM hs_positions_distribution(p_roster_size)
  LOOP
    SELECT COUNT(*) INTO already FROM players WHERE team_id=p_team AND pos_code=rec.pos_code;
    to_make := GREATEST(0, rec.target - already);

    IF to_make > 0 THEN
      PERFORM 1;
      FOR i IN 1..to_make LOOP
        PERFORM hs_generate_player(p_team, rec.pos_code, p_year);
        created := created + 1;
      END LOOP;
    END IF;
  END LOOP;

  RETURN created;
END;
$$;

-- =========================================================
-- Depth chart builder
-- =========================================================

CREATE OR REPLACE FUNCTION hs_build_depth_chart(p_team UUID)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
  rec RECORD;
  inserted INT := 0;
BEGIN
  -- clear existing chart for team (dev-friendly)
  DELETE FROM depth_chart WHERE team_id = p_team;

  FOR rec IN
    SELECT pos_code, id AS player_id, rating,
           ROW_NUMBER() OVER (PARTITION BY pos_code ORDER BY rating DESC, id) AS rnk
    FROM players
    WHERE team_id = p_team
  LOOP
    INSERT INTO depth_chart (team_id, pos_code, player_id, depth_rank)
    VALUES (p_team, rec.pos_code, rec.player_id, rec.rnk);
    inserted := inserted + 1;
  END LOOP;

  RETURN inserted;
END;
$$;

-- =========================================================
-- HS pool & rankings seeding
-- =========================================================

CREATE OR REPLACE FUNCTION hs_seed_pool_for_season(p_season UUID)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
  v_league UUID;
  added INT := 0;
  rec RECORD;
  grade INT;
BEGIN
  SELECT league_id INTO v_league FROM seasons WHERE id=p_season;
  IF v_league IS NULL THEN
    RAISE EXCEPTION 'Season % not found', p_season;
  END IF;

  -- Add every HS player in league teams to the scouting pool with inferred grade
  FOR rec IN
    SELECT p.id AS player_id, p.class_year, t.id AS team_id
    FROM players p
    JOIN teams t ON t.id = p.team_id
    WHERE t.league_id = v_league
  LOOP
    grade := CASE rec.class_year
               WHEN 'Freshman'  THEN 9
               WHEN 'Sophomore' THEN 10
               WHEN 'Junior'    THEN 11
               WHEN 'Senior'    THEN 12
               ELSE 9 END;

    INSERT INTO hs_pool_player (season_id, class_year, player_id)
    VALUES (p_season, grade, rec.player_id)
    ON CONFLICT DO NOTHING;

    added := added + 1;
  END LOOP;

  RETURN added;
END;
$$;

-- =========================================================
-- All-in-one generator:
--   - ensure HS league
--   - ensure N teams
--   - ensure current season
--   - build rosters
--   - depth charts
--   - schedule round robin
--   - seed HS scouting pool
-- Returns season_id
-- =========================================================

CREATE OR REPLACE FUNCTION hs_bulk_generate(
  p_team_target INT DEFAULT 24,
  p_roster_size INT DEFAULT 48,
  p_year INT DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INT
) RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE
  v_league UUID;
  v_season UUID;
  t RECORD;
  created INT;
BEGIN
  v_league := hs_ensure_league();
  PERFORM hs_generate_teams(v_league, p_team_target);

  v_season := hs_get_or_create_current_season(v_league, p_year);

  -- Build out each team
  FOR t IN SELECT id FROM teams WHERE league_id = v_league LOOP
    PERFORM hs_generate_roster(t.id, p_roster_size, p_year);
    PERFORM hs_build_depth_chart(t.id);
  END LOOP;

  -- Schedule & standings
  PERFORM reschedule_round_robin(v_season, TRUE, NULL);
  PERFORM upsert_season_standings(v_season);

  -- HS scouting pool
  PERFORM hs_seed_pool_for_season(v_season);

  RAISE NOTICE 'HS generation complete. Season: %', v_season;
  RETURN v_season;
END;
$$;

-- =========================================================
-- Optional: one-shot data load for dev convenience
-- Commented by default. Uncomment to auto-generate on load.
-- =========================================================
-- DO $$
-- DECLARE v_sid UUID;
-- BEGIN
--   v_sid := hs_bulk_generate(24, 48);
--   RAISE NOTICE 'Generated HS season % with teams/rosters/schedule', v_sid;
-- END$$;
