import { getPlayerById, updatePlayerCareer, createCareerRecord } from '../db/playerRepository.mjs';
import { getTeamById } from '../db/teamRepository.mjs';

/**
 * Retrieves a player's career information.
 * @param {string} playerId
 * @returns {Promise<Object>} Career data
 */
export async function getCareer(playerId) {
    const player = await getPlayerById(playerId);
    if (!player) throw new Error('Player not found');
    return player.career || {};
}

/**
 * Updates a player's career stats.
 * @param {string} playerId
 * @param {Object} careerUpdates
 * @returns {Promise<Object>} Updated career data
 */
export async function updateCareer(playerId, careerUpdates) {
    const player = await getPlayerById(playerId);
    if (!player) throw new Error('Player not found');
    const updatedCareer = { ...player.career, ...careerUpdates };
    await updatePlayerCareer(playerId, updatedCareer);
    return updatedCareer;
}

/**
 * Adds a new career record for a player (e.g., new season).
 * @param {string} playerId
 * @param {Object} record
 * @returns {Promise<Object>} New career record
 */
export async function addCareerRecord(playerId, record) {
    const player = await getPlayerById(playerId);
    if (!player) throw new Error('Player not found');
    const team = await getTeamById(record.teamId);
    if (!team) throw new Error('Team not found');
    const newRecord = await createCareerRecord(playerId, record);
    return newRecord;
}
