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
-- OFX ocupa o lugar do PDF
insert into fin.contas (id, apelido, tipo, unidade_id) values ('teste_ofx_banco', 'Banco OFX (teste)', 'corrente', 'campinas') on conflict (id) do nothing;
select fin.importar_extrato('teste_ofx_banco', repeat('a', 64), 'ia', '[{"data":"2026-10-30","valor":250,"descricao":"RECEBIMENTO PIX FULANO"},{"data":"2026-10-30","valor":-50,"descricao":"TARIFA"}]', 'teste');
select set_config('t.o', fin.importar_extrato('teste_ofx_banco', repeat('b', 64), 'ofx', '[{"data":"2026-10-30","valor":250,"descricao":"PIX RECEBIDO FULANO DE TAL","documento":"FIT1"},{"data":"2026-10-30","valor":-50,"descricao":"TARIFA PACOTE","documento":"FIT2"},{"data":"2026-10-31","valor":80,"descricao":"PIX SABADO","documento":"FIT3"}]', 'teste')::text, false);
select t.ok('ofx','OFX ocupa o lugar das linhas do PDF: nada em dobro e a linha antiga guardada',
  (select count(*) from fin.movimentos where conta_id = 'teste_ofx_banco') = 3
  and (select count(*) from fin.movimentos_substituidos where conta_id = 'teste_ofx_banco') = 2
  and (current_setting('t.o')::jsonb->>'substituidas_do_pdf')::int = 2 and (current_setting('t.o')::jsonb->>'novas')::int = 1, current_setting('t.o'));
select fin.importar_extrato('teste_ofx_banco', repeat('c', 64), 'ia', '[{"data":"2026-10-31","valor":80,"descricao":"PIX SAB"}]', 'teste');
select t.ok('ofx','PDF depois do OFX não cria linha que o OFX já trouxe', (select count(*) from fin.movimentos where conta_id = 'teste_ofx_banco') = 3);

select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),200) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DA CENTRAL FALHANDO'; end if; end $$;
