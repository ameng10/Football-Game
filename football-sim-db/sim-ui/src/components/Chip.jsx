import React from 'react';
import PropTypes from 'prop-types';

const Chip = ({ label, color = 'primary', onClick, style }) => {
    const colors = {
        primary: '#1976d2',
        secondary: '#9c27b0',
        success: '#388e3c',
        error: '#d32f2f',
        default: '#e0e0e0',
    };

    const textColor = color === 'default' ? '#000' : '#fff';

    return (
        <span
            onClick={onClick}
            style={{
                display: 'inline-block',
                padding: '0.25em 0.75em',
                borderRadius: '16px',
                background: colors[color] || colors.default,
                color: textColor,
                fontSize: '0.95em',
                cursor: onClick ? 'pointer' : 'default',
                userSelect: 'none',
                ...style,
            }}
            data-testid="chip"
        >
            {label}
        </span>
    );
};

Chip.propTypes = {
    label: PropTypes.string.isRequired,
    color: PropTypes.oneOf(['primary', 'secondary', 'success', 'error', 'default']),
    onClick: PropTypes.func,
    style: PropTypes.object,
};

export default Chip;
