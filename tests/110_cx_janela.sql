-- Caixa: janela pelos dias de operação, Pix em dois, parcela do Asaas, dia da semana e Multicrediário (dados sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into core.unidades (id, nome) values ('piracicaba','Piracicaba') on conflict (id) do nothing;
update core.config set valor = '0' where chave = 'cx.dias_sem_expediente';   -- domingo fechado
create or replace function t.sab() returns date language sql as $$
  select cx._hoje() - ((extract(dow from cx._hoje())::int + 1) % 7) - 14 $$;
delete from cx.alertas where unidade_id = 'piracicaba'; delete from cx.pagamentos where unidade_id = 'piracicaba';
delete from cx.dias where unidade_id = 'piracicaba'; delete from cx.recebimentos where unidade_id = 'piracicaba';
delete from multi.capturas where loja = 'piracicaba';

insert into fin.contas (id, apelido, tipo, unidade_id) values ('teste_cxj_banco', 'Banco Piracicaba (teste)', 'corrente', 'piracicaba') on conflict (id) do nothing;
insert into fin.movimentos (conta_id, data, sentido, valor, descricao, chave_dedup) values
  ('teste_cxj_banco', t.sab(), 'credito', 300, 'RECEBIMENTO PIX CLIENTE SABADO', 'cxj-1'),
  ('teste_cxj_banco', t.sab() + 1, 'credito', 720, 'RECEBIMENTO PIX CLIENTE DOMINGO', 'cxj-2'),
  ('teste_cxj_banco', t.sab() + 3, 'credito', 540, 'RECEBIMENTO PIX CLIENTE PARTE 1', 'cxj-3'),
  ('teste_cxj_banco', t.sab() + 3, 'credito', 60, 'RECEBIMENTO PIX CLIENTE PARTE 2', 'cxj-4'),
  ('teste_cxj_banco', cx._hoje(), 'credito', 1, 'RENDIMENTO', 'cxj-5');
insert into cx.dias (unidade_id, dia, caixa, soma_formas) values
  ('piracicaba', t.sab(), 0, 0), ('piracicaba', t.sab() + 2, 300, 300), ('piracicaba', t.sab() + 3, 1783.24, 1783.24);
insert into cx.pagamentos (unidade_id, dia, origem, forma, valor) values
  ('piracicaba', t.sab() + 2, 'venda', 'pix', 300),          -- Pix do sábado lançado na segunda
  ('piracicaba', t.sab() + 3, 'venda', 'pix', 600),          -- pago em dois Pix (540 + 60)
  ('piracicaba', t.sab() + 3, 'venda', 'asaas', 130),        -- parcela de carnê paga pelo Asaas
  ('piracicaba', t.sab() + 3, 'venda', 'crediario', 900),    -- venda no Multicrediário (no Multi: 1.000)
  ('piracicaba', t.sab() + 3, 'venda', 'crediario', 153.24); -- parcela recebida na loja
insert into cx.recebimentos (id, fonte, unidade_id, dia, forma, valor, parcela_crediario) values
  ('asaas:cxj_parc', 'asaas', 'piracicaba', t.sab() + 3, 'asaas', 130, true),
  ('asaas:cxj_avulsa', 'asaas', 'piracicaba', t.sab() - 3, 'asaas', 50, false);
insert into cx.cobertura (fonte, unidade_id, ate) values ('asaas', 'piracicaba', cx._hoje()) on conflict (fonte, unidade_id) do update set ate = excluded.ate;
select public.multi_receber('operacao_detalhe', 'Tipo=1&Data=' || to_char(t.sab() + 3, 'DD/MM/YYYY'), t.sab() + 3,
  '["CPF","Nº Venda","Valor Venda","Valor Entrada","Valor Total Venda","Consultado Garantido"]',
  '[["777.777.777-77","9901","1.000,00","0,00","1.350,00","1.350,00"]]', 'piracicaba');
select public.multi_receber('recebimentos_detalhe', 'Tipo=2&Data=' || to_char(t.sab() + 3, 'DD/MM/YYYY'), t.sab() + 3,
  '["Data Recebimento","CPF","Nº Venda","Parcela","Valor Recebido"]',
  jsonb_build_array(jsonb_build_array(to_char(t.sab() + 3, 'DD/MM/YYYY'), '888.888.888-88', '9800', '3', '153,24')), 'piracicaba');
select public.multi_receber('operacao', 'periodo=TESTE', null, '["Dia"]', '[["x"]]', 'piracicaba');

select cx.recalcular();

select t.ok('janela','Pix do sábado casa com o caixa de segunda (domingo fechado)',
  exists (select 1 from cx.casamentos c join cx.pagamentos p on p.id = c.pagamento_id where p.unidade_id = 'piracicaba' and p.valor = 300));
select t.ok('pix','um lançamento do caixa = dois Pix (540 + 60 = 600)',
  exists (select 1 from cx.casamentos c join cx.pagamentos p on p.id = c.pagamento_id where p.unidade_id = 'piracicaba' and p.valor = 600 and c.modo = 'um_em_dois'));
select t.ok('asaas','parcela de carnê paga pelo Asaas casa com o lançamento Asaas do caixa',
  exists (select 1 from cx.casamentos c join cx.pagamentos p on p.id = c.pagamento_id where p.unidade_id = 'piracicaba' and p.forma = 'asaas'));
select t.ok('aviso','Pix do domingo sem registro no caixa: com dia da semana e loja fechada',
  exists (select 1 from cx.alertas where unidade_id = 'piracicaba' and tipo = 'sem_registro_no_caixa' and status = 'aberto'
          and detalhe->>'dia_semana' = 'domingo' and (detalhe->>'loja_fechada')::boolean and (detalhe->>'valor')::numeric = 720));
select t.ok('aviso','o Pix dividido não vira "sem registro"', not exists (select 1 from cx.alertas where unidade_id = 'piracicaba'
  and tipo = 'sem_registro_no_caixa' and status = 'aberto' and dia = t.sab() + 3));
select t.ok('multi','Multicrediário × caixa: R$ 900 no caixa × R$ 1.000 no Multi (parcela recebida na loja fica de fora)',
  exists (select 1 from cx.alertas where unidade_id = 'piracicaba' and tipo = 'multi_divergente' and status = 'aberto'
          and (detalhe->>'caixa_vendas')::numeric = 900 and (detalhe->>'multi_vendas')::numeric = 1000 and (detalhe->>'parcelas_no_caixa')::numeric = 153.24),
  (select jsonb_agg(detalhe)::text from cx.alertas where unidade_id = 'piracicaba' and tipo = 'multi_divergente'));
select t.ok('relatorio','relatório do dia avisa o dinheiro sem registro e o Multicrediário',
  pg_get_functiondef('rel.gerar(date)'::regprocedure) ~ 'sem registro no caixa' and pg_get_functiondef('rel.gerar(date)'::regprocedure) ~ 'Multicrediário × caixa' and rel.gerar() is not null);

-- revisão 07/11: mesmo dia casa primeiro; entrega procura o Pix até 15 dias antes; aviso de extrato com dias vazios
insert into fin.movimentos (conta_id, data, sentido, valor, descricao, chave_dedup) values
  ('teste_cxj_banco', t.sab() + 4, 'credito', 100, 'RECEBIMENTO PIX QUARTA', 'cxj-6'),
  ('teste_cxj_banco', t.sab() - 6, 'credito', 230, 'RECEBIMENTO PIX ANTECIPADO', 'cxj-7');
insert into cx.dias (unidade_id, dia, caixa, soma_formas) values ('piracicaba', t.sab() + 4, 330, 330) on conflict do nothing;
insert into cx.pagamentos (unidade_id, dia, origem, forma, valor) values
  ('piracicaba', t.sab() + 2, 'venda', 'pix', 100),     -- segunda: o Pix dela não veio no extrato
  ('piracicaba', t.sab() + 4, 'venda', 'pix', 100),     -- quarta: o Pix de quarta é dela
  ('piracicaba', t.sab() + 4, 'entrega', 'pix', 230);   -- entrega: cliente pagou 10 dias antes
select cx.recalcular();
select t.ok('revisao','o Pix do mesmo dia fica com o caixa do mesmo dia',
  exists (select 1 from cx.casamentos c join cx.pagamentos p on p.id = c.pagamento_id join fin.movimentos m on 'banco:' || m.id = c.recebimento
          where p.unidade_id = 'piracicaba' and p.dia = t.sab() + 4 and p.valor = 100 and m.data = t.sab() + 4));
select t.ok('revisao','valor lançado na entrega acha o Pix pago dias antes',
  exists (select 1 from cx.casamentos c join cx.pagamentos p on p.id = c.pagamento_id where p.unidade_id = 'piracicaba' and p.origem = 'entrega' and p.valor = 230));
select t.ok('extrato','PDF lido com dias úteis vazios gera aviso',
  fin._checar_leitura('extrato', '{"formato":"ia","linhas":[{"data":"2026-10-26","valor":10},{"data":"2026-10-30","valor":5}]}')::text ~ '27/10, 28/10, 29/10');

update core.config set valor = '' where chave = 'cx.dias_sem_expediente';
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),160) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DO CAIXA (JANELA) FALHANDO'; end if; end $$;
