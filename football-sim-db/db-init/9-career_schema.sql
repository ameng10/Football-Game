-- db-init/9-career_schema.sql
-- High-School Career Mode core structures (public schema)

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =========================================================
-- CAREER SAVE / PLAYER LINK / STATE / EVENT LOG
-- =========================================================

-- A single user save (manual or auto-named)
CREATE TABLE IF NOT EXISTS career_save (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_label  TEXT NOT NULL DEFAULT 'Local User',     -- optional display label
  name        TEXT NOT NULL,                          -- e.g., "My HS Career"
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The user-controlled player inside a save
-- Links to an existing row in public.players
CREATE TABLE IF NOT EXISTS career_player (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  save_id         UUID NOT NULL REFERENCES career_save(id) ON DELETE CASCADE,
  player_id       UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  stage           TEXT NOT NULL DEFAULT 'HS',         -- HS | College | Draft | Pro | Retired
  star_rating     INT  NOT NULL DEFAULT 3 CHECK (star_rating BETWEEN 0 AND 5),
  position_goal   TEXT NOT NULL,                      -- must map to positions.code (use FK below)
  grade_level     INT  NOT NULL DEFAULT 9 CHECK (grade_level BETWEEN 9 AND 12),
  followers       INT  NOT NULL DEFAULT 0,            -- IG followers for flavor/progression
  narrative       JSONB NOT NULL DEFAULT '{}'::jsonb, -- ad-hoc flags/counters
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (save_id, player_id)
);

-- Enforce position_goal against positions.code
ALTER TABLE career_player
  ADD CONSTRAINT fk_career_player_pos
  FOREIGN KEY (position_goal) REFERENCES positions(code);

-- Where the save currently lives (season/team + calendar phase)
CREATE TABLE IF NOT EXISTS career_state (
  save_id     UUID PRIMARY KEY REFERENCES career_save(id) ON DELETE CASCADE,
  season_id   UUID REFERENCES seasons(id) ON DELETE SET NULL,
  team_id     UUID REFERENCES teams(id)   ON DELETE SET NULL,   -- the HS team the player is on
  calendar    JSONB NOT NULL DEFAULT '{"phase":"preseason","week":0}'::jsonb,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Narrative feed / audit log for the save
CREATE TABLE IF NOT EXISTS career_event (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  save_id     UUID NOT NULL REFERENCES career_save(id) ON DELETE CASCADE,
  happened_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  kind        TEXT NOT NULL,     -- create|customize|offer|commit|game|award|practice|train|advance|system
  payload     JSONB NOT NULL     -- arbitrary context (ids, text, deltas)
);
CREATE INDEX IF NOT EXISTS idx_career_event_save ON career_event(save_id);
CREATE INDEX IF NOT EXISTS idx_career_event_kind ON career_event(kind);

-- =========================================================
-- COACH & PERSONA (minimal, independent of any separate "person" table)
-- =========================================================

-- Optional flavor for practice/rep promotion logic
CREATE TABLE IF NOT EXISTS coach_profile (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  team_id      UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  full_name    TEXT NOT NULL DEFAULT 'Head Coach',
  role         TEXT NOT NULL DEFAULT 'HC',
  personality  JSONB NOT NULL DEFAULT '{"discipline":0.5,"meritocracy":0.7,"media":0.4}'::jsonb,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_coach_profile_team ON coach_profile(team_id);

-- Practice sessions tied to a save/team/season; reps influence depth promotions
CREATE TABLE IF NOT EXISTS practice_session (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  save_id      UUID NOT NULL REFERENCES career_save(id) ON DELETE CASCADE,
  season_id    UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
  team_id      UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  grade        NUMERIC(5,2) NOT NULL CHECK (grade >= 0 AND grade <= 100),
  reps_earned  INT NOT NULL DEFAULT 0 CHECK (reps_earned >= 0),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_practice_session_save ON practice_session(save_id);
CREATE INDEX IF NOT EXISTS idx_practice_session_team ON practice_session(team_id);

-- =========================================================
-- TRAINING SESSIONS (distinct from training_log for analytics)
-- =========================================================

-- Optional detailed record for mini-games vs simulated training
CREATE TABLE IF NOT EXISTS training_session (
  id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  save_id   UUID NOT NULL REFERENCES career_save(id) ON DELETE CASCADE,
  mode      TEXT NOT NULL,                         -- 'qb_accuracy'|'rb_agility'|'wr_hands'|'generic'
  score     INT  NOT NULL DEFAULT 0,
  points    INT  NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_training_session_save ON training_session(save_id);

-- NOTE: The generic `training_log` table from 1-schema.sql continues to exist for
-- aggregate summaries; this table is just a more granular row-per-session record.

-- =========================================================
-- HS RANKINGS / SCOUTABLE POOLS
-- =========================================================

-- Class-year rankings snapshot including the user player and AI peers
CREATE TABLE IF NOT EXISTS player_ranking (
  season_id         UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
  player_id         UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  class_year        INT  NOT NULL CHECK (class_year BETWEEN 9 AND 12),
  rank_overall      INT,
  rank_pos          INT,
  score             NUMERIC(8,2),
  PRIMARY KEY (season_id, player_id)
);
CREATE INDEX IF NOT EXISTS idx_player_ranking_season ON player_ranking(season_id);

-- Big pool of HS players by class (so we can rank nationally)
CREATE TABLE IF NOT EXISTS hs_pool_player (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  season_id   UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
  class_year  INT  NOT NULL CHECK (class_year BETWEEN 9 AND 12),
  player_id   UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_hs_pool_season ON hs_pool_player(season_id);
CREATE INDEX IF NOT EXISTS idx_hs_pool_class ON hs_pool_player(class_year);

-- =========================================================
-- RECRUITING STORYLINES (complements recruiting_offers)
-- =========================================================

CREATE TABLE IF NOT EXISTS recruiting_story (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  save_id    UUID NOT NULL REFERENCES career_save(id) ON DELETE CASCADE,
  title      TEXT NOT NULL,
  content    TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_recruiting_story_save ON recruiting_story(save_id);

-- =========================================================
-- CONVENIENCE VIEWS FOR UI (read-only)
-- =========================================================

-- Career dashboard roll-up
CREATE OR REPLACE VIEW v_career_dashboard AS
SELECT
  cs.id                      AS save_id,
  cs.name                    AS save_name,
  cp.id                      AS career_player_id,
  cp.player_id,
  cp.stage,
  cp.star_rating,
  cp.position_goal,
  cp.grade_level,
  cp.followers,
  cst.season_id,
  cst.team_id,
  (cst.calendar->>'phase')   AS phase,
  (cst.calendar->>'week')::INT AS week
FROM career_save cs
JOIN career_player cp ON cp.save_id = cs.id
LEFT JOIN career_state cst ON cst.save_id = cs.id;

-- Depth chart convenience (joins existing public.depth_chart)
CREATE OR REPLACE VIEW v_depth_chart_team AS
SELECT
  d.team_id,
  t.name AS team_name,
  d.pos_code,
  d.depth_rank,
  d.player_id,
  p.first_name,
  p.last_name,
  p.rating
FROM depth_chart d
JOIN teams t   ON t.id = d.team_id
JOIN players p ON p.id = d.player_id
ORDER BY t.name, d.pos_code, d.depth_rank;

-- Recruiting board joined with career player for a save
CREATE OR REPLACE VIEW v_career_recruiting AS
SELECT
  r.id AS offer_id,
  s.id AS save_id,
  r.player_id,
  r.college_team_id,
  ct.name AS college_name,
  r.offer_date,
  r.committed
FROM recruiting_offers r
JOIN career_player cp ON cp.player_id = r.player_id
JOIN career_save s    ON s.id = cp.save_id
JOIN teams ct         ON ct.id = r.college_team_id;

-- =========================================================
-- SMALL SAFETY INDEXES (query hotpaths)
-- =========================================================
CREATE INDEX IF NOT EXISTS idx_career_state_team ON career_state(team_id);
CREATE INDEX IF NOT EXISTS idx_career_state_season ON career_state(season_id);
CREATE INDEX IF NOT EXISTS idx_career_player_player ON career_player(player_id);
CREATE INDEX IF NOT EXISTS idx_player_ranking_rank ON player_ranking(season_id, rank_overall);

-- Done.
