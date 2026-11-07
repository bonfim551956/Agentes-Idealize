-- Origem das vendas: Loja × Visão Ideal, por loja (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into core.unidades (id, nome) values ('sorocaba','Sorocaba'), ('campinas','Campinas') on conflict (id) do nothing;
insert into com.funis (id, nome) values (8101, 'LOJA SOROCABA'), (8102, 'CAMPANHA SOROCABA'), (8103, 'CAMPANHA CAMPINAS'), (8104, 'FUNIL NOVO')
on conflict (id) do nothing;
-- a migração classifica pelo nome; aqui repete para os funis do teste (criados depois dela)
insert into atr.funis_tipo (funil_id, tipo, unidade_id) values (8101, 'loja', 'sorocaba'), (8102, 'visao_ideal', 'sorocaba'), (8103, 'visao_ideal', 'campinas')
on conflict (funil_id) do nothing;

create or replace function t.hh(s text) returns text language sql as $$ select encode(sha256(convert_to(s, 'UTF8')), 'hex') $$;
create or replace function t.ts(n int) returns timestamptz language sql as $$ select (atr._hoje() - n)::timestamptz + interval '15 hours' $$;
delete from atr.conversoes; delete from atr.vendas; delete from atr.leads;
insert into atr.leads (id, funil_id, criado_em, tel_hash) values
  (81, 8101, t.ts(20), t.hh('o1')),   -- loja Sorocaba
  (82, 8101, t.ts(40), t.hh('o2')),   -- veio primeiro pela loja...
  (83, 8102, t.ts(10), t.hh('o2')),   -- ...e depois pela Visão Ideal: vale o mais recente
  (84, 8103, t.ts(5),  t.hh('o3')),   -- Visão Ideal de Campinas, comprou em Sorocaba
  (85, 8101, t.ts(200), t.hh('o4')),  -- lead antigo demais (fora da janela)
  (86, 8104, t.ts(3),  t.hh('o6'));   -- funil sem classificação
insert into atr.vendas (id, unidade_id, dia, tipo, valor, tel_hash) values
  ('OS1', 'sorocaba', atr._hoje() - 2, 'venda', 500, t.hh('o1')),
  ('OS2', 'sorocaba', atr._hoje() - 2, 'venda', 800, t.hh('o2')),
  ('OS3', 'sorocaba', atr._hoje() - 1, 'venda', 900, t.hh('o3')),
  ('OS4', 'sorocaba', atr._hoje() - 1, 'venda', 300, t.hh('o4')),
  ('OS5old', 'sorocaba', atr._hoje() - 100, 'venda', 200, t.hh('o5')),
  ('OS5', 'sorocaba', atr._hoje() - 1, 'venda', 250, t.hh('o5')),
  ('OS6', 'sorocaba', atr._hoje() - 1, 'venda', 150, t.hh('o6')),
  ('OS7', 'sorocaba', atr._hoje() - 1, 'garantia', 0, t.hh('o1'));

select t.ok('origem','venda da loja, Visão Ideal (lead mais recente vale), recorrente, sem origem e funil sem classificação',
  (select jsonb_object_agg(os, origem) from atr.v_origem_vendas where os in ('OS1','OS2','OS3','OS4','OS5','OS6'))
  = '{"OS1":"loja","OS2":"visao_ideal","OS3":"visao_ideal","OS4":"sem_origem","OS5":"recorrente","OS6":"sem_classificacao"}'::jsonb,
  (select jsonb_object_agg(os, origem)::text from atr.v_origem_vendas));
select t.ok('origem','loja de onde o lead veio pode ser diferente da loja da venda',
  (select unidade_lead from atr.v_origem_vendas where os = 'OS3') = 'campinas' and (select unidade_id from atr.v_origem_vendas where os = 'OS3') = 'sorocaba');
select t.ok('origem','venda sem valor (garantia) fica fora', not exists (select 1 from atr.v_origem_vendas where os = 'OS7'));
select t.ok('privacidade','a visão não tem telefone nem código do telefone', not exists (select 1 from information_schema.columns
  where table_schema = 'atr' and table_name = 'v_origem_vendas' and column_name ~ '(tel|phone|cpf|nome)'));

set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.o', public.painel_origem_vendas('sorocaba', 30)::text, false);
select t.ok('painel','resumo por loja e origem, e as vendas que vieram de outra loja',
  (select (x->>'vendas')::int from jsonb_array_elements(current_setting('t.o')::jsonb->'resumo') x where x->>'origem' = 'visao_ideal') = 2
  and (select (x->>'vendas')::int from jsonb_array_elements(current_setting('t.o')::jsonb->'cruzadas') x where x->>'unidade_lead' = 'campinas') = 1
  and jsonb_array_length(current_setting('t.o')::jsonb->'vendas') = 6, current_setting('t.o'));
select t.ok('painel','filtro por origem', jsonb_array_length(public.painel_origem_vendas('sorocaba', 30, 'loja')->'vendas') = 1);
select t.erro('painel','Visão Ideal sem loja é recusado', 'select public.painel_origem_funil_salvar(8104, ''visao_ideal'', null)', 'informe a loja');
select public.painel_origem_funil_salvar(8104, 'loja', 'sorocaba');
select t.ok('painel','funil classificado pela tela muda a origem da venda',
  (select x->>'origem' from jsonb_array_elements(public.painel_origem_vendas('sorocaba', 30)->'vendas') x where x->>'os' = 'OS6') = 'loja');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('painel','gerente não classifica funil', 'select public.painel_origem_funil_salvar(8104, ''loja'', ''sorocaba'')', 'sem permissão');
reset role;
select t.sem_jwt();
select t.ok('painel','classificação auditada', exists (select 1 from core.auditoria where acao = 'origem_funil_classificado'));

select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),120) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DA ORIGEM DAS VENDAS FALHANDO'; end if; end $$;
