-- db-init/15-depth_chart_logic.sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
SET client_min_messages = NOTICE;

-- =========================================
-- SAFETY: constraints & indexes (if missing)
-- =========================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'ux_depth_chart_unique_lane'
  ) THEN
    ALTER TABLE depth_chart
    ADD CONSTRAINT ux_depth_chart_unique_lane
      UNIQUE (team_id, pos_code, depth_rank);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND indexname='idx_depth_chart_team_pos'
  ) THEN
    CREATE INDEX idx_depth_chart_team_pos ON depth_chart(team_id, pos_code);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND indexname='idx_depth_chart_player'
  ) THEN
    CREATE UNIQUE INDEX idx_depth_chart_player ON depth_chart(player_id);
  END IF;
END$$;

-- =========================================
-- HELPERS
-- =========================================

-- Clamp int
CREATE OR REPLACE FUNCTION dc_clampi(x INT, lo INT, hi INT)
RETURNS INT LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT GREATEST(lo, LEAST(hi, x));
$$;

-- Optional availability flag:
-- If your schema later adds players.injured BOOLEAN or players.status TEXT,
-- this accessor will degrade gracefully (treat as available if column missing).
CREATE OR REPLACE FUNCTION dc_is_available(p_player UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE AS $$
DECLARE avail BOOLEAN := TRUE;
BEGIN
  -- Try injured boolean
  BEGIN
    EXECUTE 'SELECT NOT COALESCE(injured, FALSE) FROM players WHERE id = $1'
      INTO avail USING p_player;
    IF avail IS NOT NULL THEN RETURN avail; END IF;
  EXCEPTION WHEN undefined_column THEN
    -- ignore, try status
  END;

  -- Try status != 'Out'
  BEGIN
    EXECUTE $$SELECT CASE WHEN LOWER(COALESCE(status,'')) IN ('out','injured','suspended') THEN FALSE ELSE TRUE END
             FROM players WHERE id = $1$$
      INTO avail USING p_player;
    IF avail IS NOT NULL THEN RETURN avail; END IF;
  EXCEPTION WHEN undefined_column THEN
    -- ignore, default TRUE
  END;

  RETURN TRUE;
END;
$$;

-- Coach meritocracy bias (0..1), default 0.7
CREATE OR REPLACE FUNCTION dc_coach_meritocracy(p_team UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE((personality->>'meritocracy')::numeric, 0.7)
  FROM coach_profile
  WHERE team_id = $1
  ORDER BY created_at DESC
  LIMIT 1;
$$;

-- =========================================
-- CORE: REBUILD TEAM DEPTH CHART
-- Re-seeds depth ranks per position by rating, honoring availability
-- =========================================
CREATE OR REPLACE FUNCTION dc_rebuild_team(p_team UUID)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  inserted INT := 0;
  rec RECORD;
BEGIN
  -- Clear existing
  DELETE FROM depth_chart WHERE team_id = p_team;

  -- Rank by position using rating (available first), tie-break awareness if attrs exist
  FOR rec IN
    WITH roster AS (
      SELECT
        p.id AS player_id,
        p.pos_code,
        p.rating,
        COALESCE(pa.awareness, 50) AS awareness,
        CASE WHEN dc_is_available(p.id) THEN 0 ELSE 1 END AS unavailable
      FROM players p
      LEFT JOIN player_attributes pa ON pa.player_id = p.id
      WHERE p.team_id = p_team
    ),
    ranked AS (
      SELECT
        pos_code,
        player_id,
        ROW_NUMBER() OVER (
          PARTITION BY pos_code
          ORDER BY unavailable ASC, rating DESC, awareness DESC, player_id
        ) AS rnk
      FROM roster
    )
    SELECT * FROM ranked
  LOOP
    INSERT INTO depth_chart (team_id, pos_code, player_id, depth_rank)
    VALUES (p_team, rec.pos_code, rec.player_id, rec.rnk);
    inserted := inserted + 1;
  END LOOP;

  RETURN inserted;
END;
$$;

-- Rebuild a single position lane for a team
CREATE OR REPLACE FUNCTION dc_reseed_position(p_team UUID, p_pos TEXT)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  inserted INT := 0;
  rec RECORD;
BEGIN
  DELETE FROM depth_chart WHERE team_id = p_team AND pos_code = UPPER(p_pos);

  FOR rec IN
    WITH roster AS (
      SELECT
        p.id AS player_id, p.pos_code, p.rating,
        COALESCE(pa.awareness, 50) AS awareness,
        CASE WHEN dc_is_available(p.id) THEN 0 ELSE 1 END AS unavailable
      FROM players p
      LEFT JOIN player_attributes pa ON pa.player_id = p.id
      WHERE p.team_id = p_team AND p.pos_code = UPPER(p_pos)
    ),
    ranked AS (
      SELECT pos_code, player_id,
             ROW_NUMBER() OVER (PARTITION BY pos_code
                                ORDER BY unavailable ASC, rating DESC, awareness DESC, player_id) AS rnk
      FROM roster
    )
    SELECT * FROM ranked
  LOOP
    INSERT INTO depth_chart (team_id, pos_code, player_id, depth_rank)
    VALUES (p_team, rec.pos_code, rec.player_id, rec.rnk);
    inserted := inserted + 1;
  END LOOP;

  RETURN inserted;
END;
$$;

-- =========================================
-- OPERATIONS: swap/set rank
-- =========================================
CREATE OR REPLACE FUNCTION dc_swap(p_team UUID, p_pos TEXT, p_player_a UUID, p_player_b UUID)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE ra INT; rb INT;
BEGIN
  SELECT depth_rank INTO ra FROM depth_chart
  WHERE team_id = p_team AND pos_code = UPPER(p_pos) AND player_id = p_player_a;

  SELECT depth_rank INTO rb FROM depth_chart
  WHERE team_id = p_team AND pos_code = UPPER(p_pos) AND player_id = p_player_b;

  IF ra IS NULL OR rb IS NULL THEN
    RAISE EXCEPTION 'Players not found in depth chart lane % for team %', p_pos, p_team;
  END IF;

  UPDATE depth_chart
  SET depth_rank = CASE WHEN player_id = p_player_a THEN rb ELSE ra END
  WHERE team_id = p_team AND pos_code = UPPER(p_pos) AND player_id IN (p_player_a, p_player_b);
END;
$$;

-- Set a player's rank and push others accordingly (stable insert)
CREATE OR REPLACE FUNCTION dc_set_rank(p_team UUID, p_pos TEXT, p_player UUID, p_new_rank INT)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE max_rank INT; cur_rank INT;
BEGIN
  SELECT MAX(depth_rank) INTO max_rank
  FROM depth_chart WHERE team_id = p_team AND pos_code = UPPER(p_pos);

  SELECT depth_rank INTO cur_rank
  FROM depth_chart WHERE team_id = p_team AND pos_code = UPPER(p_pos) AND player_id = p_player;

  IF cur_rank IS NULL THEN
    -- ensure he is in the lane
    INSERT INTO depth_chart (team_id, pos_code, player_id, depth_rank)
    VALUES (p_team, UPPER(p_pos), p_player, COALESCE(max_rank,0) + 1);
    cur_rank := max_rank + 1;
  END IF;

  p_new_rank := dc_clampi(p_new_rank, 1, GREATEST(1, max_rank));

  IF p_new_rank = cur_rank THEN RETURN; END IF;

  IF p_new_rank < cur_rank THEN
    -- promote: shift ranks up
    UPDATE depth_chart
    SET depth_rank = depth_rank + 1
    WHERE team_id = p_team AND pos_code = UPPER(p_pos)
      AND depth_rank >= p_new_rank AND depth_rank < cur_rank;

  ELSE
    -- demote: shift ranks down
    UPDATE depth_chart
    SET depth_rank = depth_rank - 1
    WHERE team_id = p_team AND pos_code = UPPER(p_pos)
      AND depth_rank <= p_new_rank AND depth_rank > cur_rank;
  END IF;

  -- apply new rank
  UPDATE depth_chart
  SET depth_rank = p_new_rank
  WHERE team_id = p_team AND pos_code = UPPER(p_pos) AND player_id = p_player;
END;
$$;

-- Convenience: set starter (rank=1)
CREATE OR REPLACE FUNCTION dc_set_starter(p_team UUID, p_pos TEXT, p_player UUID)
RETURNS VOID
LANGUAGE sql AS $$
  SELECT dc_set_rank($1, $2, $3, 1);
$$;

-- =========================================
-- PRACTICE-BASED PROMOTIONS
-- Uses practice_session (per save/team/season) to compute rolling grades
-- and auto-promotes over immediate player above if margin * meritocracy* passes.
-- =========================================
CREATE OR REPLACE FUNCTION dc_apply_practice_promotions(
  p_team UUID,
  p_window_sessions INT DEFAULT 4,          -- recent sessions window
  p_min_margin NUMERIC DEFAULT 3.0          -- min avg grade diff to promote
) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  v_merit NUMERIC := COALESCE(dc_coach_meritocracy(p_team), 0.7);
  moved INT := 0;
  lane RECORD;
  above UUID; above_rank INT;
  cand UUID;  cand_rank INT;
  g_above NUMERIC; g_cand NUMERIC;
BEGIN
  -- For each position lane, from rank 2 downward, consider swapping with immediate above
  FOR lane IN
    SELECT d.pos_code, d.player_id, d.depth_rank
    FROM depth_chart d
    WHERE d.team_id = p_team
    ORDER BY d.pos_code, d.depth_rank
  LOOP
    IF lane.depth_rank <= 1 THEN CONTINUE; END IF;

    cand := lane.player_id; cand_rank := lane.depth_rank;

    -- find immediate above
    SELECT player_id INTO above
    FROM depth_chart
    WHERE team_id = p_team AND pos_code = lane.pos_code AND depth_rank = (cand_rank - 1);

    IF above IS NULL THEN CONTINUE; END IF;

    above_rank := cand_rank - 1;

    -- compute rolling practice average per player
    WITH recent AS (
      SELECT player_id, AVG(grade)::numeric AS g
      FROM (
        -- join player's team/sessions via save/team/season; fall back to team mean if no direct link
        SELECT ps.grade, cp.player_id
        FROM practice_session ps
        JOIN career_save cs     ON cs.id = ps.save_id
        JOIN career_player cp   ON cp.save_id = ps.save_id
        WHERE ps.team_id = p_team
        ORDER BY ps.created_at DESC
        LIMIT p_window_sessions
      ) s
      GROUP BY player_id
    )
    SELECT COALESCE((SELECT g FROM recent WHERE player_id = above), 0.0),
           COALESCE((SELECT g FROM recent WHERE player_id = cand),  0.0)
    INTO g_above, g_cand;

    -- if candidate outperforms above by margin scaled by (1 - meritocracy dampening),
    -- promote candidate by 1.
    IF (g_cand - g_above) >= (p_min_margin * v_merit) THEN
      PERFORM dc_swap(p_team, lane.pos_code, cand, above);
      moved := moved + 1;
    END IF;
  END LOOP;

  RETURN moved;
END;
$$;

-- =========================================
-- AVAILABILITY ENFORCER
-- Pushes unavailable players down to bottom; pulls next available up.
-- =========================================
CREATE OR REPLACE FUNCTION dc_enforce_availability(p_team UUID, p_pos TEXT)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  changed INT := 0;
  rec RECORD;
  avail_first UUID[];
  unavail UUID[];
BEGIN
  -- Partition lane by availability
  SELECT array_agg(player_id ORDER BY depth_rank)
  INTO avail_first
  FROM depth_chart
  WHERE team_id = p_team AND pos_code = UPPER(p_pos) AND dc_is_available(player_id) = TRUE;

  SELECT array_agg(player_id ORDER BY depth_rank)
  INTO unavail
  FROM depth_chart
  WHERE team_id = p_team AND pos_code = UPPER(p_pos) AND dc_is_available(player_id) = FALSE;

  -- Rebuild lane if any unavailable present
  IF unavail IS NOT NULL AND array_length(unavail,1) > 0 THEN
    DELETE FROM depth_chart WHERE team_id = p_team AND pos_code = UPPER(p_pos);

    IF avail_first IS NOT NULL THEN
      FOR rec IN SELECT generate_subscripts(avail_first,1) AS idx LOOP
        INSERT INTO depth_chart (team_id, pos_code, player_id, depth_rank)
        VALUES (p_team, UPPER(p_pos), avail_first[rec.idx], rec.idx);
      END LOOP;
      changed := changed + COALESCE(array_length(avail_first,1),0);
    END IF;

    IF unavail IS NOT NULL THEN
      FOR rec IN SELECT generate_subscripts(unavail,1) AS idx LOOP
        INSERT INTO depth_chart (team_id, pos_code, player_id, depth_rank)
        VALUES (p_team, UPPER(p_pos), unavail[rec.idx],
                COALESCE(array_length(avail_first,1),0) + rec.idx);
      END LOOP;
      changed := changed + COALESCE(array_length(unavail,1),0);
    END IF;
  END IF;

  RETURN changed;
END;
$$;

-- Enforce availability across the whole team
CREATE OR REPLACE FUNCTION dc_enforce_team_availability(p_team UUID)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE pos TEXT; total INT := 0;
BEGIN
  FOR pos IN
    SELECT DISTINCT pos_code FROM depth_chart WHERE team_id = p_team
  LOOP
    total := total + dc_enforce_availability(p_team, pos);
  END LOOP;
  RETURN total;
END;
$$;

-- =========================================
-- SYNC: keep depth_chart consistent after roster changes
-- =========================================

-- Upsert a single player into lane (append at end if new)
CREATE OR REPLACE FUNCTION dc_sync_player(p_player UUID)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE t UUID; pos TEXT; maxr INT;
BEGIN
  SELECT team_id, pos_code INTO t, pos FROM players WHERE id = p_player;
  IF t IS NULL OR pos IS NULL THEN
    -- player detached; remove from any charts
    DELETE FROM depth_chart WHERE player_id = p_player;
    RETURN;
  END IF;

  -- If player exists in another lane/team, correct it
  DELETE FROM depth_chart WHERE player_id = p_player AND (team_id <> t OR pos_code <> pos);

  -- Ensure lane exists; if not, create with this player as last
  SELECT MAX(depth_rank) INTO maxr FROM depth_chart WHERE team_id = t AND pos_code = pos;
  IF NOT EXISTS (
    SELECT 1 FROM depth_chart WHERE team_id = t AND pos_code = pos AND player_id = p_player
  ) THEN
    INSERT INTO depth_chart (team_id, pos_code, player_id, depth_rank)
    VALUES (t, pos, p_player, COALESCE(maxr,0) + 1);
  END IF;
END;
$$;

-- Full team sync: everyone present exactly once and ranks compacted
CREATE OR REPLACE FUNCTION dc_sync_team(p_team UUID)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  pos TEXT;
  rec RECORD;
  rnk INT;
  fixed INT := 0;
BEGIN
  -- Remove chart entries for players no longer on this team
  DELETE FROM depth_chart d
  USING players p
  WHERE d.team_id = p_team AND d.player_id = p.id AND p.team_id <> p_team;

  -- Ensure every rostered player appears in exactly one lane for their position
  FOR rec IN
    SELECT p.id AS player_id, p.pos_code
    FROM players p
    WHERE p.team_id = p_team
  LOOP
    PERFORM dc_sync_player(rec.player_id);
  END LOOP;

  -- Compact ranks (1..N) per lane in rating order (availability first)
  FOR pos IN
    SELECT DISTINCT pos_code FROM players WHERE team_id = p_team
  LOOP
    rnk := 0;

    FOR rec IN
      SELECT d.player_id
      FROM depth_chart d
      JOIN players p ON p.id = d.player_id
      LEFT JOIN player_attributes pa ON pa.player_id = p.id
      WHERE d.team_id = p_team AND d.pos_code = pos
      ORDER BY CASE WHEN dc_is_available(p.id) THEN 0 ELSE 1 END,
               p.rating DESC, COALESCE(pa.awareness,50) DESC, p.id
    LOOP
      rnk := rnk + 1;
      UPDATE depth_chart SET depth_rank = rnk
      WHERE team_id = p_team AND pos_code = pos AND player_id = rec.player_id;
      fixed := fixed + 1;
    END LOOP;
  END LOOP;

  RETURN fixed;
END;
$$;

-- =========================================
-- TRIGGERS: react to roster changes
-- =========================================

-- When a player's team or position changes, sync the depth chart
CREATE OR REPLACE FUNCTION trg_players_dc_sync()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM dc_sync_player(NEW.id);
  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'players_dc_sync'
  ) THEN
    CREATE TRIGGER players_dc_sync
    AFTER INSERT OR UPDATE OF team_id, pos_code ON players
    FOR EACH ROW EXECUTE FUNCTION trg_players_dc_sync();
  END IF;
END$$;

-- Clean up depth_chart entries when a player is deleted
CREATE OR REPLACE FUNCTION trg_players_dc_cleanup()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM depth_chart WHERE player_id = OLD.id;
  RETURN OLD;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'players_dc_cleanup'
  ) THEN
    CREATE TRIGGER players_dc_cleanup
    AFTER DELETE ON players
    FOR EACH ROW EXECUTE FUNCTION trg_players_dc_cleanup();
  END IF;
