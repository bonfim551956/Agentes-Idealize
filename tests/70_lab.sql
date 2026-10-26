-- Agente de Laboratório (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;

insert into core.unidades (id, nome) values ('campinas','Campinas'), ('sao_vicente','São Vicente'), ('sorocaba','Sorocaba')
on conflict (id) do nothing;
insert into lab.unidades_origem (origem, unidade_id) values ('campinas','campinas'), ('saovicente','sao_vicente'), ('sorocaba','sorocaba')
on conflict (origem) do nothing;

-- ---------------------------------------------------------------------------
-- A. Nasce desligado e só lê
-- ---------------------------------------------------------------------------
select t.ok('travas','agente nasce pausado', (select status from core.agentes where id = 'laboratorio') = 'pausado');
select t.ok('travas','sincronização nasce desligada', core.cfg('lab.sync.ativo') = 'false');
select t.ok('travas','desligado: não cria tarefa', lab.agendar_sincronizacao() is null);
select t.ok('travas','agente proibido de criar/alterar/cancelar pedido no laboratório',
  (select bool_and((core.autorizar(p.id, 'lab.pedido', op, 'campinas')).categoria = 'proibida')
   from core.principais p, unnest(array['criar','alterar','cancelar']) op where p.agente_id = 'laboratorio'));
select t.ok('travas','espelho não tem colunas de dados pessoais',
  not exists (select 1 from information_schema.columns where table_schema = 'lab' and table_name = 'os'
              and column_name in ('cliente','telefone','receita','valor_venda','esf_od','cil_od')));

-- liga só para o teste
update core.agentes set status = 'ativo' where id = 'laboratorio';
update core.config set valor = 'true' where chave = 'lab.sync.ativo';

create function t.lote_base() returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('id','os_r1','unidade','campinas','os','1001','ped','','tipo','venda','lab','Lab Próprio','col',1,
      'prazo', (lab._hoje() - 5)::text, 'entrou_etapa_ms', (extract(epoch from date_trunc('day', now()) - interval '10 days') * 1000)::bigint::text,
      'cliente','Fulano de Tal','telefone','5513999990001'),
    jsonb_build_object('id','os_r2','unidade','saovicente','os','2002','ped','P-77','tipo','venda','lab','LAB PRÓPRIO','col',4,
      'prazo', (lab._hoje() + 3)::text, 'entrou_etapa_ms', (extract(epoch from date_trunc('day', now()) - interval '20 days') * 1000)::bigint::text, 'saldo_aberto', true),
    jsonb_build_object('id','os_r3','unidade','sorocaba','os','3003','ped','P-88','tipo','venda','lab','LAB PARCEIRO','col',5,
      'prazo', (lab._hoje() - 90)::text),
    jsonb_build_object('id','os_r4','unidade','xpto','os','4004','col',1),
    jsonb_build_object('id','os_r5','unidade','campinas','os','5005','ped','P-99','tipo','venda','col',8),
    jsonb_build_object('unidade','campinas','col',1),
    jsonb_build_object('id','os_r7','unidade','sorocaba','os','7007','ped','P-70','tipo','gar-pedido','lab','LAB PRÓPRIO','col',3,
      'refeito', true, 'prazo', (lab._hoje() + 2)::text, 'entrou_etapa_ms', (extract(epoch from date_trunc('day', now())) * 1000)::bigint::text))
$$;

create function t.sincronizar(lote jsonb, executor text default 'lab-sync') returns jsonb language plpgsql as $$
declare v_t uuid; v jsonb;
begin
  v_t := lab.agendar_sincronizacao();
  -- uma tarefa por janela de 15 min: no teste, força chave nova
  if exists (select 1 from core.tarefas where id = v_t and status <> 'pronta') then
    v_t := core.criar_tarefa((select id from core.principais where agente_id = 'laboratorio'), 'laboratorio', 'lab_sincronizacao',
      'lab.os', 'sincronizar', null, '{"origem":"adm_os_cards"}', 'lab:teste:' || gen_random_uuid(), null, 6);
  end if;
  perform core.reivindicar('laboratorio', executor, 120);
  v := lab.concluir_sincronizacao(v_t, executor, lote);
  return v || jsonb_build_object('tarefa', v_t, 'validacao', lab.validar_sincronizacao(v_t, 'validador_sql'));
