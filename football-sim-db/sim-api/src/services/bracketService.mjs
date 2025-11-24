import { getBracketById, saveBracket, updateBracket, deleteBracket } from '../repositories/bracketRepository.mjs';

/**
 * Retrieves a bracket by its ID.
 * @param {string} bracketId
 * @returns {Promise<Object|null>}
 */
export async function fetchBracket(bracketId) {
    return await getBracketById(bracketId);
}

/**
 * Creates a new bracket.
 * @param {Object} bracketData
 * @returns {Promise<Object>}
 */
export async function createBracket(bracketData) {
    return await saveBracket(bracketData);
}

/**
 * Updates an existing bracket.
 * @param {string} bracketId
 * @param {Object} updates
 * @returns {Promise<Object|null>}
 */
export async function modifyBracket(bracketId, updates) {
    return await updateBracket(bracketId, updates);
}

/**
 * Deletes a bracket by its ID.
 * @param {string} bracketId
 * @returns {Promise<boolean>}
 */
export async function removeBracket(bracketId) {
    return await deleteBracket(bracketId);
}