END$$;

-- =========================================
-- BATCH ORCHESTRATION
-- =========================================

-- Rebuild every team in a league (useful after HS/College generation)
CREATE OR REPLACE FUNCTION dc_rebuild_league(p_league UUID)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE t RECORD; total INT := 0;
BEGIN
  FOR t IN SELECT id FROM teams WHERE league_id = p_league LOOP
    total := total + dc_rebuild_team(t.id);
  END LOOP;
  RETURN total;
END;
$$;

-- Run all maintenance for a team: sync → availability → practice promotions
CREATE OR REPLACE FUNCTION dc_maintain_team(p_team UUID)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE synced INT; avail INT; promos INT;
BEGIN
  synced := dc_sync_team(p_team);
  avail  := dc_enforce_team_availability(p_team);
  promos := dc_apply_practice_promotions(p_team);
  RETURN jsonb_build_object('synced_rows', synced, 'availability_adjustments', avail, 'promotions', promos);
END;
$$;

-- =========================================
-- VIEWS FOR UI
-- =========================================

CREATE OR REPLACE VIEW v_depth_chart_ordered AS
SELECT
  d.team_id,
  t.name AS team_name,
  d.pos_code,
  d.depth_rank,
  d.player_id,
  p.first_name, p.last_name,
  p.rating,
  COALESCE(pa.awareness,50) AS awareness,
  CASE WHEN dc_is_available(p.id) THEN TRUE ELSE FALSE END AS available
FROM depth_chart d
JOIN teams t ON t.id = d.team_id
JOIN players p ON p.id = d.player_id
LEFT JOIN player_attributes pa ON pa.player_id = p.id
ORDER BY t.name, d.pos_code, d.depth_rank;

-- =========================================
-- OPTIONAL QUICK CHECKS (commented)
-- =========================================
-- -- Rebuild an entire team:
-- -- SELECT dc_rebuild_team('<team_uuid>');
-- -- Promote via practice:
-- -- SELECT dc_apply_practice_promotions('<team_uuid>');
-- -- Maintain team (sync+availability+promotions):
-- -- SELECT dc_maintain_team('<team_uuid>');
-- -- See chart:
-- -- SELECT * FROM v_depth_chart_ordered WHERE team_id = '<team_uuid>';
