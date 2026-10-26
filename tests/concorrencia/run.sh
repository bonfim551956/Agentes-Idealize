#!/usr/bin/env bash
# 200 tarefas, 4 workers simultâneos: nenhuma tarefa pode ser executada 2 vezes.
set -euo pipefail
cd "$(dirname "$0")/../.."
D=idealize_ai_test; P="psql -X -q -v ON_ERROR_STOP=1 -d $D"
$P -c "update core.tarefas set status='cancelada' where status in ('pronta','aguardando_aprovacao','bloqueada');
select count(core.criar_tarefa('00000000-0000-0000-0000-00000000000d','teste','carga','fin.lanc','registrar','loja_a',
  jsonb_build_object('i',g),'carga-'||lpad(g::text,6,'0'),1)) from generate_series(1,200) g;" >/dev/null
for w in w1 w2 w3 w4; do sed "s/WID/$w/g" tests/concorrencia/worker.sql | $P 2>&1 & done; wait
$P -At -c "select 'tarefas='||count(*)||' validando='||count(*) filter (where status='validando')||
  ' execucoes='||(select count(*) from core.execucoes e join core.tarefas t2 on t2.id=e.tarefa_id where t2.tipo='carga')||
  ' duplicadas='||(select count(*) from (select tarefa_id from core.execucoes e join core.tarefas t2 on t2.id=e.tarefa_id
     where t2.tipo='carga' group by tarefa_id having count(*)>1) z)||
  ' workers_usados='||(select count(distinct executor) from core.tarefas where tipo='carga')
  from core.tarefas where tipo='carga';"
$P -At -c "select 'cadeia_auditoria='||coalesce(core.verificar_auditoria()::text,'integra')||' eventos='||count(*) from core.auditoria"
