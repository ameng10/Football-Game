-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =====================
-- LEAGUES
-- =====================
CREATE TABLE leagues (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    level TEXT NOT NULL CHECK (level IN ('HighSchool', 'College', 'Pro')),
    created_at TIMESTAMP DEFAULT NOW()
);

-- =====================
-- SEASONS
-- =====================
CREATE TABLE seasons (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    league_id UUID NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
    year INT NOT NULL,
    current BOOLEAN DEFAULT FALSE,
    UNIQUE (league_id, year)
);

-- =====================
-- TEAMS
-- =====================
CREATE TABLE teams (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    league_id UUID NOT NULL REFERENCES leagues(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    city TEXT NOT NULL,
    mascot TEXT,
    prestige INT DEFAULT 50 CHECK (prestige BETWEEN 0 AND 100),
    created_at TIMESTAMP DEFAULT NOW()
);

-- =====================
-- POSITIONS
-- =====================
CREATE TABLE positions (
    code TEXT PRIMARY KEY,
    description TEXT NOT NULL
);

INSERT INTO positions (code, description) VALUES
('QB', 'Quarterback'),
('RB', 'Running Back'),
('WR', 'Wide Receiver'),
('TE', 'Tight End'),
('OL', 'Offensive Line'),
('DL', 'Defensive Line'),
('LB', 'Linebacker'),
('CB', 'Cornerback'),
('S', 'Safety'),
('K', 'Kicker'),
('P', 'Punter');

-- =====================
-- PLAYERS
-- =====================
CREATE TABLE players (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    team_id UUID REFERENCES teams(id) ON DELETE SET NULL,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    pos_code TEXT REFERENCES positions(code),
    birth_date DATE NOT NULL,
    stars INT DEFAULT 3 CHECK (stars BETWEEN 1 AND 5),
    rating INT DEFAULT 60 CHECK (rating BETWEEN 40 AND 99),
    potential INT DEFAULT 75 CHECK (potential BETWEEN 40 AND 99),
    height_inches INT,
    weight_lbs INT,
    class_year TEXT CHECK (class_year IN ('Freshman', 'Sophomore', 'Junior', 'Senior')),
    followers INT DEFAULT 0,
    created_at TIMESTAMP DEFAULT NOW()
);

-- =====================
-- PLAYER ATTRIBUTES (Career Mode)
-- =====================
CREATE TABLE player_attributes (
    player_id UUID PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
    speed INT DEFAULT 50 CHECK (speed BETWEEN 0 AND 100),
    strength INT DEFAULT 50 CHECK (strength BETWEEN 0 AND 100),
    agility INT DEFAULT 50 CHECK (agility BETWEEN 0 AND 100),
    throw_power INT DEFAULT 50 CHECK (throw_power BETWEEN 0 AND 100),
    throw_accuracy INT DEFAULT 50 CHECK (throw_accuracy BETWEEN 0 AND 100),
    catching INT DEFAULT 50 CHECK (catching BETWEEN 0 AND 100),
    tackling INT DEFAULT 50 CHECK (tackling BETWEEN 0 AND 100),
    awareness INT DEFAULT 50 CHECK (awareness BETWEEN 0 AND 100),
    stamina INT DEFAULT 50 CHECK (stamina BETWEEN 0 AND 100),
    training_points INT DEFAULT 0
);

-- =====================
-- GAMES
-- =====================
CREATE TABLE games (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    season_id UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
    week INT NOT NULL,
    home_team_id UUID NOT NULL REFERENCES teams(id),
    away_team_id UUID NOT NULL REFERENCES teams(id),
    home_score INT DEFAULT 0,
    away_score INT DEFAULT 0,
    status TEXT DEFAULT 'Scheduled' CHECK (status IN ('Scheduled','InProgress','Final')),
    played BOOLEAN DEFAULT FALSE,
    date DATE
);

-- =====================
-- STATS (Generic per-game stats)
-- =====================
CREATE TABLE game_stats (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    game_id UUID NOT NULL REFERENCES games(id) ON DELETE CASCADE,
    player_id UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    pass_attempts INT DEFAULT 0,
    pass_completions INT DEFAULT 0,
    pass_yards INT DEFAULT 0,
    pass_tds INT DEFAULT 0,
    interceptions INT DEFAULT 0,
    rush_attempts INT DEFAULT 0,
    rush_yards INT DEFAULT 0,
    rush_tds INT DEFAULT 0,
    receptions INT DEFAULT 0,
    rec_yards INT DEFAULT 0,
    rec_tds INT DEFAULT 0,
    tackles INT DEFAULT 0,
    sacks INT DEFAULT 0,
    forced_fumbles INT DEFAULT 0,
    fumbles_recovered INT DEFAULT 0,
    field_goals_made INT DEFAULT 0,
    field_goals_attempted INT DEFAULT 0,
    punts INT DEFAULT 0,
    punt_yards INT DEFAULT 0
);

-- =====================
-- SEASON AGGREGATE STATS
-- =====================
CREATE TABLE season_stats (
    player_id UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    season_id UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
    games_played INT DEFAULT 0,
    pass_attempts INT DEFAULT 0,
    pass_completions INT DEFAULT 0,
    pass_yards INT DEFAULT 0,
    pass_tds INT DEFAULT 0,
    interceptions INT DEFAULT 0,
    rush_attempts INT DEFAULT 0,
    rush_yards INT DEFAULT 0,
    rush_tds INT DEFAULT 0,
    receptions INT DEFAULT 0,
    rec_yards INT DEFAULT 0,
    rec_tds INT DEFAULT 0,
    tackles INT DEFAULT 0,
    sacks INT DEFAULT 0,
    forced_fumbles INT DEFAULT 0,
    fumbles_recovered INT DEFAULT 0,
    field_goals_made INT DEFAULT 0,
    field_goals_attempted INT DEFAULT 0,
    punts INT DEFAULT 0,
    punt_yards INT DEFAULT 0,
    PRIMARY KEY (player_id, season_id)
);

-- =====================
-- STANDINGS
-- =====================
CREATE TABLE standings (
    season_id UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
    team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    wins INT DEFAULT 0,
    losses INT DEFAULT 0,
    ties INT DEFAULT 0,
    points_for INT DEFAULT 0,
    points_against INT DEFAULT 0,
    PRIMARY KEY (season_id, team_id)
);

-- =====================
-- PLAYOFF BRACKETS
-- =====================
CREATE TABLE playoffs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    season_id UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
    round INT NOT NULL,
    game_order INT NOT NULL,
    home_team_id UUID NOT NULL REFERENCES teams(id),
    away_team_id UUID NOT NULL REFERENCES teams(id),
    winner_team_id UUID REFERENCES teams(id),
    played BOOLEAN DEFAULT FALSE,
    UNIQUE (season_id, round, game_order)
);

