-- =============================================================================
-- Suíte do agente financeiro (schema fin). Dados 100% sintéticos.
-- Roda depois de 10_core_tests.sql (reaproveita t.ok / t.erro).
-- =============================================================================
\set ON_ERROR_STOP on
delete from t.resultados;

-- ---------------------------------------------------------------------------
-- Massa sintética
-- ---------------------------------------------------------------------------
insert into core.unidades (id, nome) values ('u_sv','Unidade SV'), ('u_cps','Unidade CPS'), ('u_adm','Administrativo');
insert into fin.empresas (id, razao_social, cnpj) values ('emp_sv','Empresa SV Ltda','11111111000111'), ('emp_cps','Empresa CPS ME','22222222000122');
insert into fin.unidade_empresa values ('u_sv','emp_sv'), ('u_cps','emp_cps'), ('u_adm','emp_sv');
insert into fin.contas (id, apelido, tipo, unidade_id, empresa_id, instituicao, final_numero) values
  ('c_sv','Banco SV','corrente','u_sv','emp_sv','Banco X','1111'),
  ('c_sv2','Aplicação SV','poupanca','u_sv','emp_sv','Banco X','2222'),
  ('c_cps','Banco CPS','corrente','u_cps','emp_cps','Banco Y','3333'),
  ('c_cartao','Cartão SV','cartao_credito','u_sv','emp_sv','Banco X','4444');
insert into fin.regras_classificacao (padrao, sentido, natureza, categoria_id, responsavel) values
  ('STONE','credito','receita','vendas_cartao','teste'),
  ('TARIFA','debito','despesa','tarifas','teste'),
  ('ANTHROPIC','debito','despesa','ia','teste');
insert into fin.regras_classificacao (padrao, sentido, natureza, unidade_destino, responsavel) values
  ('EMPRESA CPS','debito','transferencia_unidades','u_cps','teste');

insert into core.principais (id, tipo, nome) values
  ('00000000-0000-0000-0000-0000000000f1','usuario','Diretor 1'),
  ('00000000-0000-0000-0000-0000000000f2','usuario','Gerente SV');
insert into core.principal_papeis (principal_id, papel_id, unidade_id) values
  ('00000000-0000-0000-0000-0000000000f1','diretoria',null),
  ('00000000-0000-0000-0000-0000000000f2','gerente','u_sv');

-- ---------------------------------------------------------------------------
-- A. Natureza e regras de entrada
-- ---------------------------------------------------------------------------
select t.erro('fin.regras','receita com sentido de saída é recusada',
  $q$select fin.registrar_lancamento('receita','saida',10,'u_sv','2026-10-01','t','manual')$q$, 'incompat');
select t.erro('fin.regras','categoria de receita em despesa é recusada',
  $q$select fin.registrar_lancamento('despesa','saida',10,'u_sv','2026-10-01','t','manual','c_sv','vendas_pix')$q$, 'não é de');
select t.erro('fin.regras','lançamento não nasce conciliado (só o extrato concilia)',
  $q$select fin.registrar_lancamento('despesa','saida',10,'u_sv','2026-10-01','t','manual','c_sv','tarifas',null,null,null,null,'conciliado')$q$, 'status inicial');
select t.erro('fin.regras','confirmar despesa sem categoria é recusado',
  $q$select fin.registrar_lancamento('despesa','saida',10,'u_sv','2026-10-01','t','manual','c_sv',null,null,null,null,null,'confirmado')$q$);
select t.erro('fin.regras','transferência não entra pela porta de receita/despesa',
  $q$select fin.registrar_lancamento('transferencia_interna','saida',10,'u_sv','2026-10-01','t','manual')$q$, 'transfer');
select t.erro('fin.regras','ajuste sem aprovação da diretoria é recusado',
  $q$select fin.registrar_ajuste('u_sv','saida',5,'2026-10-01','arredondamento','00000000-0000-0000-0000-0000000000f2','t')$q$, 'diretoria');

