#!/bin/bash

# api-dev.sh: Start the API server in development mode for football-sim-db

# Set environment variables
export FLASK_ENV=development
export FLASK_APP=football_sim_api.app:create_app

# Activate virtual environment if exists
if [ -d "../venv" ]; then
    source ../venv/bin/activate
fi

# Run database migrations (if using Flask-Migrate)
if [ -f "../migrations/env.py" ]; then
    flask db upgrade
fi

# Start the API server
flask run --host=0.0.0.0 --port=5000
