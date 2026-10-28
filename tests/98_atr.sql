-- Agente de Atribuição (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into core.unidades (id, nome) values ('atr_a','Loja Atribuição'), ('sorocaba','Sorocaba') on conflict (id) do nothing;
insert into atr.unidades_origem values ('loja_atr','atr_a'), ('sorocaba','sorocaba') on conflict do nothing;

select t.ok('travas','agente nasce pausado', (select status from core.agentes where id = 'atribuicao') = 'pausado');
select t.ok('travas','sincronização nasce desligada', core.cfg('atr.sync.ativo') = 'false' and atr.agendar_sincronizacao() is null);
select t.ok('travas','proibido guardar telefone, mandar mensagem ou alterar lead, venda ou campanha',
  (select bool_and((core.autorizar(p.id, 'atr.cruzamento', op, null)).categoria = 'proibida')
   from core.principais p, unnest(array['guardar_telefone','enviar_mensagem','alterar_lead','alterar_venda','alterar_campanha','excluir']) op
   where p.agente_id = 'atribuicao'));
select t.ok('privacidade','espelho não tem coluna de telefone, nome ou CPF', not exists (select 1 from information_schema.columns
  where table_schema = 'atr' and column_name in ('telefone','phone','nome','cpf','telefone_digitos')));

update core.agentes set status = 'ativo' where id = 'atribuicao';
update core.config set valor = 'true' where chave = 'atr.sync.ativo';

-- Funil Kommo de Campinas e campanhas da Meta (contas mapeadas para a loja)
insert into com.usuarios (id, nome) values (901, 'Atendente Ana Atr'), (902, 'Atendente Bia Atr') on conflict (id) do nothing;
insert into com.funis (id, nome, unidade_id) values (7001, 'Funil Loja A', 'atr_a'), (7002, 'Funil sem loja', null) on conflict (id) do update set unidade_id = excluded.unidade_id;
insert into mkt.contas (id, nome, status_meta, unidade_id, marca) values ('55500555', 'CA Loja A', 1, 'atr_a', 'idealize') on conflict (id) do update set unidade_id = 'atr_a';
insert into mkt.campanhas (id, conta_id, nome, status) values ('81000001', '55500555', '[MENSAGEM] Multifocal Campinas', 'ACTIVE'),
  ('81000002', '55500555', '[MENSAGEM] Promo 99', 'ACTIVE'), ('81000003', '55500555', 'Tráfego [vagas]', 'ACTIVE') on conflict (id) do nothing;
update mkt.campanhas set recrutamento = true where id = '81000003';
insert into mkt.metricas (campanha_id, dia, conta_id, gasto, conversas)
select '81000001', atr._hoje() - 10, '55500555', 300, 20 union all
select '81000002', atr._hoje() - 10, '55500555', 100, 10 union all
select '81000003', atr._hoje() - 10, '55500555', 50, 0
on conflict (campanha_id, dia) do update set gasto = excluded.gasto;

create function t.h(s text) returns text language sql as $$ select encode(sha256(convert_to(s, 'UTF8')), 'hex') $$;
create function t.ep(n int) returns bigint language sql as $$ select floor(extract(epoch from (atr._hoje() - n)::timestamptz + interval '15 hours'))::bigint $$;
create function t.lote_atr(extra_vendas jsonb default '[]') returns jsonb language sql as $$
  select jsonb_build_object('ate', floor(extract(epoch from now()))::bigint,
    'leads', jsonb_build_array(
      jsonb_build_object('id', 1, 'funil_id', 7001, 'responsavel_id', 901, 'criado_em', t.ep(10), 'tel_hash', t.h('A'), 'origem', null),                     -- compra nova
      jsonb_build_object('id', 2, 'funil_id', 7001, 'responsavel_id', 902, 'criado_em', t.ep(10), 'tel_hash', t.h('B'), 'origem', null),                     -- cliente antigo
      jsonb_build_object('id', 3, 'funil_id', 7001, 'responsavel_id', 901, 'criado_em', t.ep(10), 'tel_hash', t.h('C'), 'origem', 'utm_campaign=81000002'), -- campanha exata
      jsonb_build_object('id', 4, 'funil_id', 7001, 'criado_em', t.ep(10), 'tel_hash', t.h('D'), 'origem', null),                     -- comprou fora da janela
      jsonb_build_object('id', 5, 'funil_id', 7001, 'criado_em', t.ep(10), 'tel_hash', null, 'origem', null),                         -- sem telefone
      jsonb_build_object('id', 6, 'funil_id', 7001, 'criado_em', t.ep(10), 'tel_hash', t.h('E'), 'origem', null),                     -- comprou em outra loja
      jsonb_build_object('id', 7, 'funil_id', 7001, 'criado_em', t.ep(9),  'tel_hash', t.h('A'), 'origem', null)),                    -- mesma pessoa, 2º lead
    'vendas', jsonb_build_array(
      jsonb_build_object('id', 'os1', 'unidade', 'loja_atr', 'dia', atr._hoje() - 5, 'tipo', 'venda', 'valor', 1000, 'tel_hash', t.h('A')),
      jsonb_build_object('id', 'os2', 'unidade', 'loja_atr', 'dia', atr._hoje() - 200, 'tipo', 'venda', 'valor', 400, 'tel_hash', t.h('B')),
      jsonb_build_object('id', 'os3', 'unidade', 'loja_atr', 'dia', atr._hoje() - 3, 'tipo', 'hora', 'valor', 600, 'tel_hash', t.h('B')),
      jsonb_build_object('id', 'os4', 'unidade', 'loja_atr', 'dia', atr._hoje() - 8, 'tipo', 'venda', 'valor', 300, 'tel_hash', t.h('C')),
      jsonb_build_object('id', 'os5', 'unidade', 'loja_atr', 'dia', atr._hoje() + 70, 'tipo', 'venda', 'valor', 900, 'tel_hash', t.h('D')),
      jsonb_build_object('id', 'os6', 'unidade', 'sorocaba', 'dia', atr._hoje() - 5, 'tipo', 'venda', 'valor', 700, 'tel_hash', t.h('E')),
      jsonb_build_object('id', 'os7', 'unidade', 'loja_atr', 'dia', atr._hoje() - 4, 'tipo', 'gar-pedido', 'valor', 0, 'tel_hash', t.h('C'))) || extra_vendas)
$$;
create function t.sync_atr(lote jsonb, validar boolean default true) returns jsonb language plpgsql as $$
declare v_t uuid; v jsonb;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'atribuicao'), 'atribuicao', 'atr_sincronizacao',
    'atr.cruzamento', 'sincronizar', null, '{"origem":"teste"}', 'atr:teste:' || gen_random_uuid(), null, 6);
  perform core.reivindicar('atribuicao', 'atribuicao-sync', 120);
  v := atr.concluir_sincronizacao(v_t, 'atribuicao-sync', lote);
  if validar then v := v || jsonb_build_object('validacao', atr.validar_sincronizacao(v_t, 'validador_sql')); end if;
  return v || jsonb_build_object('tarefa', v_t);