-- =====================
-- RECRUITING (Career Mode)
-- =====================
CREATE TABLE recruiting_offers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    player_id UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    college_team_id UUID NOT NULL REFERENCES teams(id),
    offer_date DATE DEFAULT CURRENT_DATE,
    committed BOOLEAN DEFAULT FALSE
);

-- =====================
-- DEPTH CHART
-- =====================
CREATE TABLE depth_chart (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    pos_code TEXT NOT NULL REFERENCES positions(code),
    player_id UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    depth_rank INT NOT NULL
);

-- =====================
-- AWARDS
-- =====================
CREATE TABLE awards (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    description TEXT,
    level TEXT CHECK (level IN ('HighSchool', 'College', 'Pro'))
);

CREATE TABLE awards_assigned (
    award_id UUID REFERENCES awards(id),
    season_id UUID NOT NULL REFERENCES seasons(id) ON DELETE CASCADE,
    player_id UUID REFERENCES players(id),
    PRIMARY KEY (award_id, season_id)
);

-- =====================
-- TRAINING LOG (Career Mode)
-- =====================
CREATE TABLE training_log (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    player_id UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    date DATE DEFAULT CURRENT_DATE,
    points_earned INT DEFAULT 0,
    method TEXT CHECK (method IN ('Practice', 'MiniGame', 'Simulated'))
);

-- =====================
-- INDEXES
-- =====================
CREATE INDEX idx_players_team ON players(team_id);
CREATE INDEX idx_games_season ON games(season_id);
CREATE INDEX idx_game_stats_player ON game_stats(player_id);
CREATE INDEX idx_season_stats_player ON season_stats(player_id);
