/**
 * Error handling middleware for Express.js
 * Sends JSON error responses with appropriate status codes.
 */

export function errorHandler(err, req, res, next) {
    // Default to 500 Internal Server Error
    const status = err.status || 500;
    const message = err.message || 'Internal Server Error';

    // Log the error (customize as needed)
    if (process.env.NODE_ENV !== 'test') {
        console.error(err);
    }

    res.status(status).json({
        error: {
            message,
            status,
        },
    });
}
