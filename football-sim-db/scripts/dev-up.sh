#!/bin/bash

# dev-up.sh: Set up local development environment for football-sim-db

set -e

# Set project root
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Starting Football Sim DB development environment..."

# 1. Start PostgreSQL with Docker (if not already running)
DB_CONTAINER_NAME="football_sim_db"
DB_PORT=5432
DB_USER="football"
DB_PASSWORD="password"
DB_NAME="football_sim"

if ! docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER_NAME}$"; then
    echo "Starting PostgreSQL Docker container..."
    docker run -d \
        --name $DB_CONTAINER_NAME \
        -e POSTGRES_USER=$DB_USER \
        -e POSTGRES_PASSWORD=$DB_PASSWORD \
        -e POSTGRES_DB=$DB_NAME \
        -p $DB_PORT:5432 \
        postgres:15
else
    echo "PostgreSQL container already running."
fi

# 2. Wait for DB to be ready
echo "Waiting for PostgreSQL to be ready..."
until docker exec $DB_CONTAINER_NAME pg_isready -U $DB_USER > /dev/null 2>&1; do
    sleep 1
done

# 3. Run database migrations (if using a tool like Flyway or Prisma, adjust accordingly)
if [ -f "$PROJECT_ROOT/scripts/migrate.sh" ]; then
    echo "Running database migrations..."
    bash "$PROJECT_ROOT/scripts/migrate.sh"
fi

# 4. (Optional) Seed the database
if [ -f "$PROJECT_ROOT/scripts/seed.sh" ]; then
    echo "Seeding the database..."
    bash "$PROJECT_ROOT/scripts/seed.sh"
fi

echo "Development environment is up!"
