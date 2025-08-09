-- db-init/8-debug_reset.sql
SET client_min_messages = NOTICE;

-- =========================================================
-- Safety gates: ensure core tables exist before proceeding
-- =========================================================
DO $$
BEGIN
  PERFORM 1 FROM pg_class WHERE relname IN
  ('leagues','seasons','teams','players','player_attributes',
   'games','game_stats','season_stats','standings','playoffs',
   'recruiting_offers','depth_chart','awards','awards_assigned','training_log');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Core tables not found. Did you load 1-schema.sql?';
  END IF;
END$$;

-- =========================================================
-- SOFT RESET
--   Clears dynamic/simulated rows; keeps leagues/teams/players/awards
-- =========================================================
CREATE OR REPLACE FUNCTION debug_reset_soft()
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  RAISE NOTICE 'Soft reset: clearing dynamic tables...';

  -- child-first deletes to respect FKs
  DELETE FROM awards_assigned;      -- depends on seasons/awards
  DELETE FROM training_log;         -- player activity
  DELETE FROM recruiting_offers;    -- recruiting
  DELETE FROM depth_chart;          -- roster ordering
  DELETE FROM playoffs;             -- brackets
  DELETE FROM game_stats;           -- per-game stats
  DELETE FROM season_stats;         -- aggregates
  DELETE FROM games;                -- schedule/results
  DELETE FROM standings;            -- season standings

  RAISE NOTICE 'Soft reset complete.';
END;
$$;

-- =========================================================
-- HARD RESET
--   Nukes almost everything (keeps positions lookup; optionally keeps awards)
--   Useful when you want a totally fresh DB state.
-- =========================================================
CREATE OR REPLACE FUNCTION debug_reset_hard(p_keep_awards BOOLEAN DEFAULT TRUE)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  RAISE NOTICE 'Hard reset: deleting all gameplay data...';

  -- dynamic
  PERFORM debug_reset_soft();

  -- roster & seasons
  DELETE FROM player_attributes;
  DELETE FROM players;
  DELETE FROM seasons;
  DELETE FROM teams;
  DELETE FROM leagues;

  -- lookups
  IF NOT p_keep_awards THEN
    DELETE FROM awards;
  END IF;

  -- keep positions as canonical lookup
  RAISE NOTICE 'Hard reset complete. Awards kept: %', p_keep_awards;
END;
$$;

-- =========================================================
-- QUICK REBOOT OF A PLAYABLE HS SEASON
--   Recreates/ensures a HighSchool league + current season
--   Generates a round-robin schedule and standings
--   (Uses helpers from 5-functions-compat.sql)
-- =========================================================
CREATE OR REPLACE FUNCTION debug_bootstrap_hs_season(p_year INT DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INT)
RETURNS UUID
LANGUAGE plpgsql AS $$
DECLARE
  v_league UUID;
  v_season UUID;
  v_team_count INT;
  i INT;
BEGIN
  -- Ensure a HighSchool league exists
  SELECT id INTO v_league FROM leagues WHERE level='HighSchool' LIMIT 1;
  IF v_league IS NULL THEN
    INSERT INTO leagues (name, level) VALUES ('State High School League','HighSchool')
    RETURNING id INTO v_league;
    RAISE NOTICE 'Created HS league: %', v_league;
  END IF;

  -- Ensure at least 8 teams (lightweight placeholders if needed)
  SELECT COUNT(*) INTO v_team_count FROM teams WHERE league_id = v_league;
  IF v_team_count < 8 THEN
    RAISE NOTICE 'Creating % HS teams to reach 8 total...', 8 - v_team_count;
    i := 1;
    WHILE i <= (8 - v_team_count) LOOP
      INSERT INTO teams (league_id, name, city, mascot, prestige)
      VALUES (
        v_league,
        'HS Team ' || i::text,
        'City ' || i::text,
        'Hawks',
        35 + (random()*30)::int
      );
      i := i + 1;
    END LOOP;
  END IF;

  -- Create/get current season and schedule it
  v_season := get_or_create_season(v_league, p_year, TRUE);
  PERFORM reschedule_round_robin(v_season, TRUE, NULL);
  PERFORM upsert_season_standings(v_season);

  RAISE NOTICE 'HS season % ready for year %', v_season, p_year;
  RETURN v_season;
END;
$$;

-- =========================================================
-- OPTIONAL: run a soft reset + bootstrap in one go
--   Uncomment to execute on file load
-- =========================================================
-- DO $$
-- DECLARE v_sid UUID;
-- BEGIN
--   PERFORM debug_reset_soft();
--   v_sid := debug_bootstrap_hs_season();
--   RAISE NOTICE 'Bootstrapped HS season: %', v_sid;
-- END$$;

-- For a total wipe and rebuild:
-- DO $$
-- DECLARE v_sid UUID;
-- BEGIN
--   PERFORM debug_reset_hard(TRUE);          -- keep awards table
--   v_sid := debug_bootstrap_hs_season();
--   RAISE NOTICE 'Fresh HS season: %', v_sid;
-- END$$;