-- ---------------------------------------------------------------------------
-- B. Importação de extrato
-- ---------------------------------------------------------------------------
do $$ declare r jsonb; begin
  r := fin.importar_extrato('c_sv', repeat('a',64), 'json', '[
    {"data":"2026-10-02","valor":1500.00,"descricao":"STONE DEB VISA","documento":"S1"},
    {"data":"2026-10-03","valor":-350.00,"descricao":"PIX ENVIADO FORNECEDOR LAB","documento":"E2E-LAB-1"},
    {"data":"2026-10-04","valor":-50.00,"descricao":"PIX ENVIADO MARIA"},
    {"data":"2026-10-04","valor":-50.00,"descricao":"PIX ENVIADO MARIA"},
    {"data":"2026-10-05","valor":-12.90,"descricao":"TARIFA PACOTE"},
    {"data":"2026-10-06","valor":-200.00,"descricao":"PIX ENVIADO JOAO SERVICOS","documento":"E2E-JOAO-1"},
    {"data":"2026-10-07","valor":-1000.00,"descricao":"PIX EMPRESA CPS REPASSE"},
    {"data":"2026-10-08","valor":-99.00,"descricao":"ANTHROPIC PBC"},
    {"data":"2026-10-09","valor":-500.00,"descricao":"TED APLICACAO PROPRIA"},
    {"data":"2026-10-10","valor":-75.00,"descricao":"PIX ENVIADO COLABORADOR REEMBOLSO"},
    {"data":"2026-10-12","valor":-430.00,"descricao":"PAGTO FATURA CARTAO"},
    {"data":"2026-10-28","valor":-180.00,"descricao":"PIX ENVIADO PAPELARIA"},
    {"data":"2026-10-29","valor":-33.33,"descricao":"PIX ENVIADO FULANO SEM CADASTRO"}
  ]'::jsonb, 'agente_financeiro', 10000.00, 8519.77);
  perform t.ok('fin.extrato','13 linhas novas importadas (inclui 2 PIX idênticos no mesmo dia)', (r->>'novas')::int = 13, r::text);
  r := fin.importar_extrato('c_sv', repeat('a',64), 'json', '[]'::jsonb, 'agente_financeiro');
  perform t.ok('fin.extrato','mesmo arquivo de novo não importa nada', (r->>'ja_importado')::boolean, r::text);
  r := fin.importar_extrato('c_sv', repeat('b',64), 'json', '[
    {"data":"2026-10-04","valor":-50.00,"descricao":"PIX ENVIADO MARIA"},
    {"data":"2026-10-04","valor":-50.00,"descricao":"PIX ENVIADO MARIA"},
    {"data":"2026-10-08","valor":-99.00,"descricao":"ANTHROPIC PBC"}
  ]'::jsonb, 'agente_financeiro');
  perform t.ok('fin.extrato','arquivo sobreposto: linhas já existentes não duplicam', (r->>'novas')::int = 0 and (r->>'duplicadas')::int = 3, r::text);
  perform t.ok('fin.extrato','os 2 PIX idênticos continuam sendo 2 movimentos',
    (select count(*) from fin.movimentos where conta_id='c_sv' and descricao='PIX ENVIADO MARIA') = 2);
  perform t.ok('fin.extrato','saldo do banco fecha com as linhas (sem pendência de saldo)',
    not exists (select 1 from fin.pendencias where tipo='saldo_divergente'));
  r := fin.importar_extrato('c_cps', repeat('c',64), 'json', '[{"data":"2026-10-07","valor":1000.00,"descricao":"PIX RECEBIDO EMPRESA SV"}]'::jsonb,
                            'agente_financeiro', 0, 999);
  perform t.ok('fin.extrato','saldo que não fecha abre pendência', exists (select 1 from fin.pendencias where tipo='saldo_divergente' and unidade_id='u_cps'));
end $$;
select t.erro('fin.extrato','dados do extrato são imutáveis',
  $q$update fin.movimentos set valor = 1 where descricao='TARIFA PACOTE'$q$, 'imutáveis');
select t.erro('fin.extrato','movimento bancário não é apagado',
  $q$delete from fin.movimentos where descricao='TARIFA PACOTE'$q$, 'não são apagados');

