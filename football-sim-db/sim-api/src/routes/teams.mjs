import express from 'express';
import { getAllTeams, getTeamById, createTeam, updateTeam, deleteTeam } from '../controllers/teams.mjs';

const router = express.Router();

// GET /teams - Get all teams
router.get('/', async (req, res) => {
    try {
        const teams = await getAllTeams();
        res.json(teams);
    } catch (err) {
        res.status(500).json({ error: 'Failed to fetch teams' });
    }
});

// GET /teams/:id - Get a team by ID
router.get('/:id', async (req, res) => {
    try {
        const team = await getTeamById(req.params.id);
        if (!team) {
            return res.status(404).json({ error: 'Team not found' });
        }
        res.json(team);
    } catch (err) {
        res.status(500).json({ error: 'Failed to fetch team' });
    }
});

// POST /teams - Create a new team
router.post('/', async (req, res) => {
    try {
        const newTeam = await createTeam(req.body);
        res.status(201).json(newTeam);
    } catch (err) {
        res.status(400).json({ error: 'Failed to create team' });
    }
});

// PUT /teams/:id - Update a team
router.put('/:id', async (req, res) => {
    try {
        const updatedTeam = await updateTeam(req.params.id, req.body);
        if (!updatedTeam) {
            return res.status(404).json({ error: 'Team not found' });
        }
        res.json(updatedTeam);
    } catch (err) {
        res.status(400).json({ error: 'Failed to update team' });
    }
});

// DELETE /teams/:id - Delete a team
router.delete('/:id', async (req, res) => {
    try {
        const deleted = await deleteTeam(req.params.id);
        if (!deleted) {
            return res.status(404).json({ error: 'Team not found' });
        }
        res.json({ message: 'Team deleted' });
    } catch (err) {
        res.status(500).json({ error: 'Failed to delete team' });
    }
});

export default router;
