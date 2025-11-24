-- Injury and Fatigue Model

-- Table to track player injuries
CREATE TABLE player_injuries (
    injury_id SERIAL PRIMARY KEY,
    player_id INTEGER NOT NULL REFERENCES players(player_id),
    injury_type VARCHAR(100) NOT NULL,
    injury_start_date DATE NOT NULL,
    expected_recovery_date DATE,
    severity VARCHAR(50),
    notes TEXT
);

-- Table to track player fatigue
CREATE TABLE player_fatigue (
    fatigue_id SERIAL PRIMARY KEY,
    player_id INTEGER NOT NULL REFERENCES players(player_id),
    fatigue_level INTEGER NOT NULL CHECK (fatigue_level BETWEEN 0 AND 100),
    last_updated TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Function to update fatigue after a match
CREATE OR REPLACE FUNCTION update_player_fatigue(p_player_id INTEGER, p_fatigue_increase INTEGER)
RETURNS VOID AS $$
BEGIN
    UPDATE player_fatigue
    SET fatigue_level = LEAST(fatigue_level + p_fatigue_increase, 100),
        last_updated = CURRENT_TIMESTAMP
    WHERE player_id = p_player_id;
END;
$$ LANGUAGE plpgsql;

-- Function to recover fatigue (e.g., after rest)
CREATE OR REPLACE FUNCTION recover_player_fatigue(p_player_id INTEGER, p_fatigue_recovery INTEGER)
RETURNS VOID AS $$
BEGIN
    UPDATE player_fatigue
    SET fatigue_level = GREATEST(fatigue_level - p_fatigue_recovery, 0),
        last_updated = CURRENT_TIMESTAMP
    WHERE player_id = p_player_id;
END;
$$ LANGUAGE plpgsql;

-- Sample trigger to automatically add a fatigue record when a new player is added
CREATE OR REPLACE FUNCTION add_fatigue_record()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO player_fatigue (player_id, fatigue_level)
    VALUES (NEW.player_id, 0);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_add_fatigue_record
AFTER INSERT ON players
FOR EACH ROW
EXECUTE FUNCTION add_fatigue_record();
