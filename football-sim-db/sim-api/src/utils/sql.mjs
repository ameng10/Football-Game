import mysql from 'mysql2/promise';

// Create a connection pool (adjust config as needed)
const pool = mysql.createPool({
    host: process.env.DB_HOST || 'localhost',
    user: process.env.DB_USER || 'root',
    password: process.env.DB_PASS || '',
    database: process.env.DB_NAME || 'football_sim',
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0,
});

/**
 * Executes a SQL query with optional parameters.
 * @param {string} sql - The SQL query string.
 * @param {Array} [params] - Optional array of parameters for the query.
 * @returns {Promise<any>} - The result of the query.
 */
export async function query(sql, params = []) {
    const [rows] = await pool.execute(sql, params);
    return rows;
}

/**
 * Closes all connections in the pool.
 */
export async function closePool() {
    await pool.end();
}
