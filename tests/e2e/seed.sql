insert into core.unidades (id,nome) values ('u_e2e','E2E');
insert into fin.grupos_whatsapp (chat_id, unidade_id) values ('120000000000000777-group','u_e2e');
insert into core.principais (id,tipo,nome,telefone) values ('00000000-0000-0000-0000-00000000e2e1','usuario','Admin E2E','5513999997777');
insert into core.principal_papeis (principal_id,papel_id) values ('00000000-0000-0000-0000-00000000e2e1','admin'),('00000000-0000-0000-0000-00000000e2e1','diretoria');
select core.politica_definir('00000000-0000-0000-0000-00000000e2e1','agente_financeiro','fin.lancamento','registrar_comprovante','automatica','baixo');
insert into fin.regras_classificacao (padrao,sentido,natureza,categoria_id,prioridade,responsavel) values ('12345678000199','debito','despesa','laboratorio',30,'e2e');
