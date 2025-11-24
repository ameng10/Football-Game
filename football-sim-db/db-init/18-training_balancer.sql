-- 18-training_balancer.sql
-- This script creates a function and a trigger to balance player training sessions

-- Table: training_sessions
-- Columns: id, player_id, session_date, intensity

-- Table: players
-- Columns: id, name, stamina, skill

-- Function to balance training: adjust stamina and skill based on session intensity
CREATE OR REPLACE FUNCTION balance_training()
RETURNS TRIGGER AS $$
BEGIN
    -- Increase skill, decrease stamina based on intensity
    UPDATE players
    SET
        skill = skill + (NEW.intensity * 0.5),
        stamina = GREATEST(stamina - (NEW.intensity * 0.3), 0)
    WHERE id = NEW.player_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger: after insert on training_sessions
CREATE TRIGGER trg_balance_training
AFTER INSERT ON training_sessions
FOR EACH ROW
EXECUTE FUNCTION balance_training();
