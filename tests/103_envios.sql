-- Central de envio de arquivos (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into core.unidades (id, nome) values ('env_a','Loja Envio'), ('env_b','Loja Outra') on conflict (id) do nothing;
insert into fin.contas (id, apelido, tipo, unidade_id, instituicao, final_numero) values
  ('env_cc', 'Sicredi Envio', 'corrente', 'env_a', 'sicredi', '74992'),
  ('env_cart', 'Cartão Envio', 'cartao_credito', 'env_a', 'sicredi', '1234'),
  ('env_cc_b', 'Conta Outra Loja', 'corrente', 'env_b', 'sicredi', '11111') on conflict (id) do nothing;

select t.ok('travas','leitura nasce desligada: nada entra na fila', core.cfg('fin.envios.ativo') = 'false' and fin.agendar_envios() = 0);
select t.ok('travas','agente nunca lança o que a IA leu sem pessoa; nem apaga arquivo',
  (select bool_and((core.autorizar(p.id, 'fin.envio', op, null)).categoria = 'proibida') from core.principais p,
     unnest(array['lancar_sem_confirmacao','excluir_arquivo']) op where p.agente_id = 'financeiro'));

create function t.h64(s text) returns text language sql as $$ select encode(sha256(convert_to(s, 'UTF8')), 'hex') $$;
create function t.ini(nome text, tipo text, conta text, chave text, tam int default 1000, loja text default 'env_a') returns jsonb language sql as $$
  select public.painel_envio_iniciar(loja, tipo, conta, nome, 'application/octet-stream', tam, t.h64(chave)) $$;

set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.erro('validacao','formato não aceito (.exe) é recusado', $$select t.ini('virus.exe', 'auto', null, 'x1')$$, 'formato não aceito');
select t.erro('validacao','arquivo acima de 20 MB é recusado', $$select t.ini('grande.pdf', 'auto', null, 'x2', 30000000)$$, '20 MB');
select t.erro('validacao','conta de outra loja é recusada', $$select t.ini('extrato.ofx', 'extrato', 'env_cc_b', 'x3')$$, 'não é desta loja');
select set_config('t.e1', t.ini('extrato_sicredi.ofx', 'extrato', null, 'ofx-1')::text, false);
select set_config('t.e2', t.ini('extrato_ia.pdf', 'extrato', null, 'pdf-1')::text, false);
select set_config('t.e3', t.ini('fatura_out.pdf', 'fatura', 'env_cart', 'fat-1')::text, false);
select set_config('t.e4', t.ini('fatura_errada.pdf', 'fatura', 'env_cart', 'fat-2')::text, false);
select set_config('t.e5', t.ini('stone_semana.csv', 'stone', null, 'stone-1')::text, false);
select set_config('t.e6', t.ini('comprovante.jpg', 'comprovante', null, 'comp-1')::text, false);
select set_config('t.e7', t.ini('extrato_ia2.pdf', 'extrato', null, 'pdf-2')::text, false);
select t.ok('envio','caminho do arquivo é da loja e do mês, com o id do envio', current_setting('t.e1')::jsonb->>'caminho' like 'env_a/____-__/%.ofx'
  and (current_setting('t.e1')::jsonb->>'duplicado')::boolean is false);
select set_config('t.dup', t.ini('copia.ofx', 'extrato', null, 'ofx-1')::text, false);
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('seguranca','gerente sem permissão de envio não envia', $$select t.ini('x.pdf', 'auto', null, 'x9', 1000, 'p_b')$$, 'sem permissão');
reset role;
select t.sem_jwt();
set role anon;
select t.erro('seguranca','anon não envia', $$select public.painel_envio_iniciar('env_a','auto',null,'a.pdf','x',10,repeat('a',64))$$, 'permission');
reset role;

select t.ok('envio','mesmo arquivo de novo na mesma loja: avisa que já foi enviado e não cria outro',
  (current_setting('t.dup')::jsonb->>'duplicado')::boolean and (select count(*) from fin.envios where sha256 = t.h64('ofx-1')) = 1);
create function t.id(k text) returns uuid language sql as $$ select (current_setting(k)::jsonb->>'id')::uuid $$;
select t.ok('envio','arquivo gravado com hash diferente do anunciado: erro (não segue)',
  fin.envio_arquivo_recebido(t.id('t.e7'), 1000, t.h64('outro')) = 'erro');
select fin.envio_arquivo_recebido(t.id(k), 1000, t.h64(c)) from (values ('t.e1','ofx-1'), ('t.e2','pdf-1'), ('t.e3','fat-1'), ('t.e4','fat-2'),
  ('t.e5','stone-1'), ('t.e6','comp-1')) v(k, c);
select t.ok('envio','com a leitura desligada os arquivos ficam guardados na fila', (select count(*) from fin.envios where unidade_id = 'env_a' and status = 'recebido') = 6);

-- liga a leitura (só no teste)
update core.agentes set status = 'ativo' where id = 'financeiro';
update core.config set valor = 'true' where chave = 'fin.envios.ativo';
select t.ok('fila','agendou uma leitura por arquivo', fin.agendar_envios() = 6 and fin.agendar_envios() = 0);

create function t.ler(k text, leitura jsonb, validar boolean default true) returns jsonb language plpgsql as $$
declare v_t uuid := (select tarefa_id from fin.envios where id = t.id(k)); v jsonb; r record;
begin
  update core.tarefas set prioridade = 1 where id = v_t;
  for r in select * from core.reivindicar('financeiro', 'fin-envios-worker', 120) loop
    if r.id <> v_t then raise exception 'reivindicou outra tarefa'; end if;
  end loop;
  v := fin.envio_registrar_leitura(v_t, 'fin-envios-worker', leitura);
  if validar then v := v || jsonb_build_object('validacao', fin.validar_envio(v_t, 'validador_sql')); end if;
  return v;
end $$;

-- OFX do extrato: conta reconhecida pelo número, saldo fecha → lançado sozinho
select set_config('t.l1', t.ler('t.e1', jsonb_build_object('tipo','extrato','formato','ofx','conta_numero','0000074992-1',
  'saldo_inicial', 1000, 'saldo_final', 1150, 'linhas', jsonb_build_array(
    jsonb_build_object('data', current_date - 1, 'valor', 200, 'descricao', 'PIX RECEBIDO', 'documento', 'FIT1'),
    jsonb_build_object('data', current_date - 1, 'valor', -50, 'descricao', 'TARIFA', 'documento', 'FIT2'))))::text, false);
select t.ok('ofx','OFX com conta reconhecida e saldo fechando: lançado sem intervenção', current_setting('t.l1')::jsonb->>'status' = 'lancado'
  and (select conta_id = 'env_cc' from fin.envios where id = t.id('t.e1'))
  and exists (select 1 from fin.importacoes where conta_id = 'env_cc' and arquivo_sha256 = t.h64('ofx-1') and linhas = 2), current_setting('t.l1'));
select t.ok('ofx','conferente independente aprovou', current_setting('t.l1')::jsonb->>'validacao' = 'concluida');

-- extrato em PDF lido pela IA: fica para conferir; pessoa confirma escolhendo a conta
select set_config('t.l2', t.ler('t.e2', jsonb_build_object('tipo','extrato','formato','ia','saldo_inicial', 500, 'saldo_final', 470,
  'linhas', jsonb_build_array(jsonb_build_object('data', current_date - 3, 'valor', -30, 'descricao', 'BOLETO LUZ'))))::text, false);
select t.ok('ia','extrato em PDF: fecha, mas fica para conferir (IA não lança sozinha)', current_setting('t.l2')::jsonb->>'status' = 'conferir'
  and (current_setting('t.l2')::jsonb->'checagens'->>'ok')::boolean and current_setting('t.l2')::jsonb->>'validacao' = 'concluida');

-- fatura que fecha (compras - estorno = total) e fatura que não fecha
select t.ler('t.e3', jsonb_build_object('tipo','fatura','formato','ia','total', 130, 'compras', jsonb_build_array(
  jsonb_build_object('data', current_date - 20, 'descricao', 'POSTO SHELL', 'valor', 100, 'categoria', 'laboratorio'),
  jsonb_build_object('data', current_date - 15, 'descricao', 'LOJA DESCONHECIDA XYZ', 'valor', 50, 'parcela', '1/3'),
  jsonb_build_object('data', current_date - 10, 'descricao', 'ESTORNO', 'valor', -20))));
select t.ler('t.e4', jsonb_build_object('tipo','fatura','formato','ia','total', 999, 'compras', jsonb_build_array(
  jsonb_build_object('data', current_date - 20, 'descricao', 'ALGO', 'valor', 100))));
select t.ok('ia','fatura que não fecha: aviso com a diferença', (select checagens->>'ok' = 'false' and checagens->'avisos'->>0 like '%não bate com o total%'
  from fin.envios where id = t.id('t.e4')));
select t.ler('t.e5', jsonb_build_object('tipo','stone','formato','ia','total_bruto', 300, 'transacoes', jsonb_build_array(
  jsonb_build_object('id','stn1','data', current_date - 1, 'forma','credito','valor', 200),
  jsonb_build_object('id','stn2','data', current_date - 1, 'forma','debito','valor', 100))));
select t.ler('t.e6', jsonb_build_object('tipo','comprovante','formato','ia','itens', jsonb_build_array(
  jsonb_build_object('valor', 87.5, 'data', current_date - 2, 'favorecido', 'FORNECEDOR TESTE', 'id_transacao', 'E2E123'))));


-- confirmações (pessoa)
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.erro('confirmar','extrato da IA sem conta escolhida: pede a conta', format('select public.painel_envio_confirmar(%L)', t.id('t.e2')), 'escolha a conta');
select t.erro('confirmar','extrato não aceita conta de cartão', format('select public.painel_envio_confirmar(%L, %L)', t.id('t.e2'), 'env_cart'), 'escolha a conta');
select t.ok('confirmar','extrato confirmado com a conta: importado', (public.painel_envio_confirmar(t.id('t.e2'), 'env_cc')->>'status') = 'lancado');
select t.erro('confirmar','fatura que não fecha não pode ser confirmada', format('select public.painel_envio_confirmar(%L)', t.id('t.e4')), 'não fecham');
select public.painel_envio_descartar(t.id('t.e4'), 'arquivo cortado, vou mandar de novo');
select set_config('t.c3', public.painel_envio_confirmar(t.id('t.e3'), null, '{}')::text, false);
select set_config('t.c5', public.painel_envio_confirmar(t.id('t.e5'))::text, false);
select set_config('t.c6', public.painel_envio_confirmar(t.id('t.e6'))::text, false);
select set_config('t.pe', public.painel_envios('env_a')::text, false);
reset role;
select t.sem_jwt();
select t.ok('confirmar','extrato em PDF entrou como importação da conta', exists (select 1 from fin.importacoes where conta_id = 'env_cc' and arquivo_sha256 = t.h64('pdf-1') and formato = 'ia'));
select t.ok('fatura','2 compras lançadas no cartão (estorno fora), penduradas na fatura; sem categoria vira pendência',
  (current_setting('t.c3')::jsonb->'resultado'->>'compras')::int = 2
  and (select count(*) from fin.lancamentos where conta_id = 'env_cart' and fatura_id is not null and status <> 'cancelado') = 2
  and (current_setting('t.c3')::jsonb->'resultado'->>'sem_categoria')::int >= 1, current_setting('t.c3'));
select t.ok('stone','Stone: 2 vendas no caixa da loja e cobertura até ontem', (select count(*) from cx.recebimentos where fonte = 'stone' and unidade_id = 'env_a') = 2
  and (select ate from cx.cobertura where fonte = 'stone' and unidade_id = 'env_a') = current_date - 1);
select t.ok('comprovante','comprovante vira documento do painel + lançamento de saída', exists (select 1 from fin.documentos where origem = 'painel' and sha256 = t.h64('comp-1'))
  and (current_setting('t.c6')::jsonb->'resultado'->>'lancamentos')::int = 1);
select t.ok('painel','lista mostra os envios com situação e quem enviou; descartado com motivo',
  jsonb_array_length(current_setting('t.pe')::jsonb->'envios') >= 7
  and exists (select 1 from jsonb_array_elements(current_setting('t.pe')::jsonb->'envios') x where x->>'status' = 'descartado' and x->>'motivo' like 'arquivo cortado%'));
select t.ok('auditoria','confirmação e descarte ficam na auditoria', exists (select 1 from core.auditoria where acao = 'envio_confirmado')
  and exists (select 1 from core.auditoria where acao = 'envio_descartado'));

-- validador: IA lançada por fora → reprova
update core.config set valor = 'true' where chave = 'fin.envios.ativo';
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.e9', t.ini('extrato_ia3.pdf', 'extrato', 'env_cc', 'pdf-3')::text, false);
reset role;
select t.sem_jwt();
select fin.envio_arquivo_recebido(t.id('t.e9'), 1000, t.h64('pdf-3'));
select fin.agendar_envios();
select t.ler('t.e9', jsonb_build_object('tipo','extrato','formato','ia','linhas', jsonb_build_array(
  jsonb_build_object('data', current_date - 1, 'valor', -10, 'descricao', 'X'))), false);
update fin.envios set status = 'lancado' where id = t.id('t.e9');
select t.ok('validador','documento da IA marcado como lançado sem pessoa: conferente reprova',
  (select fin.validar_envio(tarefa_id, 'validador_sql') from fin.envios where id = t.id('t.e9')) = 'bloqueada');

-- pagamento da fatura anterior não entra na soma (achado no 1º PDF real, 28/10)
select t.ok('fatura','compras somam o total; linha de pagamento da fatura anterior fica fora e a conta fecha',
  (fin._checar_leitura('fatura', jsonb_build_object('total', 4165.55, 'compras', jsonb_build_array(
     jsonb_build_object('data','2026-09-13','descricao','Apple Com/bill','valor', 799.90),
     jsonb_build_object('data','2026-10-05','descricao','Mercadolivre','valor', 3365.65),
     jsonb_build_object('data','2026-09-25','descricao','Pagamento 030932721','valor', -2685.93)))))->>'ok' = 'true');
select t.ok('fatura','estorno de compra continua contando (não é pagamento)',
  (fin._checar_leitura('fatura', jsonb_build_object('total', 100, 'compras', jsonb_build_array(
     jsonb_build_object('data','2026-09-13','descricao','Loja X','valor', 130),
     jsonb_build_object('data','2026-09-20','descricao','Estorno Loja X','valor', -30)))))->>'ok' = 'true');

-- arquivos esperados: o que não chegou aparece (e o Supervisor cobra)
insert into fin.arquivos_esperados (unidade_id, tipo, conta_id, frequencia, dia_limite, hora_limite, dias) values
  ('env_a', 'extrato', 'env_cc', 'diaria', null, 0, '1,2,3,4,5,6,7'),
  ('env_a', 'fatura', 'env_cart', 'mensal', 1, 0, '1,2,3,4,5'),
  ('env_b', 'stone', null, 'semanal', 1, 0, '1,2,3,4,5'),
  ('env_b', 'extrato', 'env_cc_b', 'semanal', 1, 0, '1,2,3,4,5');
select t.ok('esperados','extrato de ontem chegou (OFX): não cobra; Stone da outra loja não chegou: cobra',
  not exists (select 1 from fin.arquivos_faltando() where unidade_id = 'env_a' and tipo = 'extrato')
  and exists (select 1 from fin.arquivos_faltando() where unidade_id = 'env_b' and tipo = 'stone' and descricao like 'Relatório da Stone (Loja Outra): falta o da semana%'));
-- conta sem envio na semana: confere as importações daquela conta (achado na instalação, 28/10: nome de coluna ambíguo)
select t.ok('esperados','extrato semanal de conta sem nenhum envio nem importação: cobra',
  exists (select 1 from fin.arquivos_faltando() where unidade_id = 'env_b' and tipo = 'extrato' and conta_id = 'env_cc_b'));
update core.agentes set status = 'ativo' where id = 'supervisor';
update core.config set valor = 'true' where chave = 'sup.sync.ativo';
select t.sup();
select t.ok('esperados','Supervisor transforma o arquivo que faltou em aviso de atenção (vai no resumo)',
  exists (select 1 from sup.achados where status = 'aberto' and tipo = 'arquivo_faltando' and severidade = 'media' and titulo like 'Relatório da Stone%'));
update core.agentes set status = 'pausado' where id in ('supervisor', 'financeiro');
update core.config set valor = 'false' where chave in ('sup.sync.ativo', 'fin.envios.ativo');
update sup.achados set status = 'resolvido', resolvido_em = now() where status = 'aberto';
delete from fin.arquivos_esperados where unidade_id in ('env_a','env_b');

select t.ok('auditoria','cadeia íntegra', core.verificar_auditoria() is null);

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DA CENTRAL DE ENVIO FALHANDO'; end if; end $$;
