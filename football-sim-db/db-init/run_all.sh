#!/usr/bin/env bash
set -euo pipefail

# Match docker-compose defaults (Postgres service)
DB=${DB:-footballdb}
USER=${USER:-simuser}

psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/1-schema.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/2-compat_views_triggers.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/3-seed_data.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/4-functions-sim.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/5-functions-compat.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/6-sample_schedule.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/7-smoke_tests.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/8-debug_reset.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/9-career_schema.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/10-career_functions.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/11-hs_generation.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/12-player_stats_views.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/13-award_logic.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/14-recruiting_engine.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/15-depth_chart_logic.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/16-playoff_bracket_engine.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/17-injury_fatigue_model.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/18-training_balancer.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/19-feed_instagram.sql
psql -v ON_ERROR_STOP=1 -d "$DB" -U "$USER" -f db-init/20-views_career_dashboard.sql


echo "✅ DB initialized. Try the UI now."