-- ---------------------------------------------------------------------------
-- C. Lançamentos vindos de comprovante (WhatsApp) e conciliação
-- ---------------------------------------------------------------------------
do $$ declare d1 uuid; d2 uuid; l_lab uuid; l_joao uuid; l_mar uuid; l_pap uuid; l_sem uuid; l_dup uuid; r jsonb; begin
  insert into fin.documentos (tipo, sha256, origem, unidade_id) values ('comprovante_pagamento', repeat('1',64), 'whatsapp', 'u_sv') returning id into d1;
  l_lab := fin.registrar_lancamento('despesa','saida',350,'u_sv','2026-10-03','agente_financeiro','whatsapp','c_sv','laboratorio',
            'Lab Teste','12345678000199','Lentes OS 1',  '2026-10-03','pendente','E2E-LAB-1', d1);
  -- comprovante com valor diferente do extrato (E2E igual, valor 210 × 200)
  l_joao := fin.registrar_lancamento('despesa','saida',210,'u_sv','2026-10-06','agente_financeiro','whatsapp','c_sv','prestadores',
            'Joao Servicos',null,null,'2026-10-06','pendente','E2E-JOAO-1');
  -- um único comprovante de 50 para 2 PIX iguais de 50 → ambíguo
  l_mar := fin.registrar_lancamento('despesa','saida',50,'u_sv','2026-10-04','agente_financeiro','whatsapp','c_sv','indique_ganhe',
            'Maria',null,null,'2026-10-04');
  -- data fora da janela: comprovante dia 15, banco dia 28
  l_pap := fin.registrar_lancamento('despesa','saida',180,'u_sv','2026-10-15','agente_financeiro','whatsapp','c_sv','suprimentos',
            'Papelaria',null,null,'2026-10-15');
  -- comprovante que nunca aparece no banco
  l_sem := fin.registrar_lancamento('despesa','saida',77,'u_sv','2026-10-20','agente_financeiro','whatsapp','c_sv','limpeza',
            'Limpeza X',null,null,'2026-10-20');
  -- mesmo E2E enviado duas vezes
  l_dup := fin.registrar_lancamento('despesa','saida',350,'u_sv','2026-10-03','agente_financeiro','whatsapp','c_sv','laboratorio',
            'Lab Teste','12345678000199',null,'2026-10-03','pendente','E2E-LAB-1');
  perform t.ok('fin.duplicidade','mesmo ID bancário enviado 2× abre duplicidade suspeita',
    exists (select 1 from fin.pendencias where tipo='duplicidade_suspeita' and lancamento_id = l_dup));
  perform fin.cancelar_lancamento(l_dup, 'duplicado do #'||(select numero from fin.lancamentos where id=l_lab), 'gerente');

  r := fin.conciliar('c_sv', 'agente_financeiro');
  perform t.ok('fin.conciliacao','concilia pelo ID bancário', (select status from fin.lancamentos where id=l_lab)='conciliado', r::text);
  perform t.ok('fin.conciliacao','regra registrada = id_bancario', (select regra from fin.conciliacoes where lancamento_id=l_lab)='id_bancario');
  perform t.ok('fin.divergencia','valor divergente NÃO concilia e fica contestado',
    (select status from fin.lancamentos where id=l_joao)='contestado'
    and (select status from fin.movimentos where documento_banco='E2E-JOAO-1')='divergente');
  perform t.ok('fin.divergencia','valor original preservado (sem forçar)',
    (select valor from fin.lancamentos where id=l_joao)=210 and (select valor from fin.movimentos where documento_banco='E2E-JOAO-1')=200);
  perform t.ok('fin.divergencia','divergência vira pendência material',
    exists (select 1 from fin.pendencias where tipo='divergencia' and lancamento_id=l_joao and material));
  perform t.ok('fin.conciliacao','1 comprovante para 2 PIX idênticos: ambiguidade, sem chute',
    (select status from fin.lancamentos where id=l_mar)='pendente'
    and (select count(*) from fin.pendencias where tipo='ambiguidade' and status='aberta' and (detalhe->>'valor')::numeric=50) >= 1);
  perform t.ok('fin.datas','data fora da janela não concilia automaticamente', (select status from fin.lancamentos where id=l_pap)='pendente');
  perform set_config('t.l_mar', l_mar::text, false); perform set_config('t.l_sem', l_sem::text, false);
  perform set_config('t.l_lab', l_lab::text, false); perform set_config('t.l_pap', l_pap::text, false);
  perform set_config('t.l_joao', l_joao::text, false);
