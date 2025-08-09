-- db-init/6-sample_schedule.sql
-- Create a playable High School season with a full schedule

SET client_min_messages = NOTICE;

-- 1) Ensure a canonical HighSchool league exists
DO $$
DECLARE
  v_league_id UUID;
BEGIN
  SELECT id INTO v_league_id FROM leagues WHERE level = 'HighSchool' LIMIT 1;

  IF v_league_id IS NULL THEN
    INSERT INTO leagues (name, level)
    VALUES ('State High School League', 'HighSchool')
    RETURNING id INTO v_league_id;

    RAISE NOTICE 'Created HighSchool league: %', v_league_id;
  ELSE
    RAISE NOTICE 'Found HighSchool league: %', v_league_id;
  END IF;
END
$$;

-- 2) Make sure we have at least 8 HS teams
DO $$
DECLARE
  v_league_id UUID;
  v_count INT;
  i INT;
BEGIN
  SELECT id INTO v_league_id FROM leagues WHERE level = 'HighSchool' LIMIT 1;

  SELECT COUNT(*) INTO v_count FROM teams WHERE league_id = v_league_id;

  IF v_count < 8 THEN
    RAISE NOTICE 'Only % HS teams found; creating % more', v_count, 8 - v_count;

    i := 1;
    WHILE i <= (8 - v_count) LOOP
      INSERT INTO teams (league_id, name, city, mascot, prestige)
      VALUES (
        v_league_id,
        'HS Team ' || i::text,
        'City ' || i::text,
        'Hawks',
        35 + (random()*30)::int
      );
      i := i + 1;
    END LOOP;
  ELSE
    RAISE NOTICE 'HS teams sufficient: %', v_count;
  END IF;
END
$$;

-- 3) Create (or get) current season for the HS league, mark it current
DO $$
DECLARE
  v_league_id UUID;
  v_year INT := EXTRACT(YEAR FROM CURRENT_DATE)::INT;
  v_season_id UUID;
BEGIN
  SELECT id INTO v_league_id FROM leagues WHERE level = 'HighSchool' LIMIT 1;

  v_season_id := get_or_create_season(v_league_id, v_year, TRUE);
  RAISE NOTICE 'HighSchool season for % is %', v_year, v_season_id;
END
$$;

-- 4) Generate a round-robin schedule for that season (and ensure standings)
DO $$
DECLARE
  v_league_id UUID;
  v_year INT := EXTRACT(YEAR FROM CURRENT_DATE)::INT;
  v_season_id UUID;
  v_games INT;
BEGIN
  SELECT id INTO v_league_id FROM leagues WHERE level = 'HighSchool' LIMIT 1;
  SELECT id INTO v_season_id FROM seasons WHERE league_id = v_league_id AND year = v_year LIMIT 1;

  -- wipe any existing schedule for a clean sample, then recreate
  v_games := reschedule_round_robin(v_season_id, TRUE, NULL);

  PERFORM upsert_season_standings(v_season_id);

  RAISE NOTICE 'Scheduled % games for HS season %', v_games, v_season_id;
END
$$;

-- Optional: quick peek at schedule & standings
-- SELECT * FROM v_season_schedule LIMIT 20;
-- SELECT * FROM v_standings;
