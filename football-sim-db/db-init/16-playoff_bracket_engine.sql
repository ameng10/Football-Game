-- ===================================================================
-- File: 16-playoff_bracket_engine.sql
-- Purpose: Playoff bracket schema and logic for football simulation DB
-- ===================================================================

-- =========================
-- Table: playoff_rounds
-- =========================
CREATE TABLE IF NOT EXISTS playoff_rounds (
    id SERIAL PRIMARY KEY,
    round_number INT NOT NULL UNIQUE,
    round_name VARCHAR(50) NOT NULL
);

-- =========================
-- Table: playoff_matchups
-- =========================
CREATE TABLE IF NOT EXISTS playoff_matchups (
    id SERIAL PRIMARY KEY,
    round_id INT NOT NULL REFERENCES playoff_rounds(id) ON DELETE CASCADE,
    matchup_number INT NOT NULL,
    team1_id INT NOT NULL REFERENCES teams(id),
    team2_id INT NOT NULL REFERENCES teams(id),
    winner_id INT REFERENCES teams(id),
    game_id INT REFERENCES games(id),
    UNIQUE (round_id, matchup_number)
);

-- =========================
-- Seed playoff_rounds
-- =========================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM playoff_rounds) THEN
        INSERT INTO playoff_rounds (round_number, round_name) VALUES
            (1, 'Quarterfinals'),
            (2, 'Semifinals'),
            (3, 'Finals'),
            (4, 'Champion');
    END IF;
END
$$;

-- =========================
-- Function: create_playoff_matchups
-- =========================
CREATE OR REPLACE FUNCTION create_playoff_matchups(team_ids INT[])
RETURNS VOID AS $$
DECLARE
    round_id INT;
    i INT := 1;
    matchup_num INT := 1;
BEGIN
    SELECT id INTO round_id FROM playoff_rounds WHERE round_number = 1;
    WHILE i < array_length(team_ids, 1) LOOP
        INSERT INTO playoff_matchups (round_id, matchup_number, team1_id, team2_id)
        VALUES (round_id, matchup_num, team_ids[i], team_ids[i+1]);
        i := i + 2;
        matchup_num := matchup_num + 1;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =========================
-- Function: advance_playoff_round
-- =========================
CREATE OR REPLACE FUNCTION advance_playoff_round(current_round INT)
RETURNS VOID AS $$
DECLARE
    next_round INT := current_round + 1;
    matchup_num INT := 1;
    winner_ids INT[];
    i INT := 1;
    next_round_id INT;
BEGIN
    -- Collect winners from current round
    SELECT ARRAY_AGG(winner_id ORDER BY matchup_number)
    INTO winner_ids
    FROM playoff_matchups pm
    JOIN playoff_rounds pr ON pm.round_id = pr.id
    WHERE pr.round_number = current_round AND winner_id IS NOT NULL;

    -- Get next round id
    SELECT id INTO next_round_id FROM playoff_rounds WHERE round_number = next_round;

    -- Insert next round matchups
    WHILE i < array_length(winner_ids, 1) LOOP
        INSERT INTO playoff_matchups (round_id, matchup_number, team1_id, team2_id)
        VALUES (next_round_id, matchup_num, winner_ids[i], winner_ids[i+1]);
        i := i + 2;
        matchup_num := matchup_num + 1;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
