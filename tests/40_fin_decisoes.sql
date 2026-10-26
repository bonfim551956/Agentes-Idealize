-- Decisões da homologação (v0.3.0): estorno, fatura, VT no fim do mês, reclassificação humana
\set ON_ERROR_STOP on
delete from t.resultados;

insert into core.unidades (id, nome) values ('u_dec','Unidade Dec'), ('u_dec2','Unidade Dec 2');
insert into fin.contas (id, apelido, tipo, unidade_id) values ('c_dec','Conta Dec','corrente','u_dec'),
  ('c_dec_cartao','Cartão Dec','cartao_credito','u_dec');
insert into core.principais (id, tipo, nome) values ('00000000-0000-0000-0000-0000000000d1','usuario','Diretor Dec');
insert into core.principal_papeis (principal_id, papel_id) values ('00000000-0000-0000-0000-0000000000d1','diretoria');
-- colaborador: folha no geral, VT quando pago no fim do mês
insert into fin.regras_classificacao (padrao, sentido, natureza, categoria_id, prioridade, responsavel) values
  ('88888888888','debito','despesa','folha',40,'teste');
insert into fin.regras_classificacao (padrao, sentido, natureza, categoria_id, prioridade, responsavel, ultimos_dias_uteis) values
  ('88888888888','debito','despesa','beneficios',35,'teste',2);
insert into fin.regras_classificacao (padrao, sentido, natureza, categoria_id, prioridade, responsavel) values
  ('FORNECEDOR TRAFEGO','debito','despesa','trafego_pago',40,'teste');

select t.ok('vt','fim do mês: 30 e 31/10 (corridos) e 30/10 sexta (útil) contam', fin.no_fim_do_mes('2026-10-30',2) and fin.no_fim_do_mes('2026-10-31',2));
select t.ok('vt','fim de semana empurra: 28/02/2026 (sáb) e 26/02 (qui, penúltimo útil) contam; 25/02 não',
  fin.no_fim_do_mes('2026-02-28',2) and fin.no_fim_do_mes('2026-02-26',2) and not fin.no_fim_do_mes('2026-02-25',2));
select t.ok('vt','meio do mês não conta', not fin.no_fim_do_mes('2026-10-20',2));

do $$ declare r jsonb; d uuid; e uuid; s uuid; f uuid; begin
  perform fin.importar_extrato('c_dec', repeat('7',64), 'json', '[
    {"data":"2026-10-06","valor":-1000.00,"descricao":"PAGAMENTO PIX-PIX_DEB 88888888888 COLABORADOR","documento":"D1"},
    {"data":"2026-10-30","valor":-120.00,"descricao":"PAGAMENTO PIX-PIX_DEB 88888888888 COLABORADOR","documento":"D2"},
    {"data":"2026-10-09","valor":-1500.00,"descricao":"LIQUIDACAO BOLETO- FORNECEDOR TRAFEGO","documento":"D3"},
    {"data":"2026-10-09","valor":1500.00,"descricao":"DVCOB DEVOLUCAO","documento":"D4"},
    {"data":"2026-10-23","valor":-4165.55,"descricao":"LIQUIDACAO BOLETO SICREDI CARTAO","documento":"D5"}
  ]'::jsonb, 'agente_financeiro', 10000, 4714.45);
  r := fin.lancar_do_extrato('c_dec','agente_financeiro');
  perform t.ok('vt','PIX ao colaborador no meio do mês = folha',
    (select categoria_id from fin.lancamentos l join fin.conciliacoes x on x.lancamento_id=l.id join fin.movimentos m on m.id=x.movimento_id where m.documento_banco='D1')='folha');
  perform t.ok('vt','PIX ao colaborador no fim do mês = vale-transporte (benefícios)',
    (select categoria_id from fin.lancamentos l join fin.conciliacoes x on x.lancamento_id=l.id join fin.movimentos m on m.id=x.movimento_id where m.documento_banco='D2')='beneficios');

  select l.id into d from fin.lancamentos l join fin.conciliacoes x on x.lancamento_id=l.id join fin.movimentos m on m.id=x.movimento_id where m.documento_banco='D3';
  select l.id into e from fin.lancamentos l join fin.conciliacoes x on x.lancamento_id=l.id join fin.movimentos m on m.id=x.movimento_id where m.documento_banco='D4';
  select l.id into s from fin.lancamentos l join fin.conciliacoes x on x.lancamento_id=l.id join fin.movimentos m on m.id=x.movimento_id where m.documento_banco='D5';
  perform set_config('t.d', d::text, false); perform set_config('t.e', e::text, false); perform set_config('t.s', s::text, false);
