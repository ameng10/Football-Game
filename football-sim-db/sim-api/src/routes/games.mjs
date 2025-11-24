import express from 'express';
import { getAllGames, getGameById, createGame, updateGame, deleteGame } from '../controllers/gamesController.mjs';

const router = express.Router();

// GET /games - Get all games
router.get('/', async (req, res) => {
    try {
        const games = await getAllGames();
        res.json(games);
    } catch (err) {
        res.status(500).json({ error: 'Failed to fetch games.' });
    }
});

// GET /games/:id - Get a single game by ID
router.get('/:id', async (req, res) => {
    try {
        const game = await getGameById(req.params.id);
        if (!game) {
            return res.status(404).json({ error: 'Game not found.' });
        }
        res.json(game);
    } catch (err) {
        res.status(500).json({ error: 'Failed to fetch game.' });
    }
});

// POST /games - Create a new game
router.post('/', async (req, res) => {
    try {
        const newGame = await createGame(req.body);
        res.status(201).json(newGame);
    } catch (err) {
        res.status(400).json({ error: 'Failed to create game.' });
    }
});

// PUT /games/:id - Update a game
router.put('/:id', async (req, res) => {
    try {
        const updatedGame = await updateGame(req.params.id, req.body);
        if (!updatedGame) {
            return res.status(404).json({ error: 'Game not found.' });
        }
        res.json(updatedGame);
    } catch (err) {
        res.status(400).json({ error: 'Failed to update game.' });
    }
});

// DELETE /games/:id - Delete a game
router.delete('/:id', async (req, res) => {
    try {
        const deleted = await deleteGame(req.params.id);
        if (!deleted) {
            return res.status(404).json({ error: 'Game not found.' });
        }
        res.json({ message: 'Game deleted.' });
    } catch (err) {
        res.status(500).json({ error: 'Failed to delete game.' });
    }
});

export default router;
