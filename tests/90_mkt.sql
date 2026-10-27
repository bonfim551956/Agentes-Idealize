-- Agente de Marketing / Meta Ads (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into core.unidades (id, nome) values ('campinas','Campinas'), ('sorocaba','Sorocaba') on conflict (id) do nothing;

-- A. Travas
select t.ok('travas','agente nasce pausado', (select status from core.agentes where id = 'marketing') = 'pausado');
select t.ok('travas','sincronização nasce desligada', core.cfg('mkt.sync.ativo') = 'false' and mkt.agendar_sincronizacao() is null);
select t.ok('travas','proibido criar, alterar, pausar, ativar, mexer em orçamento ou excluir na Meta',
  (select bool_and((core.autorizar(p.id, 'mkt.meta', op, null)).categoria = 'proibida')
   from core.principais p, unnest(array['criar_campanha','alterar_campanha','alterar_orcamento','pausar','ativar','criar_anuncio','excluir']) op
   where p.agente_id = 'marketing'));
select t.ok('sugestao','sugere loja e marca pelo nome da conta',
  mkt.sugestao('CA VISÃO IDEAL SOROCABA') = '{"marca":"visao_ideal","unidade_id":"sorocaba"}'::jsonb
  and mkt.sugestao('CA Campinas Idealize') = '{"marca":"idealize","unidade_id":"campinas"}'::jsonb
  and mkt.sugestao('786176966179773')->>'unidade_id' is null);

update core.agentes set status = 'ativo' where id = 'marketing';
update core.config set valor = 'true' where chave = 'mkt.sync.ativo';

create function t.dia(n int) returns text language sql as $$ select (mkt._hoje() - n)::text $$;
create function t.met(camp text, conta text, n int, gasto numeric, conv int, leads int default 0) returns jsonb language sql as $$
  select jsonb_build_object('campanha_id', camp, 'conta_id', conta, 'dia', t.dia(n), 'gasto', gasto, 'impressoes', 1000,
    'alcance', 800, 'cliques', 30, 'conversas', conv, 'leads', leads, 'visitas', 0)
$$;
-- Conta 111 (Campinas): campanha 901 boa e estável; 902 gastando sem resultado; 903 custo disparou; 904 vagas
-- Conta 222 (Sorocaba): bloqueada, com anúncio reprovado
create function t.lote_mkt(extra jsonb default '[]', status_222 int default 3) returns jsonb language sql as $$
  select jsonb_build_object('desde', t.dia(29), 'ate', t.dia(0),
    'contas', jsonb_build_array(
      jsonb_build_object('id','11100111','nome','CA Campinas Idealize','status_meta',1,'moeda','BRL'),
      jsonb_build_object('id','22200222','nome','CA VISÃO IDEAL SOROCABA','status_meta',status_222,'motivo_bloqueio',0)),
    'campanhas', jsonb_build_array(
      jsonb_build_object('id','90100901','conta_id','11100111','nome','[MENSAGEM] Campinas','objetivo','OUTCOME_ENGAGEMENT','status','ACTIVE','orcamento_diario',100),
      jsonb_build_object('id','90200902','conta_id','11100111','nome','[MENSAGEM] Teste','objetivo','OUTCOME_ENGAGEMENT','status','ACTIVE'),
      jsonb_build_object('id','90300903','conta_id','11100111','nome','[MENSAGEM] Multifocal','objetivo','OUTCOME_ENGAGEMENT','status','ACTIVE'),
      jsonb_build_object('id','90400904','conta_id','11100111','nome','Tráfego [vagas]','objetivo','OUTCOME_TRAFFIC','status','ACTIVE'),
      jsonb_build_object('id','90500905','conta_id','22200222','nome','ESCALA [MENSAGEM]','objetivo','OUTCOME_ENGAGEMENT','status','ACTIVE'),
      jsonb_build_object('id','99900999','conta_id','33300333','nome','conta que não veio','status','ACTIVE')),
    'metricas', (select jsonb_agg(x) from (
        select t.met('90100901','11100111', n, 50, 4) x from generate_series(0, 29) n
        union all select t.met('90200902','11100111', 1, 40, 0) union all select t.met('90200902','11100111', 0, 30, 0)
        union all select t.met('90300903','11100111', n, 50, 5) from generate_series(3, 29) n
        union all select t.met('90300903','11100111', n, 60, 1) from generate_series(0, 2) n
        union all select t.met('90400904','11100111', n, 10, 0) from generate_series(0, 29) n
        union all select t.met('90500905','22200222', n, 20, 2) from generate_series(2, 9) n
        union all select t.met('99900999','33300333', 0, 500, 0)
        union all select t.met('90100901','11100111', 40, 500, 0)) q) || extra,
    'anuncios_problema', jsonb_build_array(
      jsonb_build_object('id','70017001','conta_id','22200222','campanha_id','90500905','nome','Video oferta','status','DISAPPROVED')))
$$;

create function t.sync_mkt(lote jsonb, validar boolean default true) returns jsonb language plpgsql as $$
declare v_t uuid; v jsonb;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'marketing'), 'marketing', 'mkt_sincronizacao',
    'mkt.meta', 'sincronizar', null, '{"origem":"meta_ads"}', 'mkt:teste:' || gen_random_uuid(), null, 6);
  perform core.reivindicar('marketing', 'meta-sync', 120);
  v := mkt.concluir_sincronizacao(v_t, 'meta-sync', lote);
  if validar then v := v || jsonb_build_object('validacao', mkt.validar_sincronizacao(v_t, 'validador_sql')); end if;
  return v || jsonb_build_object('tarefa', v_t);
