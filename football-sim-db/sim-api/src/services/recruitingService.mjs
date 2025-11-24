import db from '../db/connection.mjs';

/**
 * Service for recruiting-related database operations.
 */
const recruitingService = {
    /**
     * Get all recruits for a given season.
     * @param {number} season
     * @returns {Promise<Array>}
     */
    async getRecruitsBySeason(season) {
        const query = 'SELECT * FROM recruits WHERE season = ?';
        const [rows] = await db.execute(query, [season]);
        return rows;
    },

    /**
     * Add a new recruit.
     * @param {Object} recruitData
     * @returns {Promise<Object>}
     */
    async addRecruit(recruitData) {
        const {
            name, position, rating, state, season, committedTeamId = null,
        } = recruitData;
        const query = `
            INSERT INTO recruits (name, position, rating, state, season, committed_team_id)
            VALUES (?, ?, ?, ?, ?, ?)
        `;
        const [result] = await db.execute(query, [
            name, position, rating, state, season, committedTeamId,
        ]);
        return { id: result.insertId, ...recruitData };
    },

    /**
     * Commit a recruit to a team.
     * @param {number} recruitId
     * @param {number} teamId
     * @returns {Promise<void>}
     */
    async commitRecruit(recruitId, teamId) {
        const query = `
            UPDATE recruits
            SET committed_team_id = ?
            WHERE id = ?
        `;
        await db.execute(query, [teamId, recruitId]);
    },

    /**
     * Get recruits committed to a specific team.
     * @param {number} teamId
     * @param {number} season
     * @returns {Promise<Array>}
     */
    async getTeamCommits(teamId, season) {
        const query = `
            SELECT * FROM recruits
            WHERE committed_team_id = ? AND season = ?
        `;
        const [rows] = await db.execute(query, [teamId, season]);
        return rows;
    },
};

export default recruitingService;
