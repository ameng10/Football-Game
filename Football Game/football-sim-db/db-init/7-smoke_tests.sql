-- db-init/7-smoke_tests.sql
SET client_min_messages = NOTICE;

-- =========================
-- 0) Sanity: required tables
-- =========================
DO $$
BEGIN
  PERFORM 1 FROM pg_class WHERE relname IN
    ('leagues','seasons','teams','players','player_attributes','games','game_stats','season_stats','standings');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Schema not loaded (missing core tables)';
  END IF;
END$$;

-- =========================
-- 1) Ensure HighSchool league
-- =========================
DO $$
DECLARE v_league UUID;
BEGIN
  SELECT id INTO v_league FROM leagues WHERE level='HighSchool' LIMIT 1;
  IF v_league IS NULL THEN
    INSERT INTO leagues (name, level) VALUES ('State High School League','HighSchool')
    RETURNING id INTO v_league;
    RAISE NOTICE 'Created HighSchool league: %', v_league;
  ELSE
    RAISE NOTICE 'Found HighSchool league: %', v_league;
  END IF;
END$$;

-- =========================
-- 2) Create (or fetch) current season
-- =========================
DO $$
DECLARE v_league UUID; v_season UUID; v_year INT := EXTRACT(YEAR FROM CURRENT_DATE)::INT;
BEGIN
  SELECT id INTO v_league FROM leagues WHERE level='HighSchool' LIMIT 1;
  v_season := get_or_create_season(v_league, v_year, TRUE);
  IF v_season IS NULL THEN
    RAISE EXCEPTION 'Could not create or fetch HS season';
  END IF;
  RAISE NOTICE 'HS season % for year % ready', v_season, v_year;
END$$;

-- =========================
-- 3) Ensure two teams exist
-- =========================
DO $$
DECLARE v_league UUID; t1 UUID; t2 UUID;
BEGIN
  SELECT id INTO v_league FROM leagues WHERE level='HighSchool' LIMIT 1;

  SELECT id INTO t1 FROM teams WHERE league_id=v_league AND name='Test HS A' LIMIT 1;
  IF t1 IS NULL THEN
    INSERT INTO teams (league_id, name, city, mascot, prestige)
    VALUES (v_league, 'Test HS A', 'Alpha', 'Lions', 45) RETURNING id INTO t1;
  END IF;

  SELECT id INTO t2 FROM teams WHERE league_id=v_league AND name='Test HS B' LIMIT 1;
  IF t2 IS NULL THEN
    INSERT INTO teams (league_id, name, city, mascot, prestige)
    VALUES (v_league, 'Test HS B', 'Bravo', 'Wolves', 48) RETURNING id INTO t2;
  END IF;

  RAISE NOTICE 'Teams: % and %', t1, t2;
END$$;

-- =========================
-- 4) Add key players + attributes (QB/RB/WR) for both teams (if missing)
-- =========================
DO $$
DECLARE
  v_year INT := EXTRACT(YEAR FROM CURRENT_DATE)::INT;
  t RECORD;
  p_id UUID;
BEGIN
  FOR t IN
    SELECT id AS team_id, name FROM teams
    WHERE name IN ('Test HS A','Test HS B')
  LOOP
    -- QB
    SELECT id INTO p_id FROM players WHERE team_id=t.team_id AND pos_code='QB' LIMIT 1;
    IF p_id IS NULL THEN
      INSERT INTO players (team_id, first_name, last_name, pos_code, birth_date, stars, rating, potential, class_year, followers)
      VALUES (t.team_id, 'Test', 'QB', 'QB', make_date(v_year-16,1,1), 3, 68, 85, 'Senior', 100)
      RETURNING id INTO p_id;
      INSERT INTO player_attributes (player_id, speed, agility, awareness, throw_power, throw_accuracy, stamina, strength, catching, tackling, training_points)
      VALUES (p_id, 60,62,60,72,73,65,55,40,35,0);
    END IF;

    -- RB
    SELECT id INTO p_id FROM players WHERE team_id=t.team_id AND pos_code='RB' LIMIT 1;
    IF p_id IS NULL THEN
      INSERT INTO players (team_id, first_name, last_name, pos_code, birth_date, stars, rating, potential, class_year, followers)
      VALUES (t.team_id, 'Test', 'RB', 'RB', make_date(v_year-16,2,1), 3, 66, 84, 'Senior', 80)
      RETURNING id INTO p_id;
      INSERT INTO player_attributes (player_id, speed, agility, awareness, throw_power, throw_accuracy, stamina, strength, catching, tackling)
      VALUES (p_id, 70,68,58,40,40,66,58,50,45);
    END IF;

    -- WR
    SELECT id INTO p_id FROM players WHERE team_id=t.team_id AND pos_code='WR' LIMIT 1;
    IF p_id IS NULL THEN
      INSERT INTO players (team_id, first_name, last_name, pos_code, birth_date, stars, rating, potential, class_year, followers)
      VALUES (t.team_id, 'Test', 'WR', 'WR', make_date(v_year-16,3,1), 3, 65, 83, 'Senior', 70)
      RETURNING id INTO p_id;
      INSERT INTO player_attributes (player_id, speed, agility, awareness, throw_power, throw_accuracy, stamina, strength, catching, tackling)
      VALUES (p_id, 72,69,57,35,40,64,50,68,35);
    END IF;
  END LOOP;

  RAISE NOTICE 'Players ensured for both teams.';
