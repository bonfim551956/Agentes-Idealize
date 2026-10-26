-- Regras de conciliação por documento (formato real do OFX Sicredi, dados sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;

insert into core.unidades (id, nome) values ('u_doc','Unidade Doc');
insert into fin.contas (id, apelido, tipo, unidade_id) values ('c_doc','Conta Doc','corrente','u_doc');

do $$ declare a uuid; b uuid; c uuid; d uuid; e uuid; r jsonb; begin
  perform fin.importar_extrato('c_doc', repeat('9',64), 'json', '[
    {"data":"2026-10-01","valor":-3500.00,"descricao":"PAGAMENTO PIX-CX111111 11111111111 SOCIO UM","documento":"F1"},
    {"data":"2026-10-01","valor":-3500.00,"descricao":"PAGAMENTO PIX-PIX_DEB 22222222222 SOCIO DOIS","documento":"F2"},
    {"data":"2026-10-02","valor":-210.87,"descricao":"LIQUIDACAO BOLETO- 33333333000133 LAB TESTE SA","documento":"F3"},
    {"data":"2026-10-03","valor":-120.00,"descricao":"PAGAMENTO PIX-PIX_DEB 44444444444 PRESTADOR","documento":"F4"},
    {"data":"2026-10-04","valor":-80.00,"descricao":"PAGAMENTO PIX-PIX_DEB 55555555555 FULANO","documento":"F5"},
    {"data":"2026-10-04","valor":-80.00,"descricao":"PAGAMENTO PIX-PIX_DEB 66666666666 CICLANO","documento":"F6"}
  ]'::jsonb, 'agente_financeiro');
  -- dois pró-labores de mesmo valor e dia: só o documento separa
  a := fin.registrar_lancamento('despesa','saida',3500,'u_doc','2026-10-01','t','whatsapp',null,'pro_labore','Socio Um','111.111.111-11',null,'2026-10-01','pendente','CX111111');
  b := fin.registrar_lancamento('despesa','saida',3500,'u_doc','2026-10-01','t','whatsapp',null,'pro_labore','Socio Dois','22222222222',null,'2026-10-01');
  c := fin.registrar_lancamento('despesa','saida',210.87,'u_doc','2026-10-01','t','whatsapp',null,'laboratorio','Lab Teste','33.333.333/0001-33',null,'2026-10-01');
  d := fin.registrar_lancamento('despesa','saida',125,'u_doc','2026-10-03','t','whatsapp',null,'prestadores','Prestador','44444444444',null,'2026-10-03');
  e := fin.registrar_lancamento('despesa','saida',80,'u_doc','2026-10-04','t','whatsapp',null,'indique_ganhe','Fulano',null,null,'2026-10-04');
  r := fin.conciliar('c_doc','agente_financeiro');
  perform t.ok('doc','código do comprovante na descrição concilia (R1b)', (select regra from fin.conciliacoes where lancamento_id=a)='id_na_descricao', r::text);
  perform t.ok('doc','2º pró-labore de mesmo valor/dia concilia pelo CPF (R1c), sem ambiguidade',
    (select regra from fin.conciliacoes where lancamento_id=b)='documento_contraparte'
    and (select m.descricao from fin.conciliacoes x join fin.movimentos m on m.id=x.movimento_id where x.lancamento_id=b) like '%22222222222%');
  perform t.ok('doc','CNPJ com máscara no comprovante concilia com o CNPJ cru do boleto (R1c)', (select regra from fin.conciliacoes where lancamento_id=c)='documento_contraparte');
  perform t.ok('doc','mesmo CPF e dia com valor diferente: pendência de divergência, nada conciliado',
    (select status from fin.lancamentos where id=d)='pendente'
    and exists (select 1 from fin.pendencias where tipo='divergencia' and lancamento_id=d and detalhe->>'prova'='documento_contraparte'));
  perform t.ok('doc','sem documento e 2 PIX iguais no dia: continua ambíguo (não chuta)',
    (select status from fin.lancamentos where id=e)='pendente'
    and exists (select 1 from fin.pendencias where tipo='ambiguidade' and (detalhe->>'valor')::numeric=80));
end $$;
select t.ok('doc','documento só casa como token isolado (não por pedaço de outro número)',
  not fin.doc_na_descricao('1111111', 'PIX 911111119 X') and fin.doc_na_descricao('CX111111','PAGAMENTO PIX-CX111111 1'));

-- regressão da homologação: E2E no comprovante × FITID no OFX não são IDs comparáveis
do $$ declare a uuid; b uuid; r jsonb; begin
  perform fin.importar_extrato('c_doc', repeat('8',64), 'json', '[
    {"data":"2026-10-21","valor":-55.00,"descricao":"PAGAMENTO PIX-PIX_DEB 77777777777 COLABORADORA","documento":"23999000001"}
  ]'::jsonb, 'agente_financeiro');
  a := fin.registrar_lancamento('despesa','saida',55,'u_doc','2026-10-21','t','whatsapp',null,'folha','Colaboradora',null,null,'2026-10-21','pendente','E8111514920261022000254EGZYBo3MY');
  r := fin.conciliar('c_doc','agente_financeiro');
  perform t.ok('doc','E2E do comprovante e FITID do banco não bloqueiam o par único (regressão homologação)',
    (select regra from fin.conciliacoes where lancamento_id=a)='valor_data_unico', r::text);
end $$;
select t.ok('doc','dois E2E diferentes continuam sendo conflito',
  fin.ids_conflitam('E8111514920261022000254EGZYBo3MY','E8111514920261022000999XXXXXXXXX')
  and not fin.ids_conflitam('E8111514920261022000254EGZYBo3MY','23999000001') and not fin.ids_conflitam(null,'x'));

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DE DOCUMENTO FALHANDO'; end if; end $$;
