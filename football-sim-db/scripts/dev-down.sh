#!/bin/bash

# dev-down.sh
# Stops and removes development Docker containers, networks, and volumes for the football-sim-db project.

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$PROJECT_DIR"

echo "Stopping and removing development containers for football-sim-db..."

if [ -f docker-compose.dev.yml ]; then
    docker-compose -f docker-compose.dev.yml down -v
else
    echo "docker-compose.dev.yml not found in $PROJECT_DIR"
    exit 1
fi

echo "Development environment stopped and cleaned up."
