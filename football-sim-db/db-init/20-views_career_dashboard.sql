-- View: career_dashboard
-- This view summarizes player career statistics for dashboard display

CREATE OR REPLACE VIEW career_dashboard AS
SELECT
    p.player_id,
    p.first_name,
    p.last_name,
    p.position,
    p.team_id,
    t.team_name,
    COUNT(g.game_id) AS games_played,
    SUM(ps.goals) AS total_goals,
    SUM(ps.assists) AS total_assists,
    SUM(ps.minutes_played) AS total_minutes,
    MAX(g.game_date) AS last_game_date
FROM
    players p
JOIN
    player_stats ps ON p.player_id = ps.player_id
JOIN
    games g ON ps.game_id = g.game_id
JOIN
    teams t ON p.team_id = t.team_id
GROUP BY
    p.player_id, p.first_name, p.last_name, p.position, p.team_id, t.team_name;
