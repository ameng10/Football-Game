-- =====================
-- SEED DATA
-- =====================

-- Leagues
INSERT INTO leagues (id, name, level)
VALUES
    (gen_random_uuid(), 'High School National', 'HS'),
    (gen_random_uuid(), 'NCAA College Football', 'NCAA'),
    (gen_random_uuid(), 'National Football League', 'NFL');

-- Positions
INSERT INTO positions (pos_code, description) VALUES
    ('QB', 'Quarterback'),
    ('RB', 'Running Back'),
    ('WR', 'Wide Receiver'),
    ('TE', 'Tight End'),
    ('OL', 'Offensive Lineman'),
    ('DL', 'Defensive Lineman'),
    ('LB', 'Linebacker'),
    ('CB', 'Cornerback'),
    ('S', 'Safety'),
    ('K', 'Kicker'),
    ('P', 'Punter');

-- High School Teams
WITH hs_league AS (
    SELECT id AS league_id FROM leagues WHERE level = 'HS' LIMIT 1
)
INSERT INTO teams (id, league_id, name, city, mascot, prestige)
VALUES
    (gen_random_uuid(), (SELECT league_id FROM hs_league), 'Lincoln High', 'Springfield', 'Tigers', 40),
    (gen_random_uuid(), (SELECT league_id FROM hs_league), 'Roosevelt High', 'Fairview', 'Eagles', 38),
    (gen_random_uuid(), (SELECT league_id FROM hs_league), 'Kennedy High', 'Oakwood', 'Knights', 35),
    (gen_random_uuid(), (SELECT league_id FROM hs_league), 'Jefferson High', 'Riverton', 'Bulldogs', 32);

-- Sample Players (Mix of classes for realism)
WITH lincoln AS (SELECT id AS team_id FROM teams WHERE name = 'Lincoln High'),
     roosevelt AS (SELECT id AS team_id FROM teams WHERE name = 'Roosevelt High')
INSERT INTO players (id, team_id, first_name, last_name, pos_code, rating, potential, stars, class_year, birth_date, followers)
VALUES
    -- Lincoln High
    (gen_random_uuid(), (SELECT team_id FROM lincoln), 'Jake', 'Anderson', 'QB', 72, 88, 3, 'Senior', '2007-05-14', 500),
    (gen_random_uuid(), (SELECT team_id FROM lincoln), 'Marcus', 'Lee', 'RB', 69, 85, 3, 'Junior', '2008-04-21', 320),
    (gen_random_uuid(), (SELECT team_id FROM lincoln), 'Chris', 'Walker', 'WR', 67, 82, 2, 'Sophomore', '2009-02-11', 150),
    (gen_random_uuid(), (SELECT team_id FROM lincoln), 'Tony', 'Jackson', 'LB', 65, 80, 2, 'Freshman', '2010-09-30', 75),

    -- Roosevelt High
    (gen_random_uuid(), (SELECT team_id FROM roosevelt), 'Ethan', 'Barnes', 'QB', 74, 90, 4, 'Senior', '2007-06-05', 620),
    (gen_random_uuid(), (SELECT team_id FROM roosevelt), 'Derrick', 'Hughes', 'RB', 70, 86, 3, 'Junior', '2008-07-19', 340),
    (gen_random_uuid(), (SELECT team_id FROM roosevelt), 'Adam', 'Coleman', 'WR', 66, 81, 2, 'Sophomore', '2009-12-08', 160),
    (gen_random_uuid(), (SELECT team_id FROM roosevelt), 'Brian', 'Stevens', 'S', 64, 79, 2, 'Freshman', '2010-03-18', 90);

-- Attributes for players (simplified numbers)
INSERT INTO player_attributes (player_id, speed, strength, agility, throw_power, throw_accuracy, catching, tackling, awareness, stamina)
SELECT id,
       FLOOR(random() * 30 + 60),
       FLOOR(random() * 30 + 60),
       FLOOR(random() * 30 + 60),
       FLOOR(random() * 20 + 50),
       FLOOR(random() * 20 + 50),
       FLOOR(random() * 20 + 50),
       FLOOR(random() * 20 + 50),
       FLOOR(random() * 30 + 50),
       FLOOR(random() * 30 + 60)
FROM players;

-- Awards
INSERT INTO awards (id, name, description, level) VALUES
    (gen_random_uuid(), 'League MVP', 'Most valuable player in the league', 'HS'),
    (gen_random_uuid(), 'Best QB', 'Top quarterback in the league', 'HS'),
    (gen_random_uuid(), 'Best RB', 'Top running back in the league', 'HS'),
    (gen_random_uuid(), 'Best WR', 'Top wide receiver in the league', 'HS');

-- Standings for start of season
WITH season AS (
    INSERT INTO seasons (id, league_id, year)
    VALUES (gen_random_uuid(), (SELECT id FROM leagues WHERE level = 'HS' LIMIT 1), EXTRACT(YEAR FROM CURRENT_DATE))
    RETURNING id
)
INSERT INTO standings (season_id, team_id, wins, losses, ties, points_for, points_against)
SELECT season.id, t.id, 0, 0, 0, 0, 0
FROM season, teams t
WHERE t.league_id = (SELECT id FROM leagues WHERE level = 'HS');