end $$;

-- B. Primeira leitura
select set_config('t.m1', t.sync_mkt(t.lote_mkt())::text, false);
select t.ok('sync','2 contas, 5 campanhas; campanha e métricas de conta não lida e fora da janela ignoradas',
  (current_setting('t.m1')::jsonb->>'contas')::int = 2 and (current_setting('t.m1')::jsonb->>'campanhas')::int = 5
  and (current_setting('t.m1')::jsonb->>'ignoradas')::int = 2, current_setting('t.m1'));
select t.ok('sync','gasto da janela confere (30×50 + 70 + 27×50 + 3×60 + 30×10 + 8×20)',
  (current_setting('t.m1')::jsonb->>'gasto_janela')::numeric = 1500 + 70 + 1350 + 180 + 300 + 160);
select t.ok('sync','validador independente aprovou', current_setting('t.m1')::jsonb->>'validacao' = 'concluida');
select t.ok('sync','campanha de vagas marcada como recrutamento', (select recrutamento from mkt.campanhas where id = '90400904')
  and not (select recrutamento from mkt.campanhas where id = '90100901'));
select t.ok('alertas','gasto sem resultado: R$ 70 em ontem+hoje sem conversa', exists (select 1 from mkt.alertas
  where tipo = 'gasto_sem_resultado' and referencia = 'campanha:90200902' and status = 'aberto' and (detalhe->>'gasto')::numeric = 70));
select t.ok('alertas','recrutamento não gera alerta de gasto sem resultado', not exists (select 1 from mkt.alertas where referencia = 'campanha:90400904'));
select t.ok('alertas','custo alto: R$ 60 por conversa contra R$ 10 de média',
  exists (select 1 from mkt.alertas where tipo = 'custo_alto' and referencia = 'campanha:90300903' and status = 'aberto'
          and (detalhe->>'custo_recente')::numeric = 60 and (detalhe->>'custo_base')::numeric = 10));
select t.ok('alertas','campanha estável não gera custo alto', not exists (select 1 from mkt.alertas where referencia = 'campanha:90100901'));
select t.ok('alertas','conta com problema (status 3 = pagamento pendente)', exists (select 1 from mkt.alertas where tipo = 'conta_com_problema' and referencia = 'conta:22200222' and status = 'aberto'));
select t.ok('alertas','anúncio reprovado', exists (select 1 from mkt.alertas where tipo = 'anuncio_reprovado' and referencia = 'anuncio:70017001' and status = 'aberto'));
select t.ok('alertas','conta bloqueada não vira também entrega parada', not exists (select 1 from mkt.alertas where tipo = 'entrega_parada' and referencia = 'conta:22200222'));
select t.ok('alertas','conta ativa com gasto ontem não tem entrega parada', not exists (select 1 from mkt.alertas where tipo = 'entrega_parada' and referencia = 'conta:11100111'));
select t.ok('alertas','contas sem loja sinalizadas com sugestão', (select count(*) from mkt.alertas where tipo = 'conta_sem_loja' and status = 'aberto'
  and detalhe->'sugestao'->>'unidade_id' is not null) = 2);