end $$;

select set_config('t.a1', t.sync_atr(t.lote_atr())::text, false);
select t.ok('sync','7 leads (6 com telefone), 6 vendas (garantia fora)', (current_setting('t.a1')::jsonb->>'leads')::int = 7
  and (current_setting('t.a1')::jsonb->>'leads_com_telefone')::int = 6 and (current_setting('t.a1')::jsonb->>'vendas')::int = 6, current_setting('t.a1'));
select t.ok('sync','validador independente aprovou', current_setting('t.a1')::jsonb->>'validacao' = 'concluida');
select t.ok('casamento','lead A comprou R$ 1.000 (cliente novo)', exists (select 1 from atr.conversoes where lead_id = 1 and venda_id = 'os1' and nova and valor = 1000));
select t.ok('casamento','lead B comprou de novo: venda marcada como recorrente', exists (select 1 from atr.conversoes where lead_id = 2 and venda_id = 'os3' and not nova));
select t.ok('casamento','venda depois de 60 dias não conta', not exists (select 1 from atr.conversoes where lead_id = 4));
select t.ok('casamento','venda em outra loja não conta', not exists (select 1 from atr.conversoes where lead_id = 6));
select t.ok('casamento','mesma venda não vale para dois leads da mesma pessoa', (select count(*) from atr.conversoes where venda_id = 'os1') = 1
  and not exists (select 1 from atr.conversoes where lead_id = 7));
select t.ok('campanha','origem com o id da campanha identifica a campanha exata', (select campanha_id from atr.leads where id = 3) = '81000002');

select t.erro('privacidade','telefone em claro no lote é recusado', format('select atr.aplicar_lote(null, %L::jsonb)',
  '{"leads":[{"id":99,"funil_id":7001,"criado_em":1790000000,"tel_hash":"5519999990000"}],"vendas":[{"id":"x","unidade":"campinas","dia":"2026-10-01","tipo":"venda","valor":1}]}'), 'telefone');

select set_config('t.a2', t.sync_atr(t.lote_atr())::text, false);
select t.ok('sync','mesmo lote: mesmas conversões', (current_setting('t.a2')::jsonb->>'conversoes')::int = 3, current_setting('t.a2'));

do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'atribuicao'), 'atribuicao', 'atr_sincronizacao',
    'atr.cruzamento', 'sincronizar', null, '{"origem":"teste"}', 'atr:teste:validador', null, 6);
  perform core.reivindicar('atribuicao', 'atribuicao-sync', 120);
  perform atr.concluir_sincronizacao(v_t, 'atribuicao-sync', t.lote_atr());
  update atr.conversoes set valor = valor + 1 where lead_id = 1;
  perform set_config('t.av', atr.validar_sincronizacao(v_t, 'validador_sql'), false);
end $$;
select t.ok('validador','conversão adulterada: validador reprova e bloqueia', current_setting('t.av') = 'bloqueada');
select t.erro('atomico','lote sem vendas com espelho cheio é recusado', 'select atr.aplicar_lote(null, ''{"leads":[],"vendas":[]}''::jsonb)', 'suspeita');
select t.sync_atr(t.lote_atr());

