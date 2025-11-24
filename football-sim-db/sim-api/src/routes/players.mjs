import express from 'express';
import { getAllPlayers, getPlayerById, createPlayer, updatePlayer, deletePlayer } from '../controllers/players.mjs';

const router = express.Router();

// GET /players - Get all players
router.get('/', async (req, res) => {
    try {
        const players = await getAllPlayers();
        res.json(players);
    } catch (err) {
        res.status(500).json({ error: 'Failed to fetch players' });
    }
});

// GET /players/:id - Get player by ID
router.get('/:id', async (req, res) => {
    try {
        const player = await getPlayerById(req.params.id);
        if (!player) {
            return res.status(404).json({ error: 'Player not found' });
        }
        res.json(player);
    } catch (err) {
        res.status(500).json({ error: 'Failed to fetch player' });
    }
});

// POST /players - Create a new player
router.post('/', async (req, res) => {
    try {
        const newPlayer = await createPlayer(req.body);
        res.status(201).json(newPlayer);
    } catch (err) {
        res.status(400).json({ error: 'Failed to create player' });
    }
});

// PUT /players/:id - Update a player
router.put('/:id', async (req, res) => {
    try {
        const updatedPlayer = await updatePlayer(req.params.id, req.body);
        if (!updatedPlayer) {
            return res.status(404).json({ error: 'Player not found' });
        }
        res.json(updatedPlayer);
    } catch (err) {
        res.status(400).json({ error: 'Failed to update player' });
    }
});

// DELETE /players/:id - Delete a player
router.delete('/:id', async (req, res) => {
    try {
        const deleted = await deletePlayer(req.params.id);
        if (!deleted) {
            return res.status(404).json({ error: 'Player not found' });
        }
        res.json({ message: 'Player deleted' });
    } catch (err) {
        res.status(500).json({ error: 'Failed to delete player' });
    }
});

export default router;