-- C. Idempotência, correção da Meta e resolução automática
select set_config('t.m2', t.sync_mkt(t.lote_mkt())::text, false);
select t.ok('sync','mesmo lote: mesmas linhas e mesmo gasto, sem duplicar alertas',
  (select count(*) from mkt.metricas) = (current_setting('t.m1')::jsonb->>'linhas')::int
  and (select sum(gasto) from mkt.metricas) = 3560 and (select count(*) from mkt.alertas where status = 'aberto' and referencia = 'campanha:90200902') = 1);
select set_config('t.m3', t.sync_mkt(
  jsonb_set(t.lote_mkt(status_222 => 1), '{metricas}',
    (select jsonb_agg(case when x->>'campanha_id' = '90200902' and x->>'dia' = t.dia(0) then x || '{"conversas":2}' else x end)
     from jsonb_array_elements(t.lote_mkt()->'metricas') x)) || '{"anuncios_problema":[]}')::text, false);
select t.ok('resolucao','Meta corrigiu: conversa apareceu, conta regularizada e anúncio aprovado → alertas resolvidos sozinhos',
  not exists (select 1 from mkt.alertas where status = 'aberto' and referencia in ('campanha:90200902','conta:22200222','anuncio:70017001')
              and tipo in ('gasto_sem_resultado','conta_com_problema','anuncio_reprovado'))
  and (select count(*) from mkt.alertas where status = 'resolvido' and resolvido_por like 'agente_marketing%') >= 3, current_setting('t.m3'));
select t.ok('alertas','conta regularizada que gastou na semana e nada ontem: entrega parada', exists (select 1 from mkt.alertas where tipo = 'entrega_parada' and referencia = 'conta:22200222' and status = 'aberto'));
select t.ok('resolucao','validação da leitura seguinte aprovou', current_setting('t.m3')::jsonb->>'validacao' = 'concluida');
select t.ok('janela','próximas leituras relêem só os últimos 3 dias',
  (mkt.proxima_janela()->>'desde')::date = mkt._hoje() - 2 and (mkt.proxima_janela()->>'ate')::date = mkt._hoje());

-- D. Validador e atomicidade
do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'marketing'), 'marketing', 'mkt_sincronizacao',
    'mkt.meta', 'sincronizar', null, '{"origem":"meta_ads"}', 'mkt:teste:validador', null, 6);
  perform core.reivindicar('marketing', 'meta-sync', 120);
  perform mkt.concluir_sincronizacao(v_t, 'meta-sync', t.lote_mkt());
  update mkt.metricas set gasto = gasto + 1 where campanha_id = '90100901' and dia = mkt._hoje();
  perform set_config('t.mv', mkt.validar_sincronizacao(v_t, 'validador_sql'), false);
end $$;
select t.ok('validador','gasto alterado depois da leitura: validador reprova e bloqueia', current_setting('t.mv') = 'bloqueada');

do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'marketing'), 'marketing', 'mkt_sincronizacao',
    'mkt.meta', 'sincronizar', null, '{"origem":"meta_ads"}', 'mkt:teste:atomico', null, 6);
  perform core.reivindicar('marketing', 'meta-sync', 120);
  perform set_config('t.ma', v_t::text, false);
end $$;
select t.erro('atomico','lote sem janela é recusado inteiro',
  format('select mkt.concluir_sincronizacao(%L, %L, %L::jsonb)', current_setting('t.ma'), 'meta-sync', '{"contas":[]}'), 'janela');
