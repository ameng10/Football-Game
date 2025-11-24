import { getTeamById, updateTeamStats } from '../repositories/teamRepository.mjs';
import { getMatchById, saveMatchResult } from '../repositories/matchRepository.mjs';

/**
 * Simulates a football match between two teams.
 * @param {string} homeTeamId
 * @param {string} awayTeamId
 * @returns {Promise<Object>} Match result
 */
export async function simulateMatch(homeTeamId, awayTeamId) {
    const homeTeam = await getTeamById(homeTeamId);
    const awayTeam = await getTeamById(awayTeamId);

    if (!homeTeam || !awayTeam) {
        throw new Error('One or both teams not found');
    }

    // Simple simulation logic: random goals based on team strength
    const homeGoals = Math.max(0, Math.round(Math.random() * homeTeam.strength));
    const awayGoals = Math.max(0, Math.round(Math.random() * awayTeam.strength));

    // Update team stats
    await updateTeamStats(homeTeamId, homeGoals, awayGoals);
    await updateTeamStats(awayTeamId, awayGoals, homeGoals);

    // Save match result
    const matchResult = {
        homeTeamId,
        awayTeamId,
        homeGoals,
        awayGoals,
        playedAt: new Date().toISOString()
    };
    await saveMatchResult(matchResult);

    return matchResult;
}

/**
 * Retrieves and simulates a match by its ID.
 * @param {string} matchId
 * @returns {Promise<Object>} Simulated match result
 */
export async function simulateMatchById(matchId) {
    const match = await getMatchById(matchId);
    if (!match) {
        throw new Error('Match not found');
    }
    return simulateMatch(match.homeTeamId, match.awayTeamId);
}
