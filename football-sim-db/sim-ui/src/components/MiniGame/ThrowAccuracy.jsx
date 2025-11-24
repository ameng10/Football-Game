import React, { useState } from 'react';
import PropTypes from 'prop-types';
import './ThrowAccuracy.css';

/**
 * ThrowAccuracy MiniGame Component
 * Simulates a throw accuracy minigame for a football simulation.
 *
 * Props:
 * - onResult: function(result: { success: boolean, score: number }) => void
 * - difficulty: 'easy' | 'medium' | 'hard'
 */
const DIFFICULTY_SETTINGS = {
    easy: { speed: 2, targetSize: 80 },
    medium: { speed: 4, targetSize: 50 },
    hard: { speed: 6, targetSize: 30 },
};

function getRandomInt(min, max) {
    return Math.floor(Math.random() * (max - min + 1)) + min;
}

const ThrowAccuracy = ({ onResult, difficulty = 'medium' }) => {
    const [throwing, setThrowing] = useState(false);
    const [targetPos, setTargetPos] = useState(getRandomInt(10, 210));
    const [markerPos, setMarkerPos] = useState(0);
    const [score, setScore] = useState(null);

    const { speed, targetSize } = DIFFICULTY_SETTINGS[difficulty];

    React.useEffect(() => {
        if (!throwing) return;
        const interval = setInterval(() => {
            setMarkerPos((pos) => (pos + speed) % 300);
        }, 16);
        return () => clearInterval(interval);
    }, [throwing, speed]);

    const handleThrow = () => {
        setThrowing(false);
        const centerTarget = targetPos + targetSize / 2;
        const diff = Math.abs(markerPos - centerTarget);
        const maxDiff = targetSize / 2;
        const hit = diff <= maxDiff;
        const accuracyScore = Math.max(0, 100 - (diff / maxDiff) * 100);
        setScore(hit ? Math.round(accuracyScore) : 0);
        if (onResult) {
            onResult({ success: hit, score: Math.round(accuracyScore) });
        }
    };

    const handleStart = () => {
        setScore(null);
        setTargetPos(getRandomInt(10, 210));
        setMarkerPos(0);
        setThrowing(true);
    };

    return (
        <div className="throw-accuracy-container">
            <h3>Throw Accuracy MiniGame</h3>
            <div className="throw-bar">
                <div
                    className="target"
                    style={{
                        left: targetPos,
                        width: targetSize,
                    }}
                />
                <div
                    className="marker"
                    style={{
                        left: markerPos,
                    }}
                />
            </div>
            <button onClick={throwing ? handleThrow : handleStart}>
                {throwing ? 'Throw!' : 'Start'}
            </button>
            {score !== null && (
                <div className="result">
                    {score > 0 ? `Hit! Score: ${score}` : 'Miss!'}
                </div>
            )}
        </div>
    );
};

ThrowAccuracy.propTypes = {
    onResult: PropTypes.func,
    difficulty: PropTypes.oneOf(['easy', 'medium', 'hard']),
};

export default ThrowAccuracy;
