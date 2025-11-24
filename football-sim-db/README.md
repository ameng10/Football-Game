# Football Sim DB + API + UI

Postgres-backed football sim stack with a Node/Express API and Vite/React UI. Docker Compose spins up Postgres and seeds everything via `db-init/`.

## Stack
- Postgres 15 (dockerized)
- Node 18+ for `sim-api`
- Vite/React for `sim-ui`

## Quickstart (local)
1) Start Postgres  
```bash
cd football-sim-db
docker-compose up -d
```

2) Seed the database (matches compose creds: DB=footballdb, USER=simuser)  
```bash
cd football-sim-db
DB=footballdb USER=simuser ./db-init/run_all.sh
```

3) API  
```bash
cd sim-api
npm install
DATABASE_URL=postgres://simuser:simpass@localhost:5432/footballdb npm run dev
# or set PG* env vars equivalently
```

4) UI  
```bash
cd sim-ui
npm install
npm run dev  # Vite on http://localhost:5173
```
The UI expects the API at `http://localhost:3001/api` (default server port 3001).

## Notes
- SQL initialization order is defined in `db-init/run_all.sh` (career schema, HS generation, recruiting, injuries, dashboard views, etc.).
- If you rerun seeds on a dirty DB, drop or recreate the `footballdb` database first.

## Troubleshooting
- Connection refused: ensure `docker-compose ps` shows Postgres healthy and your `DATABASE_URL` uses `footballdb`/`simuser`/`simpass`.
- Missing functions/views: rerun `DB=footballdb USER=simuser ./db-init/run_all.sh`.

## One-command dev (compose + seed + API + UI)
From `football-sim-db`, run:
```bash
./dev-one.sh
```
This will start docker-compose Postgres, wait for readiness, seed the DB, install API/UI deps, and launch both dev servers via `concurrently`.
Make sure Docker Desktop (or your Docker daemon) is running first.
