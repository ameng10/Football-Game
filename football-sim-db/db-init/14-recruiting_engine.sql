-- db-init/14-recruiting_engine.sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
SET client_min_messages = NOTICE;

-- =========================================================
-- TABLES
-- =========================================================

-- Per-season, per-college, per-player recruiting board row
CREATE TABLE IF NOT EXISTS recruiting_interest (
  season_id       UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
  player_id       UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  college_team_id UUID NOT NULL REFERENCES teams(id)   ON DELETE CASCADE,
  -- dynamics
  interest        NUMERIC(6,2) NOT NULL DEFAULT 0,     -- 0..100 scale
  scholarship     BOOLEAN NOT NULL DEFAULT FALSE,
  visit_week      INT,                                 -- planned official visit week (season week)
  visited         BOOLEAN NOT NULL DEFAULT FALSE,      -- visit completed flag
  nil_amount_k    INT NOT NULL DEFAULT 0,              -- NIL dollars (thousands)
  last_event      TEXT,                                -- short note for UI
  last_update     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, player_id, college_team_id)
);
CREATE INDEX IF NOT EXISTS idx_recruiting_interest_player ON recruiting_interest(player_id);
CREATE INDEX IF NOT EXISTS idx_recruiting_interest_team   ON recruiting_interest(college_team_id);

-- Narrative log for recruiting feed
CREATE TABLE IF NOT EXISTS recruiting_events (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  season_id  UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
  player_id  UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  team_id    UUID REFERENCES teams(id) ON DELETE SET NULL,  -- college team
  week       INT,
  kind       TEXT NOT NULL,                                 -- 'offer'|'visit'|'commit'|'decommit'|'interest'
  note       TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_recruiting_events_player ON recruiting_events(player_id);
CREATE INDEX IF NOT EXISTS idx_recruiting_events_team   ON recruiting_events(team_id);
CREATE INDEX IF NOT EXISTS idx_recruiting_events_season ON recruiting_events(season_id);

-- Optional NIL offers table (single best active per team/player)
CREATE TABLE IF NOT EXISTS recruiting_nil_offer (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  season_id     UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
  player_id     UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  college_team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  amount_k      INT NOT NULL DEFAULT 0, -- thousands
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (season_id, player_id, college_team_id)
);

-- Make sure recruiting_offers has uniqueness on (player,college) for sanity
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'ux_recruiting_offers_player_college'
  ) THEN
    CREATE UNIQUE INDEX ux_recruiting_offers_player_college
      ON recruiting_offers(player_id, college_team_id);
  END IF;
END$$;

-- =========================================================
-- HELPERS
-- =========================================================

-- Safe division numeric
CREATE OR REPLACE FUNCTION rec_safe_div(n NUMERIC, d NUMERIC, z NUMERIC DEFAULT 0)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE WHEN d IS NULL OR d=0 THEN z ELSE n/d END;
$$;

-- Normalize/resolve league ids
CREATE OR REPLACE FUNCTION rec_league_id(p_level TEXT)
RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT id FROM leagues
  WHERE level = CASE
                  WHEN LOWER($1) IN ('hs','highschool','high school') THEN 'HighSchool'
                  WHEN LOWER($1) IN ('college','ncaa') THEN 'College'
                  WHEN LOWER($1) IN ('pro','nfl','professional') THEN 'Pro'
                  ELSE $1
                END
  LIMIT 1;
$$;

-- Current season for league
CREATE OR REPLACE FUNCTION rec_current_season_id(p_level TEXT)
RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT s.id
  FROM seasons s
  JOIN leagues l ON l.id = s.league_id
  WHERE l.level = CASE
                    WHEN LOWER($1) IN ('hs','highschool','high school') THEN 'HighSchool'
                    WHEN LOWER($1) IN ('college','ncaa') THEN 'College'
                    WHEN LOWER($1) IN ('pro','nfl','professional') THEN 'Pro'
                    ELSE $1
                  END
    AND s.current = TRUE
  LIMIT 1;
