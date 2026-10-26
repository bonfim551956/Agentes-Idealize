#!/usr/bin/env bash
# Recria um banco descartável, aplica todas as migrações em ordem e roda a suíte.
# Uso: PGHOST=/tmp PGPORT=54329 ./scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=idealize_ai_test
export PGUSER=${PGUSER:-postgres}
dropdb --if-exists "$DB" >/dev/null
createdb "$DB"
P="psql -X -q -v ON_ERROR_STOP=1 -d $DB"
$P -f tests/00_supabase_stub.sql
for m in supabase/migrations/*.sql; do echo "→ migração $(basename "$m")"; $P -f "$m"; done
echo "→ testes"
$P -f tests/10_core_tests.sql
echo "→ testes financeiros"
$P -f tests/20_fin_tests.sql
echo "→ testes de conciliação por documento"
$P -f tests/30_fin_conciliacao_documento.sql
echo "→ testes das decisões da homologação"
$P -f tests/40_fin_decisoes.sql
echo "→ concorrência (4 workers × 200 tarefas)"
tests/concorrencia/run.sh
