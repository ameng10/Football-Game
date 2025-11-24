import React, { useState, useEffect, useRef } from 'react';
import PropTypes from 'prop-types';
import './ClickTargets.css';

// Utility to generate random positions within the container
const getRandomPosition = (containerWidth, containerHeight, size) => {
    const x = Math.random() * (containerWidth - size);
    const y = Math.random() * (containerHeight - size);
    return { x, y };
};

const TARGET_SIZE = 50; // px

const ClickTargets = ({ onScore, numTargets = 5, duration = 30 }) => {
    const [targets, setTargets] = useState([]);
    const [score, setScore] = useState(0);
    const [timeLeft, setTimeLeft] = useState(duration);
    const containerRef = useRef(null);

    // Initialize targets
    useEffect(() => {
        if (containerRef.current) {
            const { offsetWidth, offsetHeight } = containerRef.current;
            const newTargets = Array.from({ length: numTargets }).map(() =>
                getRandomPosition(offsetWidth, offsetHeight, TARGET_SIZE)
            );
            setTargets(newTargets);
        }
    }, [numTargets]);

    // Timer countdown
    useEffect(() => {
        if (timeLeft <= 0) return;
        const timer = setInterval(() => setTimeLeft(t => t - 1), 1000);
        return () => clearInterval(timer);
    }, [timeLeft]);

    // Handle target click
    const handleTargetClick = idx => {
        if (timeLeft <= 0) return;
        setScore(s => s + 1);
        if (onScore) onScore(score + 1);
        // Move the clicked target to a new random position
        setTargets(ts => {
            if (!containerRef.current) return ts;
            const { offsetWidth, offsetHeight } = containerRef.current;
            const newTargets = [...ts];
            newTargets[idx] = getRandomPosition(offsetWidth, offsetHeight, TARGET_SIZE);
            return newTargets;
        });
    };

    return (
        <div className="click-targets-container" ref={containerRef}>
            <div className="click-targets-info">
                <span>Score: {score}</span>
                <span>Time Left: {timeLeft}s</span>
            </div>
            {targets.map((pos, idx) => (
                <div
                    key={idx}
                    className="click-target"
                    style={{
                        left: pos.x,
                        top: pos.y,
                        width: TARGET_SIZE,
                        height: TARGET_SIZE,
                        pointerEvents: timeLeft > 0 ? 'auto' : 'none',
                    }}
                    onClick={() => handleTargetClick(idx)}
                />
            ))}
            {timeLeft <= 0 && (
                <div className="click-targets-end">
                    <h2>Game Over!</h2>
                    <p>Your Score: {score}</p>
                </div>
            )}
        </div>
    );
};

ClickTargets.propTypes = {
    onScore: PropTypes.func,
    numTargets: PropTypes.number,
    duration: PropTypes.number,
};

export default ClickTargets;