end $$;

select t.erro('fin.conciliacao','conciliação manual com valor diferente é recusada',
  $q$select fin.conciliar_manual((select id from fin.movimentos where documento_banco='E2E-JOAO-1'),
       array[current_setting('t.l_joao')::uuid],'00000000-0000-0000-0000-0000000000f2','forçar')$q$, 'não se força');
select t.erro('fin.conciliacao','agente não faz conciliação manual',
  $q$select fin.conciliar_manual((select id from fin.movimentos where descricao='PIX ENVIADO PAPELARIA'),
       array[current_setting('t.l_pap')::uuid],(select id from core.principais where agente_id='financeiro'),'x')$q$, 'humana');

-- ---------------------------------------------------------------------------
-- D. Transferências, cartão, reembolso, rateio, cancelamento
-- ---------------------------------------------------------------------------
do $$ declare tr uuid; c1 uuid; c2 uuid; fat uuid; pg uuid; orig uuid; rb uuid; rat uuid; begin
  -- transferência entre contas próprias da mesma unidade (TED 500 → aplicação)
  tr := fin.registrar_transferencia('c_sv','c_sv2',500,'2026-10-09','agente_financeiro','manual','aplicação');
  perform t.ok('fin.transferencia','contas da mesma unidade = transferência interna com par',
    (select natureza from fin.lancamentos where id=tr)='transferencia_interna'
    and (select par_id from fin.lancamentos where id=tr) = (select id from fin.lancamentos where par_id=tr and id<>tr));

  -- cartão: duas compras no mês + pagamento da fatura (430)
  c1 := fin.registrar_lancamento('despesa','saida',300,'u_sv','2026-10-01','agente_financeiro','whatsapp','c_cartao','sistemas',
          'Sistema Y',null,null,'2026-10-01','confirmado');
  c2 := fin.registrar_lancamento('despesa','saida',130,'u_sv','2026-10-02','agente_financeiro','whatsapp','c_cartao','correios',
          'Correios',null,null,'2026-10-02','confirmado');
  select fatura_id into fat from fin.lancamentos where id=c1;
  perform t.ok('fin.cartao','compras no cartão penduradas na mesma fatura, total 430',
    (select fatura_id from fin.lancamentos where id=c2)=fat and (select valor_total from fin.faturas_cartao where id=fat)=430);
  pg := fin.pagar_fatura(fat, 'c_sv', 430, '2026-10-12', 'agente_financeiro');
  perform t.ok('fin.cartao','pagamento igual ao total marca fatura paga', (select status from fin.faturas_cartao where id=fat)='paga');

  -- reembolso: colaborador pagou 75 do bolso; empresa reembolsa
  orig := fin.registrar_lancamento('despesa','saida',75,'u_sv','2026-10-08','agente_financeiro','whatsapp',null,'deslocamento',
            'Colaborador',null,'Uber visita','2026-10-08','confirmado');
  rb := fin.registrar_reembolso(orig,'saida',75,'2026-10-10','c_sv','agente_financeiro');
  perform t.ok('fin.reembolso','reembolso fica ligado à despesa original', (select original_id from fin.lancamentos where id=rb)=orig);
  perform set_config('t.orig', orig::text, false);

  -- rateio: tarifa de sistema 99 (Anthropic) vira despesa ADM e é rateada entre SV e CPS
  perform set_config('t.c1', c1::text, false);
end $$;
select t.erro('fin.reembolso','reembolso acima da despesa original é recusado',
  $q$select fin.registrar_reembolso(current_setting('t.orig')::uuid,'saida',1,'2026-10-11','c_sv','t')$q$, 'excedem');

