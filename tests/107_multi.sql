-- Conferência do Multicrediário × ADM (pedido 07/11; dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
delete from multi.capturas;

-- Operação (detalhe): 4 vendas aprovadas e 1 negada; cabeçalho real do Multicrediário
select public.multi_receber('operacao_detalhe', 'Tipo=1&Data=' || to_char(current_date - 5, 'DD/MM/YYYY'), current_date - 5,
  '["Loja","Data venda","Data venda efetivação","Hora","Plano","Meio de Pagamento","CPF","Nº Venda","Parcela","Valor Parcela","Valor Venda","Valor Entrada","Valor Total Venda","Consultado Garantido","Autorização / Resposta","Cupom Fiscal / ID"]',
  jsonb_build_array(
    jsonb_build_array('B0','','','10:00','0 + 12','Boleto','111.111.111-11','0001','12','100,00','1.000,00','0,00','1.401,27','1.401,27','A1',''),   -- ok
    jsonb_build_array('B0','','','10:00','1 + 10','Boleto','222.222.222-22','0002','10','200,00','1.700,00','300,00','2.531,11','2.231,11','A2',''), -- ADM somou entrada
    jsonb_build_array('B0','','','10:00','0 + 12','Boleto','333.333.333-33','0003','12','100,00','1.400,00','0,00','1.955,19','1.955,19','A3',''),   -- centavos
    jsonb_build_array('B0','','','10:00','0 + 7','Boleto','444.444.444-44','0004','7','100,00','700,00','0,00','855,87','855,87','A4','')));        -- sem ADM
select public.multi_receber('operacao_detalhe', 'Tipo=2&Data=' || to_char(current_date - 5, 'DD/MM/YYYY'), current_date - 5,
  '["Loja","Data venda","Data venda efetivação","Hora","Plano","Meio de Pagamento","CPF","Nº Venda","Parcela","Valor Venda","Valor Entrada","Valor Total Venda","Resposta"]',
  jsonb_build_array(jsonb_build_array('B0','','','15:07','0 + 12','','555.555.555-55','0005','12','1.700,00','0,00','1.700,00','Limite excedido')));
select public.multi_receber('operacao', 'periodo=CORRENTE', null, '["Dia"]', '[["x"]]');
-- Recebimentos: 2 parcelas recebidas (uma com baixa no ADM, outra sem)
select public.multi_receber('recebimentos_detalhe', 'Tipo=2&Data=' || to_char(current_date - 1, 'DD/MM/YYYY'), current_date - 1,
  '["Loja","Data Recebimento","Plano","Prazo entre Parcelas","CPF","Nº Venda","Parcela","Valor Recebido","Valor Parcela","Autorização","Cupom Fiscal / ID"]',
  jsonb_build_array(
    jsonb_build_array('0001','' || to_char(current_date - 1, 'DD/MM/YYYY'),'0 + 12','30','111.111.111-11','0001','1','116,77','116,77','X',''),
    jsonb_build_array('0001','' || to_char(current_date - 1, 'DD/MM/YYYY'),'0 + 12','30','111.111.111-11','0001','2','116,77','116,77','X',''),
    jsonb_build_array('0001','' || to_char(current_date - 1, 'DD/MM/YYYY'),'0 + 7','30','444.444.444-44','0004','1','122,27','122,27','X',''),       -- venda nova sem carnê
    jsonb_build_array('0001','' || to_char(current_date - 1, 'DD/MM/YYYY'),'0 + 12','30','777.777.777-77','0007','6','90,00','90,00','X','')));       -- venda antiga (antes do ADM)
-- Documentos: venda 0001 com proposta enviada (fica ATIVO no Multicrediário) = ok; venda 0002 sem a proposta
select public.multi_receber('documentos', '11111111111|0001', current_date - 5, '["Tipo de Documento","Obrigatório","Quantidade","Situação","Informação","Envio"]',
  '[["Documento Identificação","SIM","2","POSITIVADO","INFO",""],["Proposta Simplificada","SIM","1","ATIVO","INFO",""],["Comprovante de Renda","NÃO","0","ATIVO","INFO",""]]');
select public.multi_receber('documentos', '22222222222|0002', current_date - 5, '["Tipo de Documento","Obrigatório","Quantidade","Situação","Informação","Envio"]',
  '[["Documento Identificação","SIM","2","POSITIVADO","INFO",""],["Proposta Simplificada","SIM","0","ATIVO","INFO",""]]');

select t.ok('leitura','vendas lidas pelo nome da coluna, com financiado e entrada',
  (select count(*) from multi.v_operacoes where tipo = 1) = 4
  and (select garantido from multi.v_operacoes where venda = '0002') = 2231.11 and (select entrada from multi.v_operacoes where venda = '0002') = 300);

-- cópia do ADM (o CPF chega só como código)
select set_config('t.r', multi.receber_adm(jsonb_build_array(
  jsonb_build_object('crediario_id','c1','unidade','saovicente','os','9001','dt_compra',current_date - 5,'valor_crediario',1401.27,'num_parcelas',12,'status','aberto','cpf_hash',multi._hash('11111111111')),
  jsonb_build_object('crediario_id','c2','unidade','saovicente','os','9002','dt_compra',current_date - 5,'valor_crediario',2531.11,'valor_entrada',300,'num_parcelas',10,'status','aberto','cpf_hash',multi._hash('22222222222')),
  jsonb_build_object('crediario_id','c3','unidade','saovicente','os',null,'dt_compra',current_date - 3,'valor_crediario',1955.16,'num_parcelas',12,'status','aberto','cpf_hash',multi._hash('33333333333')),
  jsonb_build_object('crediario_id','c9','unidade','saovicente','os','9009','dt_compra',current_date - 4,'valor_crediario',1579.81,'num_parcelas',10,'status','aberto','cpf_hash',multi._hash('99999999999')),
  jsonb_build_object('crediario_id','cx','unidade','campinas','os','7001','dt_compra',current_date - 4,'valor_crediario',999,'num_parcelas',10,'status','aberto','cpf_hash',multi._hash('88888888888'))),
  jsonb_build_array(jsonb_build_object('id','p1','crediario_id','c1','numero',1,'valor',116.77,'dt_pagamento',current_date - 1),
                    jsonb_build_object('id','p2','crediario_id','c1','numero',2,'valor',116.77)))::text, false);

select t.ok('conferencia','venda que bate fica sem aviso', not exists (select 1 from multi.achados where chave = 'venda:0001' and status = 'aberto'));
select t.ok('conferencia','ADM que somou a entrada no crediário vira aviso específico',
  exists (select 1 from multi.achados where tipo = 'valor_com_entrada' and chave = 'venda:0002' and descricao like '%entrada de R$ 300,00%'));
select t.ok('conferencia','diferença de centavos, OS em branco e data diferente aparecem',
  exists (select 1 from multi.achados where tipo = 'centavos' and chave = 'venda:0003')
  and exists (select 1 from multi.achados where tipo = 'sem_os' and chave = 'venda:0003')
  and exists (select 1 from multi.achados where tipo = 'data_diferente' and chave = 'venda:0003'));
select t.ok('conferencia','venda aprovada sem crediário no ADM', exists (select 1 from multi.achados where tipo = 'venda_sem_adm' and chave = 'venda:0004'));
select t.ok('conferencia','crediário no ADM sem venda no Multicrediário (só São Vicente)',
  exists (select 1 from multi.achados where tipo = 'adm_sem_venda' and chave = 'adm:c9')
  and not exists (select 1 from multi.achados where chave = 'adm:cx'));
select t.ok('parcelas','parcela recebida sem baixa no ADM vira aviso; a que tem baixa, não',
  exists (select 1 from multi.achados where tipo = 'parcela_sem_baixa' and chave = 'parcela:0001:2')
  and not exists (select 1 from multi.achados where chave = 'parcela:0001:1'));
select t.ok('parcelas','parcela de venda nova sem carnê no ADM vira aviso; a de venda anterior ao ADM, não',
  exists (select 1 from multi.achados where tipo = 'parcela_sem_carne' and chave = 'parcela:0004:1')
  and not exists (select 1 from multi.achados where chave = 'parcela:0007:6'));
select t.ok('documentos','obrigatório sem arquivo vira aviso; enviado (ATIVO) e opcional, não',
  exists (select 1 from multi.achados where tipo = 'documento_pendente' and chave = 'doc:0002:Proposta Simplificada' and descricao like '%não foi enviado%')
  and not exists (select 1 from multi.achados where chave like 'doc:0001:%'));
select t.ok('documentos','fila do robô: vendas aprovadas sem documento lido (pendentes só depois de 12 h)',
  (select array_agg(venda order by venda) from public.multi_docs_fila(30, 80)) = array['0003','0004']);  -- 0001 ok, 0002 lida agora há pouco
select t.ok('conferencia','os avisos não mostram CPF', not exists (select 1 from multi.achados where descricao ~ '\d{3}\.\d{3}\.\d{3}'));

-- correções no ADM fecham os avisos sozinhos
select multi.receber_adm(jsonb_build_array(
  jsonb_build_object('crediario_id','c2','unidade','saovicente','os','9002','dt_compra',current_date - 5,'valor_crediario',2231.11,'valor_entrada',300,'num_parcelas',10,'status','aberto','cpf_hash',multi._hash('22222222222'))),
  jsonb_build_array(jsonb_build_object('id','p2','crediario_id','c1','numero',2,'valor',116.77,'dt_pagamento',current_date)));
select t.ok('conferencia','corrigido no ADM, o aviso fecha sozinho',
  (select status from multi.achados where chave = 'venda:0002' order by id desc limit 1) = 'resolvido'
  and (select status from multi.achados where chave = 'parcela:0001:2' order by id desc limit 1) = 'resolvido');

-- painel
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.p', public.painel_multi(current_date - 5)::text, false);
select t.ok('painel','tela traz resumo do dia, avisos, vendas conferidas e negadas',
  (current_setting('t.p')::jsonb->'resumo'->>'aprovadas')::int = 4 and (current_setting('t.p')::jsonb->'resumo'->>'negadas')::int = 1
  and jsonb_array_length(current_setting('t.p')::jsonb->'vendas') = 4 and jsonb_array_length(current_setting('t.p')::jsonb->'abertos') >= 5);
reset role;
select set_config('t.aid', (select id from multi.achados where tipo = 'venda_sem_adm' and status = 'aberto')::text, false);
set role authenticated;
select t.ok('ajustes','tela mostra as regras da conferência', (public.painel_multi_ajustes()->>'adm_inicio') = '2026-08-25');
select t.erro('ajustes','tolerância fora da faixa é recusada', 'select public.painel_multi_ajustes_salvar(10, ''2026-08-25'', ''saovicente'')', 'tolerância');
select public.painel_multi_ajustes_salvar(0.05, current_date - 30, 'SaoVicente, campinas', 'teste');
select t.ok('ajustes','regras salvas pela tela (unidades normalizadas)',
  (public.painel_multi_ajustes()->>'unidades') in ('campinas,saovicente','saovicente,campinas') and (public.painel_multi_ajustes()->>'tolerancia')::numeric = 0.05);
select public.painel_multi_ajustes_salvar(0.01, '2026-08-25', 'saovicente', 'volta');
select t.erro('painel','resolver exige dizer o que foi feito', format('select public.painel_multi_resolver(%s, %L)', current_setting('t.aid'), 'ok'), 'escreva o que foi feito');
select public.painel_multi_resolver(current_setting('t.aid')::bigint, 'Lançado no ADM pela loja');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('painel','gerente de loja não vê a conferência da rede', 'select public.painel_multi()', 'sem permissão');
select t.erro('ajustes','gerente de loja não altera as regras', 'select public.painel_multi_ajustes_salvar(0.01, ''2026-08-25'', ''saovicente'')', 'sem permissão');
reset role;
select t.sem_jwt();
select t.ok('painel','aviso resolvido com a nota e auditado',
  (select status = 'resolvido' and nota = 'Lançado no ADM pela loja' from multi.achados where id = current_setting('t.aid')::bigint)
  and exists (select 1 from core.auditoria where acao = 'multi_aviso_resolvido') and exists (select 1 from core.auditoria where acao = 'multi_ajustes_alterados'));

select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DO MULTICREDIÁRIO FALHANDO'; end if; end $$;
