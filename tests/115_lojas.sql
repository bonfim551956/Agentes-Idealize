-- Lojas: ativar, desativar e cadastrar loja nova pelo painel (dados sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;

set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.l', public.painel_lojas()::text, false);
select public.painel_loja_salvar('santos_teste', 'Santos (teste)', true, 'santosteste', 'SANTOSTESTE', 'loja nova para teste');
select t.erro('lojas','código do ADM de outra loja é recusado', $q$select public.painel_loja_salvar('outra_teste', 'Outra', true, 'santosteste', null, 'teste de código repetido')$q$, 'já é de outra loja');
select t.erro('lojas','código inválido é recusado', $q$select public.painel_loja_salvar('Loja X!', 'Loja X', true, null, null, 'teste de código')$q$, 'inválido');
select t.erro('lojas','motivo é obrigatório', $q$select public.painel_loja_salvar('santos_teste', 'Santos (teste)', false, null, null, '')$q$, 'motivo');
select public.painel_loja_salvar('campinas', 'Campinas', false, null, null, 'desativada por enquanto');
select set_config('t.eu', public.painel_eu()::text, false);
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('lojas','gerente não mexe nas lojas', $q$select public.painel_loja_salvar('campinas', 'Campinas', true, null, null, 'tentativa de gerente')$q$, 'permiss');
reset role; select t.sem_jwt();

select t.ok('lojas','a tela lista as lojas com códigos e ligações', jsonb_array_length(current_setting('t.l')::jsonb) >= 4
  and (select x->>'codigo_adm' from jsonb_array_elements(current_setting('t.l')::jsonb) x where x->>'id' = 'sorocaba') = 'sorocaba');
select t.ok('lojas','loja nova entra em todos os mapas do ADM, Lab, cobranças, atribuição e RH',
  exists (select 1 from core.unidades where id = 'santos_teste' and ativo)
  and exists (select 1 from cx.unidades_origem where origem = 'santosteste' and unidade_id = 'santos_teste')
  and exists (select 1 from cob.unidades_origem where origem = 'santosteste') and exists (select 1 from lab.unidades_origem where origem = 'santosteste')
  and exists (select 1 from atr.unidades_origem where origem = 'santosteste') and exists (select 1 from rh.lojas_origem where origem = 'SANTOSTESTE'));
select t.ok('lojas','loja desativada some do seletor do painel',
  not exists (select 1 from jsonb_array_elements(current_setting('t.eu')::jsonb->'unidades') x where x->>'id' = 'campinas')
  and exists (select 1 from jsonb_array_elements(current_setting('t.eu')::jsonb->'unidades') x where x->>'id' = 'sorocaba'));
select t.ok('lojas','desativar fica no histórico auditado', exists (select 1 from core.auditoria where acao = 'loja_desativada' and entidade_id = 'campinas'));
select t.ok('lojas','fechamento do caixa ignora loja desativada', (select core.loja_ativa('campinas')) = false and core.loja_ativa(null));

-- volta como estava
update core.unidades set ativo = true where id = 'campinas';
delete from cx.unidades_origem where unidade_id = 'santos_teste'; delete from cob.unidades_origem where unidade_id = 'santos_teste';
delete from lab.unidades_origem where unidade_id = 'santos_teste'; delete from atr.unidades_origem where unidade_id = 'santos_teste';
delete from rh.lojas_origem where unidade_id = 'santos_teste'; delete from cx.fechamentos where unidade_id = 'santos_teste';
delete from core.unidades where id = 'santos_teste';

select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),200) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DAS LOJAS FALHANDO'; end if; end $$;
