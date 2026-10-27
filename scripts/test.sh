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
echo "→ testes do canal WhatsApp"
$P -f tests/50_fin_whatsapp.sql
echo "→ testes do painel (camada de acesso)"
$P -f tests/60_painel.sql
echo "→ testes do agente de laboratório"
$P -f tests/70_lab.sql
echo "→ testes do agente comercial"
$P -f tests/80_com.sql
echo "→ testes do agente de marketing"
$P -f tests/90_mkt.sql
echo "→ testes do agente de caixa"
$P -f tests/95_cx.sql
echo "→ concorrência (4 workers × 200 tarefas)"
tests/concorrencia/run.sh
echo "→ funções (Deno): unidade + ponta a ponta"
tests/e2e/run.sh
echo "→ função de sincronização do laboratório (Deno)"
(cd supabase/functions && deno test --allow-env lab-sync/normalizar_test.ts 2>&1 | grep -E "passed|failed")
echo "→ função de sincronização comercial / Kommo (Deno)"
(cd supabase/functions && deno test --allow-env kommo-sync/normalizar_test.ts 2>&1 | grep -E "passed|failed")
echo "→ função de sincronização de marketing / Meta (Deno)"
(cd supabase/functions && deno test --allow-env meta-sync/normalizar_test.ts 2>&1 | grep -E "passed|failed")
echo "→ função de sincronização do caixa (Deno)"
(cd supabase/functions && deno test --allow-env caixa-sync/normalizar_test.ts 2>&1 | grep -E "passed|failed")