END$$;

-- =========================
-- 5) Schedule a single test game (Week 1) and simulate it
-- =========================
DO $$
DECLARE
  v_league UUID; v_season UUID; v_year INT := EXTRACT(YEAR FROM CURRENT_DATE)::INT;
  t1 UUID; t2 UUID; g UUID;
BEGIN
  SELECT id INTO v_league FROM leagues WHERE level='HighSchool' LIMIT 1;
  SELECT id INTO v_season FROM seasons WHERE league_id=v_league AND year=v_year LIMIT 1;

  SELECT id INTO t1 FROM teams WHERE league_id=v_league AND name='Test HS A' LIMIT 1;
  SELECT id INTO t2 FROM teams WHERE league_id=v_league AND name='Test HS B' LIMIT 1;

  -- Ensure standings rows
  INSERT INTO standings (season_id, team_id) VALUES (v_season, t1)
    ON CONFLICT (season_id, team_id) DO NOTHING;
  INSERT INTO standings (season_id, team_id) VALUES (v_season, t2)
    ON CONFLICT (season_id, team_id) DO NOTHING;

  -- Create or reuse a Week 1 game
  SELECT id INTO g FROM games
  WHERE season_id=v_season AND week=1 AND home_team_id=t1 AND away_team_id=t2 LIMIT 1;

  IF g IS NULL THEN
    INSERT INTO games (season_id, week, date, home_team_id, away_team_id, status, played)
    VALUES (v_season, 1, CURRENT_DATE, t1, t2, 'Scheduled', FALSE)
    RETURNING id INTO g;
  END IF;

  -- Simulate
  PERFORM simulate_game(g);

  -- Check final status
  PERFORM 1 FROM games WHERE id=g AND played=TRUE AND status='Final';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game % did not finalize correctly', g;
  END IF;

  RAISE NOTICE 'Simulated game % OK', g;
END$$;

-- =========================
-- 6) Verify standings updated
-- =========================
DO $$
DECLARE
  v_league UUID; v_season UUID; v_year INT := EXTRACT(YEAR FROM CURRENT_DATE)::INT;
  t1 UUID; t2 UUID; w1 INT; l1 INT; w2 INT; l2 INT;
BEGIN
  SELECT id INTO v_league FROM leagues WHERE level='HighSchool' LIMIT 1;
  SELECT id INTO v_season FROM seasons WHERE league_id=v_league AND year=v_year LIMIT 1;
  SELECT id INTO t1 FROM teams WHERE league_id=v_league AND name='Test HS A' LIMIT 1;
  SELECT id INTO t2 FROM teams WHERE league_id=v_league AND name='Test HS B' LIMIT 1;

  SELECT wins, losses INTO w1, l1 FROM standings WHERE season_id=v_season AND team_id=t1;
  SELECT wins, losses INTO w2, l2 FROM standings WHERE season_id=v_season AND team_id=t2;

  IF (w1 + l1) = 0 OR (w2 + l2) = 0 THEN
    RAISE EXCEPTION 'Standings did not update for teams % and %', t1, t2;
  END IF;

  RAISE NOTICE 'Standings updated: TeamA W-L %-% | TeamB W-L %-%', w1, l1, w2, l2;
END$$;

-- =========================
-- 7) Verify season_stats aggregated from game_stats
-- =========================
DO $$
DECLARE
  v_league UUID; v_season UUID; v_year INT := EXTRACT(YEAR FROM CURRENT_DATE)::INT;
  any_rows INT;
BEGIN
  SELECT id INTO v_league FROM leagues WHERE level='HighSchool' LIMIT 1;
  SELECT id INTO v_season FROM seasons WHERE league_id=v_league AND year=v_year LIMIT 1;

  SELECT COUNT(*) INTO any_rows
  FROM season_stats s
  WHERE s.season_id = v_season;

  IF COALESCE(any_rows,0) = 0 THEN
    RAISE EXCEPTION 'No season_stats rows found after simulation (trigger may have failed)';
  END IF;

  RAISE NOTICE 'Season stats rows present: %', any_rows;
END$$;

-- =========================
-- 8) Optional: show a quick summary
-- =========================
-- SELECT * FROM v_season_schedule ORDER BY week LIMIT 10;
-- SELECT * FROM v_standings ORDER BY wins DESC, points_for - points_against DESC LIMIT 10;
-- SELECT p.first_name, p.last_name, s.*
-- FROM season_stats s JOIN players p ON p.id = s.player_id
-- ORDER BY pass_yards DESC NULLS LAST, rush_yards DESC NULLS LAST, rec_yards DESC NULLS LAST
-- LIMIT 10;
