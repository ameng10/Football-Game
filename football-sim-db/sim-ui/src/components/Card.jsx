import React from 'react';
import PropTypes from 'prop-types';
import './Card.css'; // Optional: create this file for custom styles

const Card = ({ title, children, className = '', onClick }) => (
    <div className={`card ${className}`} onClick={onClick} tabIndex={onClick ? 0 : undefined} role={onClick ? 'button' : undefined}>
        {title && <div className="card-title">{title}</div>}
        <div className="card-content">{children}</div>
    </div>
);

Card.propTypes = {
    title: PropTypes.string,
    children: PropTypes.node.isRequired,
    className: PropTypes.string,
    onClick: PropTypes.func,
};

export default Card;