end $$;

-- estorno
select t.erro('estorno','agente não marca estorno',
  $q$select fin.marcar_estorno(current_setting('t.e')::uuid, current_setting('t.d')::uuid, (select id from core.principais where agente_id='financeiro'), 'x')$q$, 'pessoa');
select t.erro('estorno','estorno com o mesmo sentido da original é recusado',
  $q$select fin.marcar_estorno(current_setting('t.s')::uuid, current_setting('t.d')::uuid, '00000000-0000-0000-0000-0000000000d1', 'x')$q$, 'oposto');
do $$ begin
  update fin.lancamentos set categoria_id='outras_receitas', status='conciliado' where id = current_setting('t.e')::uuid;
  perform t.ok('estorno','antes: boleto devolvido infla receita e despesa em 1.500',
    (select sum(valor) from fin.v_dre where unidade_id='u_dec' and categoria_id='trafego_pago') = 1500
    and (select sum(valor) from fin.v_dre where unidade_id='u_dec' and natureza='receita') = 1500);
  perform fin.marcar_estorno(current_setting('t.e')::uuid, current_setting('t.d')::uuid, '00000000-0000-0000-0000-0000000000d1', 'boleto devolvido no mesmo dia');
  perform t.ok('estorno','depois: líquido zero na DRE e nenhuma receita fantasma',
    (select sum(valor) from fin.v_dre where unidade_id='u_dec' and categoria_id='trafego_pago') = 0
    and coalesce((select sum(valor) from fin.v_dre where unidade_id='u_dec' and natureza='receita'),0) = 0);
  perform t.ok('estorno','caixa continua mostrando as duas movimentações reais',
    (select sum(entradas) from fin.v_caixa_conta where conta_id='c_dec') = 1500);
end $$;
select t.erro('estorno','estorno acima da original é recusado',
  $q$select fin.marcar_estorno(current_setting('t.e')::uuid, current_setting('t.d')::uuid, '00000000-0000-0000-0000-0000000000d1', 'de novo')$q$);

-- fatura do cartão
do $$ declare f uuid; c uuid; begin
  perform t.ok('fatura','antes: débito do cartão contado como despesa', (select natureza from fin.lancamentos where id=current_setting('t.s')::uuid) = 'despesa');
  f := fin.marcar_pagamento_fatura(current_setting('t.s')::uuid, 'c_dec_cartao', '2026-10-01', '2026-10-23',
         '00000000-0000-0000-0000-0000000000d1', 'Diego: é a fatura do cartão');
  perform t.ok('fatura','vira pagamento de fatura: sai da DRE, fica no caixa',
    (select natureza from fin.lancamentos where id=current_setting('t.s')::uuid)='pagamento_fatura'
    and not exists (select 1 from fin.v_dre where unidade_id='u_dec' and valor=4165.55)
    and exists (select 1 from fin.v_caixa_conta where conta_id='c_dec' and natureza='pagamento_fatura' and saidas=4165.55));
  perform t.ok('fatura','sem as compras lançadas: fatura divergente + pendência material',
    (select status from fin.faturas_cartao where id=f)='divergente'
    and exists (select 1 from fin.pendencias where tipo='fatura_divergente' and status='aberta' and material));
  -- lançar as compras da fatura fecha a divergência sozinho
  c := fin.registrar_lancamento('despesa','saida',4000,'u_dec','2026-10-05','t','manual','c_dec_cartao','sistemas',null,null,null,'2026-10-05','confirmado');
  perform t.ok('fatura','compras parciais: continua divergente', (select status from fin.faturas_cartao where id=f)='divergente');
  c := fin.registrar_lancamento('despesa','saida',165.55,'u_dec','2026-10-06','t','manual','c_dec_cartao','correios',null,null,null,'2026-10-06','confirmado');
  perform t.ok('fatura','compras = pagamento: fatura paga e pendência resolvida automaticamente',
    (select status from fin.faturas_cartao where id=f)='paga'
    and not exists (select 1 from fin.pendencias where tipo='fatura_divergente' and status='aberta' and lancamento_id=current_setting('t.s')::uuid));
  perform t.ok('fatura','DRE passa a ter as compras (4.165,55) e não o pagamento',
    (select sum(valor) from fin.v_dre where unidade_id='u_dec' and categoria_id in ('sistemas','correios')) = 4165.55);