-- extrato: o que sobrou vira lançamento pelas regras; o que tem comprovante parecido vira pendência
do $$ declare r jsonb; begin
  r := fin.conciliar('c_sv', 'agente_financeiro');
  perform t.ok('fin.conciliacao','TED da transferência, fatura e reembolso conciliados por valor+data único',
    (select count(*) from fin.lancamentos where conta_id='c_sv' and status='conciliado'
       and natureza in ('transferencia_interna','pagamento_fatura','reembolso')) = 3, r::text);
  r := fin.lancar_do_extrato('c_sv', 'agente_financeiro');
  perform t.ok('fin.extrato','linhas com regra viram lançamentos classificados (Stone, tarifa, Anthropic)',
    (select count(*) from fin.lancamentos where origem='extrato' and conta_id='c_sv' and categoria_id in ('vendas_cartao','tarifas','ia')) = 3, r::text);
  perform t.ok('fin.datas','movimento de mesmo valor que comprovante fora da janela NÃO vira lançamento novo (evita duplicar)',
    exists (select 1 from fin.pendencias where tipo='ambiguidade' and (detalhe->>'valor')::numeric=180)
    and (select count(*) from fin.lancamentos where valor=180 and status <> 'cancelado') = 1);
  perform t.ok('fin.transferencia','PIX para outra unidade vira transferência entre unidades + pendência do par',
    exists (select 1 from fin.lancamentos where natureza='transferencia_unidades' and unidade_id='u_sv' and valor=1000)
    and exists (select 1 from fin.pendencias where tipo='transferencia_sem_par' and not material));
  perform t.ok('fin.pagamento_sem_comprovante','despesa paga sem comprovante (PIX sem regra) fica sem categoria + pendência',
    exists (select 1 from fin.pendencias where tipo='sem_classificacao'));
end $$;

do $$ declare a uuid; begin
  -- rateio da despesa de IA (99) entre SV 60 e CPS 40 → desbalanceado (100)
  select id into a from fin.lancamentos where categoria_id='ia' and origem='extrato';
  perform set_config('t.ia', a::text, false);
end $$;
select t.erro('fin.rateio','rateio que não fecha com o valor é recusado',
  $q$select fin.ratear(current_setting('t.ia')::uuid,'[{"unidade":"u_sv","valor":60},{"unidade":"u_cps","valor":40}]','teste','t')$q$, 'desbalanceado');
do $$ begin
  perform fin.ratear(current_setting('t.ia')::uuid,'[{"unidade":"u_sv","valor":59.40},{"unidade":"u_cps","valor":39.60}]','60/40 por faturamento','agente_financeiro');
  perform t.ok('fin.rateio','rateio redistribui a DRE entre as unidades',
    (select valor from fin.v_dre where unidade_id='u_cps' and categoria_id='ia') = 39.60
    and (select valor from fin.v_dre where unidade_id='u_sv' and categoria_id='ia') = 59.40);
  perform t.ok('fin.rateio','rateio não mexe no caixa (dinheiro saiu só de SV)',
    not exists (select 1 from fin.v_caixa_conta where conta_id='c_cps' and saidas = 39.60));
end $$;

select t.erro('fin.cancelamento','lançamento conciliado não pode ser cancelado',
  $q$select fin.cancelar_lancamento(current_setting('t.l_lab')::uuid,'erro','t')$q$, 'conciliado');
select t.erro('fin.cancelamento','lançamento não é apagado',
  $q$delete from fin.lancamentos where id = current_setting('t.l_sem')::uuid$q$, 'não são apagados');
select t.erro('fin.cancelamento','cancelar sem motivo é recusado',
  $q$update fin.lancamentos set status='cancelado' where id = current_setting('t.l_sem')::uuid$q$, 'motivo');

