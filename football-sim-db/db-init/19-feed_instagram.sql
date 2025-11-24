-- 19-feed_instagram.sql
-- Purpose: Insert sample Instagram feed data for football players and provide helper functions for feed management

-- =========================================================
-- TABLE DEFINITION (if not exists)
-- =========================================================
-- Ensure the instagram_feed table exists before inserting data
CREATE TABLE IF NOT EXISTS instagram_feed (
    id SERIAL PRIMARY KEY,
    player_id INT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    post_url VARCHAR(255) NOT NULL,
    caption TEXT,
    posted_at TIMESTAMPTZ NOT NULL,
    likes INT DEFAULT 0,
    comments INT DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_instagram_feed_player ON instagram_feed(player_id);
CREATE INDEX IF NOT EXISTS idx_instagram_feed_posted_at ON instagram_feed(posted_at);

-- =========================================================
-- SAMPLE DATA INSERTS
-- =========================================================
INSERT INTO instagram_feed (player_id, post_url, caption, posted_at, likes, comments)
VALUES
    (1, 'https://instagram.com/p/abc123', 'Great win today! #football', '2024-06-01 18:30:00', 1200, 150),
    (2, 'https://instagram.com/p/def456', 'Training hard for the next match.', '2024-06-02 09:15:00', 950, 80),
    (3, 'https://instagram.com/p/ghi789', 'Teamwork makes the dream work!', '2024-06-03 20:45:00', 1100, 120),
    (1, 'https://instagram.com/p/jkl012', 'Thank you fans for your support!', '2024-06-04 14:00:00', 1300, 200),
    (4, 'https://instagram.com/p/mno345', 'Ready for the big game tomorrow.', '2024-06-05 17:20:00', 800, 60),
    (2, 'https://instagram.com/p/pqr678', 'Recovery and rest day.', '2024-06-06 10:00:00', 700, 40),
    (3, 'https://instagram.com/p/stu901', 'Proud of my teammates!', '2024-06-07 19:30:00', 1150, 130),
    (4, 'https://instagram.com/p/vwx234', 'Game face on.', '2024-06-08 16:45:00', 900, 75);

-- =========================================================
-- HELPER FUNCTIONS
-- =========================================================

-- Function: Get recent posts for a player
CREATE OR REPLACE FUNCTION get_recent_instagram_posts(p_player_id INT, p_limit INT DEFAULT 5)
RETURNS TABLE (
    post_url VARCHAR,
    caption TEXT,
    posted_at TIMESTAMPTZ,
    likes INT,
    comments INT
) AS $$
    SELECT post_url, caption, posted_at, likes, comments
    FROM instagram_feed
    WHERE player_id = p_player_id
    ORDER BY posted_at DESC
    LIMIT p_limit;
$$ LANGUAGE sql STABLE;

-- Function: Get most liked posts across all players
CREATE OR REPLACE FUNCTION get_top_liked_posts(p_limit INT DEFAULT 5)
RETURNS TABLE (
    player_id INT,
    post_url VARCHAR,
    caption TEXT,
    posted_at TIMESTAMPTZ,
    likes INT,
    comments INT
) AS $$
    SELECT player_id, post_url, caption, posted_at, likes, comments
    FROM instagram_feed
    ORDER BY likes DESC
    LIMIT p_limit;
$$ LANGUAGE sql STABLE;

-- Function: Add a new Instagram post for a player
CREATE OR REPLACE FUNCTION add_instagram_post(
    p_player_id INT,
    p_post_url VARCHAR,
    p_caption TEXT,
    p_posted_at TIMESTAMPTZ,
    p_likes INT DEFAULT 0,
    p_comments INT DEFAULT 0
) RETURNS VOID AS $$
BEGIN
    INSERT INTO instagram_feed (player_id, post_url, caption, posted_at, likes, comments)
    VALUES (p_player_id, p_post_url, p_caption, p_posted_at, p_likes, p_comments);
END;
$$ LANGUAGE plpgsql;

-- =========================================================
-- SAMPLE QUERIES
-- =========================================================

-- Get the 3 most recent posts for player 1
-- SELECT * FROM get_recent_instagram_posts(1, 3);

-- Get the top 5 most liked posts
-- SELECT * FROM get_top_liked_posts(5);

-- Add a new post for player 2
-- SELECT add_instagram_post(2, 'https://instagram.com/p/xyz567', 'Excited for playoffs!', '2024-06-09 12:00:00', 500, 30);

-- =========================================================
-- END OF FILE
--