end $$;

-- ---------------------------------------------------------------------------
-- B. Primeira sincronização
-- ---------------------------------------------------------------------------
select set_config('t.s1', t.sincronizar(t.lote_base())::text, false);
select t.ok('sync','contagens do lote (7 recebidas, 5 aplicadas, 2 ignoradas)',
  (current_setting('t.s1')::jsonb->>'recebidas')::int = 7 and (current_setting('t.s1')::jsonb->>'aplicadas')::int = 5
  and (current_setting('t.s1')::jsonb->>'ignoradas')::int = 2, current_setting('t.s1'));
select t.ok('sync','validador independente aprovou e a tarefa concluiu',
  current_setting('t.s1')::jsonb->>'validacao' = 'concluida'
  and (select status from core.tarefas where id = (current_setting('t.s1')::jsonb->>'tarefa')::uuid) = 'concluida');
select t.ok('sync','unidade do kanban mapeada (saovicente → sao_vicente)',
  (select unidade_id from lab.os where id_origem = 'os_r2') = 'sao_vicente');
select t.ok('alertas','prazo vencido em OS em andamento', exists (select 1 from lab.alertas where id_origem = 'os_r1' and tipo = 'prazo_vencido' and status = 'aberto'));
select t.ok('alertas','parada há 10 dias em "Aguardando lentes" (limite 7)', exists (select 1 from lab.alertas where id_origem = 'os_r1' and tipo = 'parado_na_etapa' and status = 'aberto'));
select t.ok('alertas','sem número de pedido no laboratório', exists (select 1 from lab.alertas where id_origem = 'os_r1' and tipo = 'sem_pedido_lab' and status = 'aberto'));
select t.ok('alertas','avisado há 20 dias e não retirado (limite 15)', exists (select 1 from lab.alertas where id_origem = 'os_r2' and tipo = 'aguardando_retirada' and status = 'aberto'));
select t.ok('alertas','OS entregue com prazo antigo não gera alerta', not exists (select 1 from lab.alertas where id_origem = 'os_r3'));
select t.ok('alertas','unidade desconhecida vira alerta e a OS não entra', exists (select 1 from lab.alertas where id_origem = 'os_r4' and tipo = 'unidade_desconhecida')
  and not exists (select 1 from lab.os where id_origem = 'os_r4'));
select t.ok('alertas','coluna sem nome confirmado vira alerta', exists (select 1 from lab.alertas where id_origem = 'os_r5' and tipo = 'etapa_desconhecida'));
select t.ok('alertas','pedido refeito sinalizado', exists (select 1 from lab.alertas where id_origem = 'os_r7' and tipo = 'refeito'));
select t.ok('alertas','refeito recente sem prazo vencido não gera alerta de atraso',
  not exists (select 1 from lab.alertas where id_origem = 'os_r7' and tipo in ('prazo_vencido','parado_na_etapa')));
select t.ok('privacidade','nome e telefone do cliente não foram gravados',
  not exists (select 1 from lab.os where row_to_json(os.*)::text ~ '(Fulano|5513999990001)'));

-- ---------------------------------------------------------------------------
-- C. Idempotência e resolução automática
-- ---------------------------------------------------------------------------
select set_config('t.s2', t.sincronizar(t.lote_base())::text, false);
select t.ok('sync','mesmo lote de novo: nada novo, nada alterado',
  (current_setting('t.s2')::jsonb->>'novas')::int = 0 and (current_setting('t.s2')::jsonb->>'atualizadas')::int = 0, current_setting('t.s2'));
select t.ok('sync','alertas não duplicam', (select count(*) from lab.alertas where status = 'aberto' and id_origem = 'os_r1') = 3);
select t.ok('sync','contagem da etapa preservada quando a origem não informa a data e a etapa não muda',
  (select entrou_etapa_em < now() - interval '9 days' from lab.os where id_origem = 'os_r1'));

select set_config('t.s3', t.sincronizar(
  jsonb_build_array(jsonb_build_object('id','os_r1','unidade','campinas','os','1001','ped','P-55','tipo','venda','lab','Lab Próprio','col',5,
    'prazo', (lab._hoje() - 5)::text)))::text, false);