end $$;

-- reclassificação
select t.erro('reclass','agente não reclassifica',
  $q$select fin.reclassificar(current_setting('t.d')::uuid,'google_ads',(select id from core.principais where agente_id='financeiro'),'x')$q$, 'pessoa');
select t.erro('reclass','reclassificar sem motivo é recusado',
  $q$select fin.reclassificar(current_setting('t.d')::uuid,'google_ads','00000000-0000-0000-0000-0000000000d1','')$q$, 'motivo');
select t.erro('reclass','categoria de receita em saída é recusada',
  $q$select fin.reclassificar(current_setting('t.d')::uuid,'vendas_pix','00000000-0000-0000-0000-0000000000d1','x')$q$, 'incompat');
do $$ declare tu uuid; begin
  perform fin.reclassificar(current_setting('t.d')::uuid,'google_ads','00000000-0000-0000-0000-0000000000d1','era Google');
  perform t.ok('reclass','reclassificação muda a DRE e fica na auditoria com antes/depois',
    (select categoria_id from fin.lancamentos where id=current_setting('t.d')::uuid)='google_ads'
    and exists (select 1 from core.auditoria where acao='reclassificacao' and entidade_id=current_setting('t.d')
                and antes->>'categoria'='trafego_pago' and depois->>'categoria'='google_ads'));
  -- perna única de transferência entre unidades → receita de custos compartilhados recebidos
  tu := gen_random_uuid();
  insert into fin.lancamentos (id, natureza, sentido, valor, unidade_id, conta_id, data_competencia, data_caixa, status, origem, par_id, criado_por)
  values (tu,'transferencia_unidades','entrada',1889.70,'u_dec','c_dec','2026-10-06','2026-10-06','confirmado','extrato',tu,'t');
  perform fin.reclassificar(tu,'recebimento_intercompany','00000000-0000-0000-0000-0000000000d1','Diego: custos compartilhados');
  perform t.ok('reclass','transferência de perna única vira receita intercompany',
    (select natureza||'/'||categoria_id from fin.lancamentos where id=tu)='receita/recebimento_intercompany'
    and (select par_id from fin.lancamentos where id=tu) is null);
end $$;

-- saldo de abertura e regra versionada
do $$ declare i uuid; r1 bigint; r2 bigint; begin
  select id into i from fin.importacoes where conta_id='c_dec';
  perform fin.confirmar_saldo_inicial(i, 10000, '00000000-0000-0000-0000-0000000000d1', 'conferido no app do banco');
  perform t.ok('saldo','saldo inicial confirmado e fechando com o final: sem pendência',
    not exists (select 1 from fin.pendencias where tipo='saldo_divergente' and detalhe->>'importacao'=i::text and status='aberta'));
  perform fin.confirmar_saldo_inicial(i, 9999, '00000000-0000-0000-0000-0000000000d1', 'teste de divergência');
  perform t.ok('saldo','saldo inicial que não fecha abre pendência',
    exists (select 1 from fin.pendencias where tipo='saldo_divergente' and detalhe->>'importacao'=i::text and status='aberta'));
  r1 := fin.definir_regra('99999999999','debito','despesa','folha',40,'00000000-0000-0000-0000-0000000000d1','teste v1');
  r2 := fin.definir_regra('99999999999','debito','despesa','premios',40,'00000000-0000-0000-0000-0000000000d1','teste v2');
  perform t.ok('regra','nova versão da regra desativa a anterior, sem apagar',
    (select status from fin.regras_classificacao where id=r1)='inativa' and (select versao from fin.regras_classificacao where id=r2)=2);
  perform t.ok('regra','auditoria da regra não grava o CPF em claro', not exists (select 1 from core.auditoria where depois::text like '%99999999999%'));
end $$;
select t.ok('auditoria','cadeia íntegra após as decisões', core.verificar_auditoria() is null);

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DE DECISÕES FALHANDO'; end if; end $$;