select t.erro('atomico','janela maior que 3 meses é recusada',
  format('select mkt.concluir_sincronizacao(%L, %L, %L::jsonb)', current_setting('t.ma'), 'meta-sync', '{"desde":"2026-01-01","ate":"2026-10-01"}'), 'janela');
select t.ok('atomico','nada gravado e tarefa segue em execução',
  (select status from core.tarefas where id = current_setting('t.ma')::uuid) = 'executando'
  and not exists (select 1 from mkt.sincronizacoes where tarefa_id = current_setting('t.ma')::uuid));
select t.erro('validador','executor não valida a si mesmo',
  format('select mkt.validar_sincronizacao(%L, %L)', current_setting('t.ma'), 'meta-sync'), 'validação');
select t.sync_mkt(t.lote_mkt(status_222 => 1));   -- leitura limpa de novo

-- E. Painel, loja das contas e escopo
set role anon;
select t.erro('seguranca','anon não chama o painel de marketing', 'select public.painel_marketing()', 'permission');
reset role;
set role authenticated;
select t.erro('seguranca','usuário logado não lê o espelho direto', 'select count(*) from mkt.metricas', 'permission');
select t.erro('seguranca','usuário logado não chama funções do agente', 'select mkt.agendar_sincronizacao()', 'permission');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('painel','gerente não define a loja de uma conta', $q$select public.painel_marketing_conta_loja('11100111', 'campinas', 'idealize', 'tentativa')$q$, 'sem permissão');
select t.ok('painel','gerente de outra unidade não vê nada do marketing',
  jsonb_array_length(public.painel_marketing()->'lojas') = 0 and jsonb_array_length(public.painel_marketing()->'alertas') = 0
  and public.painel_marketing()->'contas' = 'null'::jsonb);
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('painel','admin vê as contas com sugestão de loja', jsonb_array_length(public.painel_marketing()->'contas') = 2
  and (select bool_and(x->'sugestao'->>'unidade_id' is not null) from jsonb_array_elements(public.painel_marketing()->'contas') x));
select t.erro('painel','marca inválida recusada', $q$select public.painel_marketing_conta_loja('11100111', 'campinas', 'xyz', 'conta de Campinas')$q$, 'marca');
select public.painel_marketing_conta_loja('11100111', 'campinas', 'idealize', 'Conta CA Campinas Idealize é da loja de Campinas');
select t.ok('painel','loja de Campinas: gasto comercial dos 7 dias sem recrutamento (901 + 902 + 903)',
  (select (x->>'gasto')::numeric = 7*50 + 70 + 4*50 + 3*60 and (x->>'gasto_recrutamento')::numeric = 70
   from jsonb_array_elements(public.painel_marketing('campinas')->'lojas') x), public.painel_marketing('campinas')::text);
select t.ok('painel','filtro por loja mostra só campanhas e alertas dela',
  (select bool_and(x->>'unidade_id' = 'campinas') from jsonb_array_elements(public.painel_marketing('campinas')->'campanhas') x)
  and (select bool_and(x->>'unidade_id' = 'campinas') from jsonb_array_elements(public.painel_marketing('campinas')->'alertas') x));
select t.ok('painel','gasto por dia no período', jsonb_array_length(public.painel_marketing(null, 7)->'por_dia') = 7);
reset role;
select t.sem_jwt();
select t.ok('lojas','conta mapeada: alerta de conta sem loja resolvido e decisão auditada',
  not exists (select 1 from mkt.alertas where referencia = 'conta:11100111' and tipo = 'conta_sem_loja' and status = 'aberto')
  and exists (select 1 from core.auditoria where acao = 'conta_loja' and entidade_id = '11100111' and ator_id = '00000000-0000-0000-0000-0000000060a1'));
select t.ok('lojas','alertas da conta herdaram a loja', (select unidade_id from mkt.alertas where referencia = 'campanha:90300903' and status = 'aberto') = 'campinas');

select t.ok('auditoria','cadeia íntegra', core.verificar_auditoria() is null);
update core.agentes set status = 'pausado' where id = 'marketing';
update core.config set valor = 'false' where chave = 'mkt.sync.ativo';

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DO MARKETING FALHANDO'; end if; end $$;