select t.ok('resolucao','OS entregue: alertas resolvidos sozinhos',
  not exists (select 1 from lab.alertas where id_origem = 'os_r1' and status = 'aberto')
  and (select count(*) from lab.alertas where id_origem = 'os_r1' and status = 'resolvido') = 3);
select t.ok('resolucao','resolução registra quem resolveu',
  (select bool_and(resolvido_por like 'agente_laboratorio%') from lab.alertas where id_origem = 'os_r1' and status = 'resolvido'));
select t.ok('resolucao','histórico de alertas fica (não apaga)', (select count(*) from lab.alertas where id_origem = 'os_r1') = 3);

-- ---------------------------------------------------------------------------
-- D. Validador, atomicidade e segurança
-- ---------------------------------------------------------------------------
select set_config('t.s4', t.sincronizar(
  jsonb_build_array(jsonb_build_object('id','os_r9','unidade','campinas','os','5513999990001','ped','X','tipo','venda','col',0)))::text, false);
select t.ok('validador','dado pessoal no número da OS: validador reprova e bloqueia',
  current_setting('t.s4')::jsonb->>'validacao' = 'bloqueada', current_setting('t.s4'));

do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'laboratorio'), 'laboratorio', 'lab_sincronizacao',
    'lab.os', 'sincronizar', null, '{"origem":"adm_os_cards"}', 'lab:teste:atomico', null, 6);
  perform core.reivindicar('laboratorio', 'lab-sync', 120);
  perform set_config('t.atomico', v_t::text, false);
end $$;
select t.erro('atomico','lote inválido é recusado inteiro',
  format('select lab.concluir_sincronizacao(%L, %L, %L::jsonb)', current_setting('t.atomico'), 'lab-sync', '{"nao":"lista"}'), 'lote inválido');
select t.ok('atomico','tarefa continua em execução (nada registrado pela metade)',
  (select status from core.tarefas where id = current_setting('t.atomico')::uuid) = 'executando'
  and not exists (select 1 from lab.sincronizacoes where tarefa_id = current_setting('t.atomico')::uuid));
select lab.concluir_sincronizacao(current_setting('t.atomico')::uuid, 'lab-sync', '[]'::jsonb);
select t.erro('validador','executor não valida a própria execução',
  format('select lab.validar_sincronizacao(%L, %L)', current_setting('t.atomico'), 'lab-sync'), 'executor');
select t.ok('validador','lote vazio é válido', lab.validar_sincronizacao(current_setting('t.atomico')::uuid, 'validador_sql') = 'concluida');

set role anon;
select t.erro('seguranca','anon não chama o painel do laboratório', 'select public.painel_lab()', 'permission');
reset role;
set role authenticated;
select t.erro('seguranca','usuário logado não lê o espelho direto', 'select count(*) from lab.os', 'permission');
select t.erro('seguranca','usuário logado não chama as funções do agente', $q$select lab.agendar_sincronizacao()$q$, 'permission');

-- painel: admin global vê tudo; gerente de outra unidade não vê nada do laboratório
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('painel','admin vê alertas abertos das lojas', jsonb_array_length(public.painel_lab()->'alertas') >= 3);
select t.ok('painel','etapas com nome e situação', jsonb_array_length(public.painel_lab()->'etapas') = 9);
select t.ok('painel','filtro por unidade', (select bool_and(x->>'unidade_id' = 'sao_vicente') from jsonb_array_elements(public.painel_lab('sao_vicente')->'alertas') x));
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.ok('painel','gerente de outra unidade não vê alertas do laboratório', jsonb_array_length(public.painel_lab()->'alertas') = 0);
select t.erro('painel','gerente não filtra unidade fora do escopo', $q$select public.painel_lab('campinas')$q$, 'sem permissão');
reset role;
select t.sem_jwt();

select t.ok('auditoria','cadeia íntegra', core.verificar_auditoria() is null);
-- devolve as travas como nasceram
update core.agentes set status = 'pausado' where id = 'laboratorio';
update core.config set valor = 'false' where chave = 'lab.sync.ativo';

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DO LABORATÓRIO FALHANDO'; end if; end $$;
