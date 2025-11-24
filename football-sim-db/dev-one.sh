#!/usr/bin/env bash
set -euo pipefail

# One-command local stack runner: Postgres (compose) + seed + API + UI
# Usage: from football-sim-db dir -> ./dev-one.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "▶️  Starting Postgres via docker-compose..."
# Check Docker daemon
if ! docker info >/dev/null 2>&1; then
  echo "❌ Docker daemon not running. Start Docker Desktop (or dockerd) and retry." >&2
  exit 1
fi

docker-compose up -d

echo "⏳ Waiting for Postgres to be ready..."
until docker exec football-sim-postgres pg_isready -U simuser >/dev/null 2>&1; do
  sleep 1
done

echo "🧩 Seeding database..."
PGHOST=localhost PGPORT=5432 PGPASSWORD=simpass DB=footballdb USER=simuser ./db-init/run_all.sh

echo "📦 Installing dependencies (API/UI)..."
(cd sim-api && npm install)
(cd sim-ui && npm install)

echo "🚀 Starting API (3001) and UI (5173)..."
npx concurrently -n API,UI -c green,blue \
  "cd sim-api && PORT=3001 npm run dev" \
  "cd sim-ui && npm run dev"
