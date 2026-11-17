#!/usr/bin/env bash
# Builds a throwaway database, loads synthetic data and runs demo/walkthrough.sql.
#   PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=pw bash scripts/demo.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${LEDGER_DEMO_DB:-ledger_demo}"
export PGHOST="${PGHOST:-127.0.0.1}" PGUSER="${PGUSER:-postgres}"

dropdb --if-exists "$DB"
createdb "$DB"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f db/test-support/stub_auth.sql
for f in db/migrations/*.sql; do psql -q -v ON_ERROR_STOP=1 -1 -d "$DB" -f "$f"; done
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f db/seed/demo_seed.sql
psql -d "$DB" -f demo/walkthrough.sql
