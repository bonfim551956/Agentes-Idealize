-- Central de pendências (dados sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.c', public.painel_central()::text, false);
select t.ok('central','junta avisos de várias áreas, cada um com a tela onde se resolve',
  (current_setting('t.c')::jsonb->>'total')::int > 0
  and (select count(distinct x->>'area') from jsonb_array_elements(current_setting('t.c')::jsonb->'itens') x) >= 2
  and not exists (select 1 from jsonb_array_elements(current_setting('t.c')::jsonb->'itens') x where coalesce(x->>'link', '') !~ '^/'),
  left(current_setting('t.c'), 300));
select t.ok('central','urgentes primeiro', (current_setting('t.c')::jsonb->'itens'->0->>'gravidade')::int = 1);
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.ok('central','gerente vê só a própria loja e não vê incidentes da plataforma',
  (select count(distinct x->>'unidade_id') from jsonb_array_elements(public.painel_central()->'itens') x where x->>'unidade_id' is not null) <= 1
  and not exists (select 1 from jsonb_array_elements(public.painel_central()->'itens') x where x->>'area' = 'Plataforma'),
  (select string_agg(distinct coalesce(x->>'unidade_id','-') || ':' || (x->>'area'), ',') from jsonb_array_elements(public.painel_central()->'itens') x));
reset role;
select t.sem_jwt();
select t.ok('envio','lançar extrato refaz a conferência do caixa', pg_get_functiondef('public.painel_envio_confirmar(uuid,text,jsonb)'::regprocedure) ~ 'cx\.recalcular');
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),200) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DA CENTRAL FALHANDO'; end if; end $$;
