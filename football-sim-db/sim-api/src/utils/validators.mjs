/**
 * validators.mjs
 * Utility functions for validating input data in the football-sim-db sim-api.
 */

/**
 * Validates that a value is a non-empty string.
 * @param {any} value
 * @returns {boolean}
 */
export function isNonEmptyString(value) {
    return typeof value === 'string' && value.trim().length > 0;
}

/**
 * Validates that a value is a positive integer.
 * @param {any} value
 * @returns {boolean}
 */
export function isPositiveInteger(value) {
    return Number.isInteger(value) && value > 0;
}

/**
 * Validates that a value is a valid email address.
 * @param {string} value
 * @returns {boolean}
 */
export function isValidEmail(value) {
    if (typeof value !== 'string') return false;
    // Simple email regex
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

/**
 * Validates that a value is a valid date string (ISO 8601).
 * @param {string} value
 * @returns {boolean}
 */
export function isValidDate(value) {
    if (typeof value !== 'string') return false;
    const date = new Date(value);
    return !isNaN(date.getTime());
}

/**
 * Validates that a value is a valid player position.
 * @param {string} value
 * @returns {boolean}
 */
export function isValidPlayerPosition(value) {
    const positions = ['QB', 'RB', 'WR', 'TE', 'K', 'DEF', 'LB', 'CB', 'S', 'OL', 'DL'];
    return positions.includes(value);
}
