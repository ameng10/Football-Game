import React from 'react';

// Example props: { rounds: [[{ team1: 'A', team2: 'B', score1: 1, score2: 2 }, ...], ...] }
const BracketView = ({ rounds }) => {
    if (!rounds || rounds.length === 0) {
        return <div>No bracket data available.</div>;
    }

    return (
        <div className="bracket-view" style={{ display: 'flex', gap: '2rem', overflowX: 'auto' }}>
            {rounds.map((round, roundIdx) => (
                <div key={roundIdx} className="bracket-round">
                    <h4>Round {roundIdx + 1}</h4>
                    <div>
                        {round.map((match, matchIdx) => (
                            <div key={matchIdx} className="bracket-match" style={{ marginBottom: '1rem', border: '1px solid #ccc', padding: '0.5rem', borderRadius: '4px' }}>
                                <div>
                                    <strong>{match.team1}</strong> {typeof match.score1 === 'number' && `(${match.score1})`}
                                </div>
                                <div>
                                    <strong>{match.team2}</strong> {typeof match.score2 === 'number' && `(${match.score2})`}
                                </div>
                            </div>
                        ))}
                    </div>
                </div>
            ))}
        </div>
    );
};

export default BracketView;