-- ---------------------------------------------------------------------------
-- E. Visões: DRE × caixa — nada contado duas vezes
-- ---------------------------------------------------------------------------
do $$ begin
  perform t.ok('fin.cartao','DRE conta as compras do cartão uma vez (300 + 130)',
    (select sum(valor) from fin.v_dre where unidade_id='u_sv' and categoria_id in ('sistemas','correios')) = 430);
  perform t.ok('fin.cartao','DRE não conta o pagamento da fatura',
    not exists (select 1 from fin.v_dre where natureza not in ('receita','despesa')));
  perform t.ok('fin.cartao','caixa conta só o pagamento da fatura (430), não as compras',
    (select sum(saidas) from fin.v_caixa_conta where conta_id='c_sv' and natureza='pagamento_fatura') = 430
    and not exists (select 1 from fin.v_caixa_conta where conta_id='c_cartao'));
  perform t.ok('fin.reembolso','DRE vê a despesa original (75) uma vez; caixa vê o reembolso (75)',
    (select sum(valor) from fin.v_dre where unidade_id='u_sv' and categoria_id='deslocamento') = 75
    and (select sum(saidas) from fin.v_caixa_conta where natureza='reembolso') = 75);
  perform t.ok('fin.transferencia','transferência interna fora da DRE e do caixa da unidade',
    not exists (select 1 from fin.v_dre where natureza like 'transfer%')
    and (select coalesce(sum(saidas),0) from fin.v_caixa_unidade where unidade_id='u_sv' and data='2026-10-09') = 0);
  perform t.ok('fin.transferencia','transferência entre unidades aparece no caixa da unidade e some no consolidado',
    (select saidas from fin.v_caixa_unidade where unidade_id='u_sv' and data='2026-10-07') = 1000
    and coalesce((select saidas from fin.v_caixa_consolidado where data='2026-10-07'),0) = 0);
  perform t.ok('fin.comprovante','comprovante sem pagamento confirmado não entra no caixa nem na DRE',
    (select status from fin.lancamentos where id=current_setting('t.l_sem')::uuid)='pendente'
    and not exists (select 1 from fin.v_dre where categoria_id='limpeza'));
  perform t.ok('fin.divergencia','lançamento contestado fora dos valores confirmados',
    not exists (select 1 from fin.v_dre where categoria_id='prestadores'));
end $$;

do $$ declare p uuid; begin
  p := fin.registrar_lancamento('despesa','saida',4000,'u_sv','2026-11-05','agente_financeiro','manual','c_sv','aluguel',
         'Locador',null,'Aluguel nov',  '2026-11-05','previsto', null, null, null, true);
  perform t.ok('fin.previsto','previsão aparece no previsto e não no realizado',
    exists (select 1 from fin.v_previsto where valor=4000) and not exists (select 1 from fin.v_dre where categoria_id='aluguel')
    and not exists (select 1 from fin.v_caixa_conta where saidas=4000));
end $$;

-- ---------------------------------------------------------------------------
-- F. Fechamento mensal
-- ---------------------------------------------------------------------------
do $$ declare f uuid; v jsonb; begin
  f := fin.preparar_fechamento('u_sv', '2026-10-01', 'agente_financeiro');
  perform t.ok('fin.fechamento','com pendências materiais o fechamento nasce BLOQUEADO',
    (select status from fin.fechamentos where id=f)='bloqueado' and (select pendencias_materiais from fin.fechamentos where id=f) > 0,
    (select pendencias_materiais::text from fin.fechamentos where id=f));
  perform t.ok('fin.fechamento','comprovante sem pagamento listado no pacote',
    exists (select 1 from fin.pendencias where tipo='comprovante_sem_pagamento' and lancamento_id=current_setting('t.l_sem')::uuid));
  perform set_config('t.f1', f::text, false);
end $$;
select t.erro('fin.fechamento','quem preparou não valida',
  $q$select fin.validar_fechamento(current_setting('t.f1')::uuid,'agente_financeiro')$q$, 'preparou');
select t.erro('fin.fechamento','fechamento bloqueado não pode ser aprovado',
  $q$select fin.decidir_fechamento(current_setting('t.f1')::uuid,'00000000-0000-0000-0000-0000000000f1',true,
       (select pacote_hash from fin.fechamentos where id=current_setting('t.f1')::uuid))$q$, 'validado');

