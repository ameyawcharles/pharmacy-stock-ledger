#!/usr/bin/env bash
# Builds a throwaway database from the migrations and runs the concurrency/correctness suite.
# Needs: PostgreSQL 15+ reachable via the usual PG* variables, psql/createdb/dropdb, and
#        Python 3 with psycopg2 (pip install psycopg2-binary).
#
#   PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=pw bash scripts/run_tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${LEDGER_DB:-ledger_test}"
export PGHOST="${PGHOST:-127.0.0.1}" PGUSER="${PGUSER:-postgres}"

dropdb --if-exists "$DB"
createdb "$DB"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f db/test-support/stub_auth.sql
for f in db/migrations/*.sql; do
  echo "applying $f"
  psql -q -v ON_ERROR_STOP=1 -1 -d "$DB" -f "$f"
done

PG_DSN="host=$PGHOST dbname=$DB user=$PGUSER password=${PGPASSWORD:-}" python3 tests/harness.py
