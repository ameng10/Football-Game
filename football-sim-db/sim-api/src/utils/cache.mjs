/**
 * Simple in-memory cache utility for the football-sim-db sim-api.
 * Provides get, set, and clear methods.
 */

const cache = new Map();

/**
 * Get a value from the cache.
 * @param {string} key
 * @returns {any} Cached value or undefined if not found.
 */
export function getCache(key) {
    return cache.get(key);
}

/**
 * Set a value in the cache.
 * @param {string} key
 * @param {any} value
 */
export function setCache(key, value) {
    cache.set(key, value);
}

/**
 * Clear a value from the cache.
 * @param {string} key
 */
export function clearCache(key) {
    cache.delete(key);
}

/**
 * Clear all cache entries.
 */
export function clearAllCache() {
    cache.clear();
}
