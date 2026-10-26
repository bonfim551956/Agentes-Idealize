#!/usr/bin/env bash
# Worker real (Deno) + Postgres real descartável. Download, storage e Claude são simulados no teste.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB=idealize_ai_e2e; export PGUSER=${PGUSER:-postgres}
dropdb --if-exists "$DB" >/dev/null; createdb "$DB"
P="psql -X -q -v ON_ERROR_STOP=1 -d $DB"
$P -f tests/00_supabase_stub.sql
for m in supabase/migrations/*.sql; do $P -f "$m"; done
$P -f tests/e2e/seed.sql >/dev/null
cd supabase/functions/fin-worker
SUPABASE_DB_URL="postgres://${PGUSER}@127.0.0.1:${PGPORT:-5432}/$DB" deno test -A worker_test.ts e2e_test.ts 2>&1 | grep -E " ok | FAILED|passed|failed|esperado"
