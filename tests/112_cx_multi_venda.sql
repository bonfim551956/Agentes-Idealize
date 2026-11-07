-- Multicrediário × caixa venda a venda (dados sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into core.unidades (id, nome) values ('sorocaba','Sorocaba') on conflict (id) do nothing;
create or replace function t.b() returns date language sql as $$ select cx._hoje() - ((extract(dow from cx._hoje())::int + 1) % 7) - 19 $$; -- uma segunda
delete from cx.alertas where unidade_id = 'sorocaba'; delete from cx.pagamentos where unidade_id = 'sorocaba';
delete from cx.dias where unidade_id = 'sorocaba'; delete from multi.capturas where loja = 'sorocaba';
insert into cx.dias (unidade_id, dia, caixa, soma_formas) select 'sorocaba', t.b() + g, 0, 0 from generate_series(0, 9) g;
insert into cx.pagamentos (unidade_id, dia, origem, forma, valor) values
  ('sorocaba', t.b() + 2, 'venda', 'crediario', 1000),                         -- venda 5001 (de segunda) lançada na quarta
  ('sorocaba', t.b() + 2, 'venda', 'crediario', 225), ('sorocaba', t.b() + 2, 'venda', 'crediario', 325),  -- venda 5002 em dois
  ('sorocaba', t.b() + 3, 'venda', 'crediario', 1000), ('sorocaba', t.b() + 3, 'venda', 'crediario', 1000),
  ('sorocaba', t.b() + 3, 'venda', 'crediario', 220),                          -- venda 5003 (2.120) lançada como 2.220
  ('sorocaba', t.b() + 1, 'venda', 'crediario', 165.27),                       -- sem venda nem parcela
  ('sorocaba', t.b() + 1, 'venda', 'crediario', 153.39);                       -- parcela recebida na loja
select public.multi_receber('operacao_detalhe', 'Tipo=1&Data=' || to_char(t.b() + g, 'DD/MM/YYYY'), t.b() + g,
  '["CPF","Nº Venda","Valor Venda","Valor Entrada","Valor Total Venda","Consultado Garantido"]',
  case g when 0 then '[["111.111.111-11","5001","1.000,00","0,00","1.300,00","1.300,00"],["222.222.222-22","5004","800,00","0,00","900,00","900,00"]]'::jsonb
         when 2 then '[["333.333.333-33","5002","550,00","0,00","600,00","600,00"]]'::jsonb
         else '[["444.444.444-44","5003","2.120,00","0,00","2.500,00","2.500,00"]]'::jsonb end, 'sorocaba')
  from generate_series(0, 3) g where g <> 1;
select public.multi_receber('recebimentos_detalhe', 'Tipo=2&Data=' || to_char(t.b() + 1, 'DD/MM/YYYY'), t.b() + 1,
  '["Data Recebimento","CPF","Nº Venda","Parcela","Valor Recebido"]',
  jsonb_build_array(jsonb_build_array(to_char(t.b() + 1, 'DD/MM/YYYY'), '555.555.555-55', '4800', '2', '153,39')), 'sorocaba');
select public.multi_receber('operacao', 'periodo=TESTE2', null, '["Dia"]', '[["x"]]', 'sorocaba');

select cx.recalcular();
select t.ok('multi_venda','venda lançada no caixa dois dias depois: informativo com as duas datas, sem aviso urgente',
  exists (select 1 from cx.alertas where unidade_id = 'sorocaba' and tipo = 'multi_outro_dia' and status = 'aberto' and detalhe->>'venda' = '5001'
          and (detalhe->>'caixa_dia')::date = t.b() + 2 and dia = t.b() and detalhe->>'caixa_dia_semana' = 'quarta'),
  (select jsonb_agg(jsonb_build_object('t', tipo, 'd', detalhe))::text from cx.alertas where unidade_id = 'sorocaba' and status = 'aberto'));
select t.ok('multi_venda','venda paga em dois lançamentos no mesmo dia casa sem aviso',
  exists (select 1 from cx.multi_casamentos where unidade_id = 'sorocaba' and venda = '5002' and modo = 'mesmo_dia' and cardinality(pagamentos) = 2)
  and not exists (select 1 from cx.alertas where unidade_id = 'sorocaba' and detalhe->>'venda' = '5002' and status = 'aberto'));
select t.ok('multi_venda','venda de R$ 2.120 lançada como 1.000 + 1.000 + 220: valor diferente',
  exists (select 1 from cx.alertas where unidade_id = 'sorocaba' and tipo = 'multi_valor_diferente' and status = 'aberto' and detalhe->>'venda' = '5003'
          and (detalhe->>'valor_caixa')::numeric = 2220 and (detalhe->>'diferenca')::numeric = 100));
select t.ok('multi_venda','venda sem lançamento no caixa depois do prazo',
  exists (select 1 from cx.alertas where unidade_id = 'sorocaba' and tipo = 'multi_sem_caixa' and status = 'aberto' and detalhe->>'venda' = '5004'));
select t.ok('multi_venda','lançamento "Multicrediário" sem venda nem parcela vira aviso; a parcela recebida na loja não',
  exists (select 1 from cx.alertas where unidade_id = 'sorocaba' and tipo = 'caixa_multi_sem_venda' and status = 'aberto' and (detalhe->>'valor')::numeric = 165.27)
  and not exists (select 1 from cx.alertas where unidade_id = 'sorocaba' and tipo = 'caixa_multi_sem_venda' and status = 'aberto' and (detalhe->>'valor')::numeric = 153.39));
select t.ok('multi_venda','o aviso antigo pelo total do dia não existe mais',
  not exists (select 1 from cx.alertas where tipo = 'multi_divergente' and status = 'aberto'));
select t.ok('multi_venda','central mostra o informativo como baixa prioridade',
  (select count(*) from cx.alertas where tipo = 'multi_outro_dia' and status = 'aberto') > 0);

-- conversa com o agente no aviso (pedido 07/11)
select set_config('t.ref', (select referencia from cx.alertas where unidade_id = 'sorocaba' and tipo = 'caixa_multi_sem_venda' and status = 'aberto' limit 1), false);
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select public.painel_aviso_escrever('caixa', 'caixa_multi_sem_venda', current_setting('t.ref'), 'Esse valor entrou duplicado, confere?', 'comentar');
select t.ok('conversa','mensagem da pessoa fica no aviso',
  jsonb_array_length(public.painel_aviso_conversa('caixa', 'caixa_multi_sem_venda', current_setting('t.ref'))->'mensagens') = 1);
reset role; select t.sem_jwt();
select t.ok('conversa','agente vê a mensagem pendente com o aviso',
  exists (select 1 from jsonb_array_elements(public.agente_avisos_pendentes()) x where x->>'referencia' = current_setting('t.ref') and x->'aviso'->>'status' = 'aberto'));
select public.agente_aviso_responder((select id from core.avisos_conversa where referencia = current_setting('t.ref') and papel = 'pessoa'), 'Conferi: não há venda nem parcela desse valor.');
select t.ok('conversa','resposta do agente fecha a pendência',
  not exists (select 1 from jsonb_array_elements(public.agente_avisos_pendentes()) x where x->>'referencia' = current_setting('t.ref'))
  and (select count(*) from core.avisos_conversa where referencia = current_setting('t.ref')) = 2);
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('conversa','gerente não marca aviso como explicado',
  $q$select public.painel_aviso_escrever('caixa', 'caixa_multi_sem_venda', current_setting('t.ref'), 'explicado', 'explicar')$q$, 'permiss');
select t.jwt('00000000-0000-0000-0000-00000000a001');
select public.painel_aviso_escrever('caixa', 'caixa_multi_sem_venda', current_setting('t.ref'), 'Parcela lançada errado, já corrigida na loja.', 'explicar');
reset role; select t.sem_jwt();
select cx.recalcular();
select t.ok('conversa','aviso explicado não volta a abrir',
  exists (select 1 from cx.alertas where referencia = current_setting('t.ref') and status = 'explicado')
  and not exists (select 1 from cx.alertas where referencia = current_setting('t.ref') and status = 'aberto'));
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select public.painel_aviso_escrever('caixa', 'caixa_multi_sem_venda', current_setting('t.ref'), 'Volta a cobrar.', 'reabrir');
reset role; select t.sem_jwt();
select t.ok('conversa','reabrir volta a cobrar o aviso',
  exists (select 1 from cx.alertas where referencia = current_setting('t.ref') and status = 'aberto'));
delete from core.avisos_conversa where referencia = current_setting('t.ref');

-- regras editáveis: dias depois = 1 → a venda lançada 2 dias depois deixa de casar
update core.config set valor = '1' where chave = 'cx.multi_dias_depois';
select cx.recalcular();
select t.ok('multi_venda','com prazo de 1 dia, a venda lançada 2 dias depois fica sem par',
  exists (select 1 from cx.alertas where unidade_id = 'sorocaba' and tipo = 'multi_sem_caixa' and status = 'aberto' and detalhe->>'venda' = '5001'));
update core.config set valor = '7' where chave = 'cx.multi_dias_depois';
select cx.recalcular();

delete from cx.alertas where unidade_id = 'sorocaba'; delete from cx.pagamentos where unidade_id = 'sorocaba';
delete from cx.dias where unidade_id = 'sorocaba'; delete from multi.capturas where loja = 'sorocaba';
select cx.recalcular();
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),300) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DO MULTICREDIÁRIO VENDA A VENDA FALHANDO'; end if; end $$;
