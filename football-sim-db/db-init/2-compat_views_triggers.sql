-- =====================
-- VIEWS
-- =====================

-- 1. View: full roster for a team
CREATE OR REPLACE VIEW v_team_roster AS
SELECT
    t.id AS team_id,
    t.name AS team_name,
    t.city,
    t.mascot,
    p.id AS player_id,
    p.first_name,
    p.last_name,
    p.pos_code,
    p.rating,
    p.potential,
    p.stars,
    p.class_year,
    p.followers,
    pa.speed,
    pa.strength,
    pa.agility,
    pa.throw_power,
    pa.throw_accuracy,
    pa.catching,
    pa.tackling,
    pa.awareness,
    pa.stamina
FROM teams t
LEFT JOIN players p ON p.team_id = t.id
LEFT JOIN player_attributes pa ON pa.player_id = p.id
ORDER BY t.name, p.pos_code, p.rating DESC;

-- 2. View: season schedule with scores
CREATE OR REPLACE VIEW v_season_schedule AS
SELECT
    g.id AS game_id,
    g.season_id,
    g.week,
    ht.name AS home_team,
    at.name AS away_team,
    g.home_score,
    g.away_score,
    g.status,
    g.played,
    g.date
FROM games g
JOIN teams ht ON g.home_team_id = ht.id
JOIN teams at ON g.away_team_id = at.id
ORDER BY g.week, g.date;

-- 3. View: current standings
CREATE OR REPLACE VIEW v_standings AS
SELECT
    s.season_id,
    t.id AS team_id,
    t.name AS team_name,
    s.wins,
    s.losses,
    s.ties,
    s.points_for,
    s.points_against
FROM standings s
JOIN teams t ON s.team_id = t.id
ORDER BY s.wins DESC, s.losses ASC;

-- 4. View: recruiting board
CREATE OR REPLACE VIEW v_recruiting_board AS
SELECT
    r.id AS offer_id,
    r.player_id,
    CONCAT(p.first_name, ' ', p.last_name) AS player_name,
    p.pos_code,
    p.stars,
    p.rating,
    r.college_team_id,
    ct.name AS college_name,
    r.offer_date,
    r.committed
FROM recruiting_offers r
JOIN players p ON p.id = r.player_id
JOIN teams ct ON ct.id = r.college_team_id
ORDER BY p.stars DESC, p.rating DESC;

-- =====================
-- TRIGGERS
-- =====================

-- Trigger function: update standings after a game is marked played
CREATE OR REPLACE FUNCTION trg_update_standings()
RETURNS TRIGGER AS $$
BEGIN
    -- Only run if game was played
    IF NEW.played = TRUE THEN
        -- Home team
        UPDATE standings
        SET
            wins = wins + CASE WHEN NEW.home_score > NEW.away_score THEN 1 ELSE 0 END,
            losses = losses + CASE WHEN NEW.home_score < NEW.away_score THEN 1 ELSE 0 END,
            ties = ties + CASE WHEN NEW.home_score = NEW.away_score THEN 1 ELSE 0 END,
            points_for = points_for + NEW.home_score,
            points_against = points_against + NEW.away_score
        WHERE season_id = NEW.season_id AND team_id = NEW.home_team_id;

        -- Away team
        UPDATE standings
        SET
            wins = wins + CASE WHEN NEW.away_score > NEW.home_score THEN 1 ELSE 0 END,
            losses = losses + CASE WHEN NEW.away_score < NEW.home_score THEN 1 ELSE 0 END,
            ties = ties + CASE WHEN NEW.away_score = NEW.home_score THEN 1 ELSE 0 END,
            points_for = points_for + NEW.away_score,
            points_against = points_against + NEW.home_score
        WHERE season_id = NEW.season_id AND team_id = NEW.away_team_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_game_update
AFTER UPDATE ON games
FOR EACH ROW
EXECUTE FUNCTION trg_update_standings();

-- Trigger function: update season_stats after inserting game_stats
CREATE OR REPLACE FUNCTION trg_update_season_stats()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO season_stats (
        player_id, season_id,
        games_played, pass_attempts, pass_completions, pass_yards, pass_tds, interceptions,
        rush_attempts, rush_yards, rush_tds,
        receptions, rec_yards, rec_tds,
        tackles, sacks, forced_fumbles, fumbles_recovered,
        field_goals_made, field_goals_attempted, punts, punt_yards
    )
    VALUES (
        NEW.player_id, (SELECT season_id FROM games WHERE id = NEW.game_id),
        1, NEW.pass_attempts, NEW.pass_completions, NEW.pass_yards, NEW.pass_tds, NEW.interceptions,
        NEW.rush_attempts, NEW.rush_yards, NEW.rush_tds,
        NEW.receptions, NEW.rec_yards, NEW.rec_tds,
        NEW.tackles, NEW.sacks, NEW.forced_fumbles, NEW.fumbles_recovered,
        NEW.field_goals_made, NEW.field_goals_attempted, NEW.punts, NEW.punt_yards
    )
    ON CONFLICT (player_id, season_id) DO UPDATE
    SET
        games_played = season_stats.games_played + 1,
        pass_attempts = season_stats.pass_attempts + EXCLUDED.pass_attempts,
        pass_completions = season_stats.pass_completions + EXCLUDED.pass_completions,
        pass_yards = season_stats.pass_yards + EXCLUDED.pass_yards,
        pass_tds = season_stats.pass_tds + EXCLUDED.pass_tds,
        interceptions = season_stats.interceptions + EXCLUDED.interceptions,
        rush_attempts = season_stats.rush_attempts + EXCLUDED.rush_attempts,
        rush_yards = season_stats.rush_yards + EXCLUDED.rush_yards,
        rush_tds = season_stats.rush_tds + EXCLUDED.rush_tds,
        receptions = season_stats.receptions + EXCLUDED.receptions,
        rec_yards = season_stats.rec_yards + EXCLUDED.rec_yards,
        rec_tds = season_stats.rec_tds + EXCLUDED.rec_tds,
        tackles = season_stats.tackles + EXCLUDED.tackles,
        sacks = season_stats.sacks + EXCLUDED.sacks,
        forced_fumbles = season_stats.forced_fumbles + EXCLUDED.forced_fumbles,
        fumbles_recovered = season_stats.fumbles_recovered + EXCLUDED.fumbles_recovered,
        field_goals_made = season_stats.field_goals_made + EXCLUDED.field_goals_made,
        field_goals_attempted = season_stats.field_goals_attempted + EXCLUDED.field_goals_attempted,
        punts = season_stats.punts + EXCLUDED.punts,
        punt_yards = season_stats.punt_yards + EXCLUDED.punt_yards;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_game_stats_insert
AFTER INSERT ON game_stats
FOR EACH ROW
EXECUTE FUNCTION trg_update_season_stats();