$$;

-- Simple same-city proximity bonus (0 or 1); extend later with geo if needed
CREATE OR REPLACE FUNCTION rec_proximity_bonus(p_hs_team UUID, p_college_team UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN LOWER(th.city) = LOWER(tc.city) AND th.city IS NOT NULL AND tc.city IS NOT NULL
             THEN 1.0 ELSE 0.0
         END
  FROM teams th, teams tc
  WHERE th.id = p_hs_team AND tc.id = p_college_team;
$$;

-- Position need score for a college team at a given position (0..1)
-- Uses depth_chart counts: fewer top players => higher need
CREATE OR REPLACE FUNCTION rec_position_need(p_college_team UUID, p_pos TEXT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE
  have_top INT;
  target INT;
BEGIN
  -- Count first 3 depth spots as "top" at that position
  SELECT COUNT(*) INTO have_top
  FROM depth_chart d
  JOIN players p ON p.id = d.player_id
  WHERE d.team_id = p_college_team
    AND (d.pos_code = p_pos OR (p_pos IN ('WR','TE') AND d.pos_code IN ('WR','TE')))
    AND d.depth_rank <= 3;

  -- Target starters + depth (heuristic) per position family
  target := CASE
    WHEN p_pos = 'QB' THEN 2
    WHEN p_pos = 'RB' THEN 3
    WHEN p_pos IN ('WR','TE') THEN 5
    WHEN p_pos = 'OL' THEN 8
    WHEN p_pos = 'DL' THEN 6
    WHEN p_pos = 'LB' THEN 5
    WHEN p_pos IN ('CB','S') THEN 5
    ELSE 2
  END;

  RETURN GREATEST(0, LEAST(1, 1 - rec_safe_div(have_top::numeric, NULLIF(target,0), 0)));
END;
$$;

-- Pull coach personality (meritocracy/media/discipline) as small biases (0..1)
CREATE OR REPLACE FUNCTION rec_coach_bias(p_team UUID, p_key TEXT)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE( (coach_profile.personality->>$2)::numeric, 0.5 )
  FROM coach_profile
  WHERE team_id = $1
  ORDER BY created_at DESC
  LIMIT 1;
$$;

-- =========================================================
-- BOARD BUILD / REFRESH
-- =========================================================

/*
  rec_build_board(p_college_season UUID, p_targets_per_team INT DEFAULT 20)
  - Ensures a recruiting board for every College team in the season.
  - Pulls HS seniors from the *current HS season* scouting pool and creates
    interest rows weighted by: player ranking/ratings, team prestige, position need,
    proximity, and coach bias.
*/
CREATE OR REPLACE FUNCTION rec_build_board(p_college_season UUID, p_targets_per_team INT DEFAULT 20)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
  v_college_league UUID;
  v_year INT;
  v_hs_season UUID;
  t RECORD;
  created INT := 0;
BEGIN
  -- Resolve college league + year
  SELECT league_id, year INTO v_college_league, v_year FROM seasons WHERE id = p_college_season;
  IF v_college_league IS NULL THEN
    RAISE EXCEPTION 'Season % not found', p_college_season;
  END IF;

  -- Get current HS season (source of seniors)
  v_hs_season := rec_current_season_id('HighSchool');
  IF v_hs_season IS NULL THEN
    -- Create HS season with generator if missing? For now, require it.
    RAISE EXCEPTION 'No current HighSchool season found. Generate HS season first.';
  END IF;

  -- For each college team, select top HS seniors by composite score
  FOR t IN SELECT id AS team_id, prestige FROM teams WHERE league_id = v_college_league LOOP
    WITH seniors AS (
      SELECT p.id AS player_id, p.team_id AS hs_team_id, p.pos_code, p.stars, p.rating,
             pr.rank_overall, pr.score AS rank_score
      FROM hs_pool_player hp
      JOIN players p ON p.id = hp.player_id
      LEFT JOIN player_ranking pr ON pr.player_id = p.id AND pr.season_id = hp.season_id
      WHERE hp.season_id = v_hs_season
        AND hp.class_year = 12 -- seniors
    ),
    scored AS (
      SELECT s.player_id,
             s.hs_team_id,
             s.pos_code,
             s.stars, s.rating,
             COALESCE(s.rank_score, (s.rating - 50)) AS rank_score,
             -- composite:
             ( COALESCE(s.rank_score, (s.rating - 50)) * 0.55
               + (t.prestige * 0.15)
               + (rec_position_need(t.team_id, s.pos_code) * 25.0)
               + (rec_proximity_bonus(s.hs_team_id, t.team_id) * 5.0)
               + ((rec_coach_bias(t.team_id,'meritocracy') - 0.5) * 4.0)
             ) AS composite
      FROM seniors s, (SELECT $1::uuid AS team_id, $2::int AS prestige) t
    ),
    picked AS (
      SELECT * FROM scored
      ORDER BY composite DESC, stars DESC, rating DESC, player_id
      LIMIT GREATEST(5, $3) -- at least 5
    )
    INSERT INTO recruiting_interest (season_id, player_id, college_team_id, interest, last_event)
    SELECT p_college_season, player_id, t.team_id,
           GREATEST(5, LEAST(25, 10 + (composite/10.0)))::numeric(6,2), -- starting interest
           'board:init'
    FROM picked
    ON CONFLICT (season_id, player_id, college_team_id) DO NOTHING;

    GET DIAGNOSTICS created = created + ROW_COUNT;
  END LOOP;

  RETURN created;
END;
$$;

-- Refresh/expand boards (re-run scoring and insert missing rows)
CREATE OR REPLACE FUNCTION rec_refresh_board(p_college_season UUID, p_targets_per_team INT DEFAULT 20)
RETURNS INT LANGUAGE plpgsql AS $$
BEGIN
  RETURN rec_build_board(p_college_season, p_targets_per_team);
END;
$$;

-- =========================================================
-- ACTIONS: OFFERS / VISITS / NIL
-- =========================================================

-- Offer a scholarship (and log + mirror to recruiting_offers)
CREATE OR REPLACE FUNCTION rec_offer_scholarship(p_college_season UUID, p_team UUID, p_player UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO recruiting_interest (season_id, player_id, college_team_id, scholarship, last_event)
  VALUES (p_college_season, p_player, p_team, TRUE, 'offer:scholarship')
  ON CONFLICT (season_id, player_id, college_team_id)
  DO UPDATE SET scholarship = TRUE, last_event = 'offer:scholarship', last_update = now();

  INSERT INTO recruiting_offers (player_id, college_team_id, committed)
  VALUES (p_player, p_team, FALSE)
  ON CONFLICT (player_id, college_team_id) DO NOTHING;

  INSERT INTO recruiting_events (season_id, player_id, team_id, kind, note)
  VALUES (p_college_season, p_player, p_team, 'offer', 'Scholarship offered');
END;
$$;

-- Schedule an official visit for a given season week
CREATE OR REPLACE FUNCTION rec_schedule_visit(p_college_season UUID, p_team UUID, p_player UUID, p_week INT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  UPDATE recruiting_interest
  SET visit_week = p_week, last_event = 'visit:scheduled', last_update = now()
  WHERE season_id = p_college_season AND player_id = p_player AND college_team_id = p_team;

  INSERT INTO recruiting_events (season_id, player_id, team_id, week, kind, note)
  VALUES (p_college_season, p_player, p_team, p_week, 'visit', 'Official visit scheduled');
END;
$$;

-- Set/replace a NIL offer
CREATE OR REPLACE FUNCTION rec_set_nil(p_college_season UUID, p_team UUID, p_player UUID, p_amount_k INT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO recruiting_nil_offer (season_id, player_id, college_team_id, amount_k)
  VALUES (p_college_season, p_player, p_team, GREATEST(0,p_amount_k))
  ON CONFLICT (season_id, player_id, college_team_id)
  DO UPDATE SET amount_k = EXCLUDED.amount_k;

  UPDATE recruiting_interest
  SET nil_amount_k = GREATEST(0,p_amount_k), last_event = 'nil:set', last_update = now()
  WHERE season_id = p_college_season AND player_id = p_player AND college_team_id = p_team;

  INSERT INTO recruiting_events (season_id, player_id, team_id, kind, note)
  VALUES (p_college_season, p_player, p_team, 'interest', 'NIL updated to $'||p_amount_k||'k');
END;
$$;

-- =========================================================
-- WEEKLY ENGINE
-- =========================================================

/*
  rec_tick_week(p_college_season UUID, p_week INT, p_is_signing_week BOOLEAN DEFAULT FALSE)
  - Applies weekly interest deltas:
    * + base bump for scholarship, + visit spike on visit week, + NIL scaled
    * + prestige halo, + position need trickle, + proximity trickle
    * - decay vs other offers (competition)
  - If signing_week or interest >= 90, commits player to the leader.
*/
CREATE OR REPLACE FUNCTION rec_tick_week(p_college_season UUID, p_week INT, p_is_signing_week BOOLEAN DEFAULT FALSE)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_college_league UUID;
  v_total_rows INT := 0;
  v_commits INT := 0;
  r RECORD;
  lead RECORD;
  comp INT;
BEGIN
  SELECT league_id INTO v_college_league FROM seasons WHERE id = p_college_season;
  IF v_college_league IS NULL THEN
    RAISE EXCEPTION 'Season % not found', p_college_season;
  END IF;

  -- Iterate all rows for this season
  FOR r IN
    SELECT ri.*, p.team_id AS hs_team_id, pl.pos_code, t.prestige
    FROM recruiting_interest ri
    JOIN players pl ON pl.id = ri.player_id
    LEFT JOIN teams t ON t.id = ri.college_team_id
    LEFT JOIN players p ON p.id = ri.player_id
    WHERE ri.season_id = p_college_season
  LOOP
    v_total_rows := v_total_rows + 1;

    -- components
    -- scholarship bump
    r.interest := r.interest + CASE WHEN r.scholarship THEN 2.5 ELSE 0.8 END;

    -- visit spike (only once)
    IF r.visit_week IS NOT NULL AND r.visit_week = p_week AND NOT r.visited THEN
      r.interest := r.interest + 8.0;
      r.visited := TRUE;
      INSERT INTO recruiting_events (season_id, player_id, team_id, week, kind, note)
      VALUES (p_college_season, r.player_id, r.college_team_id, p_week, 'visit', 'Official visit completed');
    END IF;

    -- NIL scaled (diminishing returns)
    r.interest := r.interest + LEAST(6.0, r.nil_amount_k / 50.0);

    -- team prestige halo
    r.interest := r.interest + COALESCE(r.prestige,40) / 200.0;

    -- position need trickle
    r.interest := r.interest + rec_position_need(r.college_team_id, r.pos_code) * 1.8;

    -- proximity trickle
    r.interest := r.interest + rec_proximity_bonus(r.hs_team_id, r.college_team_id) * 0.8;

    -- competition decay: if player has >4 offers, slight dilution
    SELECT COUNT(*) INTO comp
    FROM recruiting_interest
    WHERE season_id = p_college_season AND player_id = r.player_id AND scholarship = TRUE;
    IF comp >= 5 THEN
      r.interest := r.interest - (comp - 4) * 0.9;
    END IF;

    -- clamp 0..100
    r.interest := GREATEST(0, LEAST(100, r.interest));

    UPDATE recruiting_interest
    SET interest = r.interest, visited = r.visited, last_event = 'tick:'||p_week, last_update = now()
    WHERE season_id = p_college_season AND player_id = r.player_id AND college_team_id = r.college_team_id;
  END LOOP;

  -- Commit logic:
  -- If signing week -> everyone commits to top interest.
  -- Otherwise, auto-commit players whose top team interest >= 90 and ahead by 5+ points.
  FOR r IN
    SELECT player_id
    FROM recruiting_interest
    WHERE season_id = p_college_season
    GROUP BY player_id
  LOOP
    -- leader row
    SELECT college_team_id, interest
    INTO lead
    FROM recruiting_interest
    WHERE season_id = p_college_season AND player_id = r.player_id
    ORDER BY interest DESC, scholarship DESC, nil_amount_k DESC
    LIMIT 1;

    IF lead.college_team_id IS NULL THEN CONTINUE; END IF;

    IF p_is_signing_week THEN
      PERFORM rec_commit_player(p_college_season, r.player_id, lead.college_team_id, p_week, TRUE);
      v_commits := v_commits + 1;
    ELSE
      -- check margin over #2
      PERFORM 1;
      WITH top2 AS (
        SELECT interest
        FROM recruiting_interest
        WHERE season_id = p_college_season AND player_id = r.player_id
        ORDER BY interest DESC
        LIMIT 2
      )
      SELECT CASE WHEN COUNT(*)=2 THEN (MAX(interest) - MIN(interest)) ELSE 100 END
      FROM top2
      INTO comp;

      IF lead.interest >= 90 AND comp >= 5 THEN
        PERFORM rec_commit_player(p_college_season, r.player_id, lead.college_team_id, p_week, FALSE);
        v_commits := v_commits + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('rows_processed', v_total_rows, 'commits', v_commits);
END;
$$;

-- Internal: commit a player (updates recruiting_offers + players.team_id for college stage)
CREATE OR REPLACE FUNCTION rec_commit_player(p_college_season UUID, p_player UUID, p_team UUID, p_week INT, p_signing BOOLEAN)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  -- mark committed in recruiting_offers
  UPDATE recruiting_offers
  SET committed = TRUE
  WHERE player_id = p_player AND college_team_id = p_team;

  -- log
  INSERT INTO recruiting_events (season_id, player_id, team_id, week, kind, note)
  VALUES (p_college_season, p_player, p_team, p_week, 'commit',
          CASE WHEN p_signing THEN 'Signing Day commit' ELSE 'Verbal commit' END);

  -- Optionally move player to college team only at the *end* of HS season; keep HS roster during HS games.
  -- If you prefer immediate transfer, uncomment:
  -- UPDATE players SET team_id = p_team WHERE id = p_player;
END;
$$;

-- =========================================================
-- VIEWS for UI
-- =========================================================

-- Board per college team with rank of targets
CREATE OR REPLACE VIEW v_recruiting_board_team AS
SELECT
  ri.season_id,
  ri.college_team_id AS team_id,
  t.name AS team_name,
  ri.player_id,
  p.first_name, p.last_name, p.pos_code, p.stars, p.rating,
  ri.interest, ri.scholarship, ri.visit_week, ri.visited, ri.nil_amount_k, ri.last_event, ri.last_update,
  RANK() OVER (PARTITION BY ri.college_team_id ORDER BY ri.interest DESC, ri.scholarship DESC, ri.nil_amount_k DESC) AS team_rank
FROM recruiting_interest ri
JOIN teams t   ON t.id = ri.college_team_id
JOIN players p ON p.id = ri.player_id;

-- Player-centric board: list top N teams for a player
CREATE OR REPLACE VIEW v_recruiting_board_player AS
SELECT
  ri.season_id,
  ri.player_id,
  p.first_name, p.last_name, p.pos_code, p.stars, p.rating,
  ri.college_team_id AS team_id,
  t.name AS team_name,
  ri.interest, ri.scholarship, ri.visit_week, ri.visited, ri.nil_amount_k, ri.last_event, ri.last_update,
  RANK() OVER (PARTITION BY ri.player_id ORDER BY ri.interest DESC, ri.scholarship DESC, ri.nil_amount_k DESC) AS player_rank
FROM recruiting_interest ri
JOIN teams t   ON t.id = ri.college_team_id
JOIN players p ON p.id = ri.player_id;

-- Simple commitments view (from recruiting_offers)
CREATE OR REPLACE VIEW v_commitments AS
SELECT
  ro.player_id,
  p.first_name || ' ' || p.last_name AS player_name,
  p.pos_code, p.stars, p.rating,
  ro.college_team_id AS team_id,
  t.name AS team_name,
  ro.committed,
  ro.offer_date
FROM recruiting_offers ro
JOIN players p ON p.id = ro.player_id
JOIN teams t   ON t.id = ro.college_team_id
WHERE ro.committed = TRUE;

-- =========================================================
-- ORCHESTRATION SHORTCUTS
-- =========================================================

-- Build college recruiting boards for the current College season (ensure one exists)
CREATE OR REPLACE FUNCTION recruiting_bootstrap(p_targets_per_team INT DEFAULT 20)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
  v_col_season UUID := rec_current_season_id('College');
  v_created INT := 0;
BEGIN
  IF v_col_season IS NULL THEN
    -- create a bare college season if missing (no schedule needed for recruiting tests)
    INSERT INTO leagues (name, level) VALUES ('NCAA Generic','College')
    ON CONFLICT DO NOTHING;

    v_col_season := get_or_create_season(rec_league_id('College'),
                                         EXTRACT(YEAR FROM CURRENT_DATE)::INT, TRUE);
  END IF;

  v_created := rec_build_board(v_col_season, p_targets_per_team);
  RETURN v_created;
END;
$$;

-- Advance one recruiting week for the current College season
CREATE OR REPLACE FUNCTION recruiting_advance_week(p_is_signing_week BOOLEAN DEFAULT FALSE)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_col_season UUID := rec_current_season_id('College');
  v_week INT := COALESCE((SELECT MAX(week) FROM games WHERE season_id = v_col_season), 0) + 1;
BEGIN
  IF v_col_season IS NULL THEN
    RAISE EXCEPTION 'No College season found';
  END IF;
  RETURN rec_tick_week(v_col_season, v_week, p_is_signing_week);
END;
$$;

-- =========================================================
-- OPTIONAL QUICK TESTS (commented out)
-- =========================================================
-- -- Build HS ecosystem first (from file 11), then:
-- -- 1) Ensure College season + board
-- -- SELECT recruiting_bootstrap(25);
-- -- 2) Offer some scholarships
-- -- SELECT rec_offer_scholarship( rec_current_season_id('College'),
-- --         (SELECT id FROM teams WHERE league_id = rec_league_id('College') ORDER BY prestige DESC LIMIT 1),
-- --         (SELECT player_id FROM v_recruiting_board_team ORDER BY team_rank LIMIT 1) );
-- -- 3) Schedule visits and set NIL
-- -- SELECT rec_schedule_visit(rec_current_season_id('College'),
-- --         (SELECT team_id FROM v_recruiting_board_team ORDER BY team_rank LIMIT 1),
-- --         (SELECT player_id FROM v_recruiting_board_team ORDER BY team_rank LIMIT 1), 12);
-- -- SELECT rec_set_nil(rec_current_season_id('College'),
-- --         (SELECT team_id FROM v_recruiting_board_team ORDER BY team_rank LIMIT 1),
-- --         (SELECT player_id FROM v_recruiting_board_team ORDER BY team_rank LIMIT 1), 150);
-- -- 4) Advance some weeks, then signing day
-- -- SELECT recruiting_advance_week(FALSE);
-- -- SELECT recruiting_advance_week(FALSE);
-- -- SELECT recruiting_advance_week(TRUE);  -- signing week: force commits to leaders