-- resolução humana das pendências
do $$ declare m uuid; p record; begin
  -- 2 PIX de 50 à Maria: humano concilia 1 com o comprovante; o outro era um 2º pagamento sem comprovante
  select id into m from fin.movimentos where descricao='PIX ENVIADO MARIA' order by criado_em limit 1;
  perform fin.conciliar_manual(m, array[current_setting('t.l_mar')::uuid], '00000000-0000-0000-0000-0000000000f2', 'conferido com a Maria');
  select id into m from fin.movimentos where descricao='PIX ENVIADO MARIA' and status='pendente';
  perform fin.conciliar_manual(m, array[fin.registrar_lancamento('despesa','saida',50,'u_sv','2026-10-04','gerente','painel','c_sv','indique_ganhe','Maria',null,'2º indique',  '2026-10-04')],
    '00000000-0000-0000-0000-0000000000f2', 'segundo indique e ganhe');
  -- papelaria: data do comprovante estava errada; concilia manualmente
  select id into m from fin.movimentos where descricao='PIX ENVIADO PAPELARIA';
  perform fin.conciliar_manual(m, array[current_setting('t.l_pap')::uuid], '00000000-0000-0000-0000-0000000000f2', 'comprovante agendado, pago dia 28');
  -- Joao: o comprovante de 210 estava errado; cancela e lança o valor real do banco
  perform fin.cancelar_lancamento(current_setting('t.l_joao')::uuid, 'comprovante com valor errado; banco = 200', 'gerente');
  select id into m from fin.movimentos where documento_banco='E2E-JOAO-1';
  update fin.movimentos set status='pendente' where id = m;
  perform fin.conciliar_manual(m, array[fin.registrar_lancamento('despesa','saida',200,'u_sv','2026-10-06','gerente','painel','c_sv','prestadores','Joao Servicos',null,null,'2026-10-06')],
    '00000000-0000-0000-0000-0000000000f2', 'valor do extrato');
  -- extrato da conta de aplicação confirma a perna de entrada da transferência interna
  perform fin.importar_extrato('c_sv2', repeat('d',64), 'json',
    '[{"data":"2026-10-09","valor":500.00,"descricao":"TED RECEBIDA CONTA CORRENTE"}]'::jsonb, 'agente_financeiro', 0, 500);
  perform fin.conciliar('c_sv2', 'agente_financeiro');
  perform t.ok('fin.transferencia','extrato da conta destino concilia a perna de entrada da transferência interna',
    (select count(*) from fin.lancamentos where natureza='transferencia_interna' and status='conciliado') = 2);
  -- comprovante de 77 sem pagamento: não foi pago, cancela
  perform fin.cancelar_lancamento(current_setting('t.l_sem')::uuid, 'pagamento não realizado', 'gerente');
  -- classificar o PIX sem regra (despesa de 'outras')
  update fin.lancamentos set categoria_id='outras_despesas'
   where id in (select lancamento_id from fin.pendencias where tipo='sem_classificacao' and status='aberta');
  -- todas as pendências restantes de SV ficam resolvidas pela pessoa responsável
  update fin.pendencias set status='resolvida', resolvido_por='00000000-0000-0000-0000-0000000000f2',
    resolucao='revisado', resolvido_em=now() where unidade_id='u_sv' and status='aberta';
end $$;

do $$ declare f uuid; v jsonb; r text; h text; begin
  f := fin.preparar_fechamento('u_sv', '2026-10-01', 'agente_financeiro');
  perform t.ok('fin.fechamento','após resolver, o fechamento é preparado sem pendências materiais',
    (select status from fin.fechamentos where id=f)='preparado', (select pendencias_materiais::text from fin.fechamentos where id=f));
  perform t.ok('fin.fechamento','versão anterior marcada como reaberta (histórico preservado)',
    (select status from fin.fechamentos where id=current_setting('t.f1')::uuid)='reaberto');
  v := fin.validar_fechamento(f, 'validador_independente');
  perform t.ok('fin.validacao','validador recalcula pelo extrato e confere com o pacote', (v->>'ok')::boolean, v::text);
  perform t.ok('fin.validacao','caixa do pacote = movimentos do extrato (exceto transferência interna)',
    (select (pacote->>'caixa_saidas')::numeric from fin.fechamentos where id=f) =
    (select sum(valor) from fin.movimentos where conta_id='c_sv' and sentido='debito') - 500
    and (select (pacote->>'caixa_entradas')::numeric from fin.fechamentos where id=f) =
    (select sum(valor) from fin.movimentos where conta_id in ('c_sv','c_sv2') and sentido='credito') - 500);
  h := (select pacote_hash from fin.fechamentos where id=f);
  perform set_config('t.f2', f::text, false); perform set_config('t.h2', h, false);