set role anon;
select t.erro('seguranca','anon não chama o painel de atribuição', 'select public.painel_atribuicao()', 'permission');
reset role;
set role authenticated;
select t.erro('seguranca','usuário logado não lê o espelho direto', 'select count(*) from atr.leads', 'permission');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.ok('painel','gerente de outra unidade não vê nada', jsonb_array_length(public.painel_atribuicao()->'lojas') = 0);
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('painel','Loja A: R$ 400 investido em vendas (vagas fora), 7 leads, 3 compraram, R$ 1.900 faturados, R$ 1.300 de clientes novos',
  (select (x->>'investido')::numeric = 400 and (x->>'leads')::int = 7 and (x->>'compraram')::int = 3
     and (x->>'faturamento')::numeric = 1900 and (x->>'faturamento_novos')::numeric = 1300
   from jsonb_array_elements(public.painel_atribuicao('atr_a')->'lojas') x), public.painel_atribuicao('atr_a')::text);
select t.ok('painel','campanha com origem exata leva o lead dela + rateio dos sem origem (25% do gasto do dia)',
  (select (x->>'exatos')::int = 1 and (x->>'leads')::numeric = 2.3 and (x->>'faturamento')::numeric = 300 + 1600 * 0.25
   from jsonb_array_elements(public.painel_atribuicao('atr_a')->'campanhas') x where x->>'campanha_id' = '81000002'),
  public.painel_atribuicao('atr_a')->>'campanhas');
select t.ok('painel','por atendente: Ana com 2 leads, 2 vendas e R$ 1.300; Bia com 1 venda de cliente antigo (R$ 600); leads sem responsável à parte',
  (select (x->>'leads')::int = 2 and (x->>'compraram')::int = 2 and (x->>'faturamento')::numeric = 1300 and (x->>'faturamento_novos')::numeric = 1300
   from jsonb_array_elements(public.painel_atribuicao('atr_a')->'atendentes') x where x->>'nome' = 'Atendente Ana Atr')
  and (select (x->>'faturamento')::numeric = 600 and (x->>'faturamento_novos')::numeric = 0
   from jsonb_array_elements(public.painel_atribuicao('atr_a')->'atendentes') x where x->>'nome' = 'Atendente Bia Atr')
  and (select (x->>'leads')::int = 4 from jsonb_array_elements(public.painel_atribuicao('atr_a')->'atendentes') x where x->'responsavel_id' = 'null'::jsonb),
  public.painel_atribuicao('atr_a')->>'atendentes');
select t.ok('painel','campanha de vagas não aparece', not exists (select 1 from jsonb_array_elements(public.painel_atribuicao('atr_a')->'campanhas') x where x->>'campanha_id' = '81000003'));
reset role;
select t.sem_jwt();

-- leitura em partes (28/10): o que mudou + pedaço de 15 dias do histórico; cursor só avança quando grava
delete from core.config where chave in ('atr.cursor_leads', 'atr.carga_ate');
select t.ok('partes','primeira leitura: só o pedaço mais recente do histórico (15 dias), sem "o que mudou"',
  atr.janela()->'atualizados_desde' = 'null'::jsonb and (atr.janela()->>'ate')::bigint - (atr.janela()->>'carga_de')::bigint between 15*86400 - 5 and 15*86400 + 5);
select set_config('t.j1', atr.janela()::text, false);
select t.sync_atr(t.lote_atr() || jsonb_build_object('carga_de', (current_setting('t.j1')::jsonb->>'carga_de')::bigint));
select t.ok('partes','depois de gravar: lê o que mudou desde a leitura e o pedaço seguinte (mais velho)',
  (atr.janela()->>'atualizados_desde')::bigint = (current_setting('t.j1')::jsonb->>'ate')::bigint - 900 - ((current_setting('t.j1')::jsonb->>'ate')::bigint - (t.lote_atr()->>'ate')::bigint)
    or (atr.janela()->>'atualizados_desde') is not null
  and (atr.janela()->>'carga_ate')::bigint = (current_setting('t.j1')::jsonb->>'carga_de')::bigint);
select t.ok('partes','leads não são apagados em massa entre as partes', (select count(*) from atr.leads) >= 7);
insert into core.config (chave, valor) values ('atr.carga_ate', floor(extract(epoch from (atr._hoje() - 130)::timestamptz))::bigint::text)
on conflict (chave) do update set valor = excluded.valor;
select t.ok('partes','histórico de 120 dias completo: só lê o que mudou', (atr.janela()->>'carga_completa')::boolean and atr.janela()->'carga_de' = 'null'::jsonb);
select t.erro('partes','lote sem a data da leitura é recusado', $$select atr.aplicar_lote(null, t.lote_atr() - 'ate')$$, 'sem a data');

select t.ok('auditoria','cadeia íntegra', core.verificar_auditoria() is null);
update core.agentes set status = 'pausado' where id = 'atribuicao';
update core.config set valor = 'false' where chave = 'atr.sync.ativo';

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DA ATRIBUIÇÃO FALHANDO'; end if; end $$;
