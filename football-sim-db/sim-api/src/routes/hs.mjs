import express from 'express';

// Example: High School Football Simulation API routes
const router = express.Router();

// GET all high school teams
router.get('/teams', async (req, res) => {
    // Replace with actual DB call
    const teams = [
        { id: 1, name: 'Springfield High' },
        { id: 2, name: 'Riverview Prep' }
    ];
    res.json(teams);
});

// GET a specific team by ID
router.get('/teams/:id', async (req, res) => {
    const { id } = req.params;
    // Replace with actual DB call
    const team = { id, name: 'Springfield High' };
    res.json(team);
});

// POST create a new team
router.post('/teams', async (req, res) => {
    const { name } = req.body;
    // Replace with actual DB insert
    const newTeam = { id: Date.now(), name };
    res.status(201).json(newTeam);
});

// Export the router for use in your main app
export default router;