end $$;
select t.erro('fin.fechamento','gerente (não diretoria) não aprova fechamento',
  $q$select fin.decidir_fechamento(current_setting('t.f2')::uuid,'00000000-0000-0000-0000-0000000000f2',true,current_setting('t.h2'))$q$, 'diretoria');
select t.erro('fin.fechamento','agente não aprova fechamento',
  $q$select fin.decidir_fechamento(current_setting('t.f2')::uuid,(select id from core.principais where agente_id='financeiro'),true,current_setting('t.h2'))$q$, 'diretoria');
select t.erro('fin.fechamento','aprovação presa ao pacote visto (hash diferente é recusado)',
  $q$select fin.decidir_fechamento(current_setting('t.f2')::uuid,'00000000-0000-0000-0000-0000000000f1',true,'abc')$q$, 'pacote mudou');
do $$ declare r text; begin
  r := fin.decidir_fechamento(current_setting('t.f2')::uuid,'00000000-0000-0000-0000-0000000000f1',true,current_setting('t.h2'));
  perform t.ok('fin.fechamento','diretoria aprova fechamento validado', r='aprovado', r);
end $$;
select t.erro('fin.fechamento','competência aprovada fica travada para novos lançamentos',
  $q$select fin.registrar_lancamento('despesa','saida',1,'u_sv','2026-10-15','t','manual','c_sv','tarifas')$q$, 'fechada');
select t.erro('fin.fechamento','não se prepara de novo competência aprovada',
  $q$select fin.preparar_fechamento('u_sv','2026-10-01','agente_financeiro')$q$, 'aprovada');
select t.ok('fin.fechamento','novembro continua aberto',
  (select fin.registrar_lancamento('despesa','saida',1,'u_sv','2026-11-02','t','manual','c_sv','tarifas')) is not null);

-- validador pega adulteração do pacote
do $$ declare f uuid; v jsonb; begin
  f := fin.preparar_fechamento('u_cps', '2026-10-01', 'agente_financeiro');
  update fin.pendencias set status='resolvida', resolvido_por='00000000-0000-0000-0000-0000000000f1', resolucao='ok', resolvido_em=now()
   where unidade_id='u_cps' and status='aberta';
  f := fin.preparar_fechamento('u_cps', '2026-10-01', 'agente_financeiro');
  update fin.fechamentos set pacote = jsonb_set(pacote, '{caixa_entradas}', '0') where id = f;
  v := fin.validar_fechamento(f, 'validador_independente');
  perform t.ok('fin.validacao','pacote adulterado é detectado e o fechamento fica bloqueado',
    not (v->>'ok')::boolean and (select status from fin.fechamentos where id=f)='bloqueado', v::text);
end $$;

-- ---------------------------------------------------------------------------
-- G. Auditoria e segurança do schema fin
-- ---------------------------------------------------------------------------
select t.ok('fin.auditoria','lançamentos, conciliações manuais e fechamento auditados',
  (select count(*) from core.auditoria where entidade='fin.lancamento') > 20
  and exists (select 1 from core.auditoria where acao='conciliacao_manual')
  and exists (select 1 from core.auditoria where acao='fechamento_aprovado'));
select t.ok('fin.auditoria','cadeia de auditoria íntegra após tudo', core.verificar_auditoria() is null);
set role anon;
select t.erro('fin.seguranca','anon não lê fin.lancamentos', $q$select * from fin.lancamentos$q$, 'permission');
reset role;
select t.ok('fin.seguranca','RLS forçado em todas as tabelas do fin',
  not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
              where n.nspname='fin' and c.relkind='r' and not (c.relrowsecurity and c.relforcerowsecurity)));
select t.ok('fin.seguranca','toda função SECURITY DEFINER do fin tem search_path fixo',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='fin' and (p.prosecdef or p.prorettype = 'trigger'::regtype)
                and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')));

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe
from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin
  if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES FINANCEIROS FALHANDO'; end if;
end $$;
