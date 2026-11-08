-- Agente no WhatsApp direto com a diretoria (dados sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
update core.config set valor = 'false' where chave = 'wa.ativo';
delete from wa.mensagens;
create or replace function t.zapi(p_tel text, p_id text, p_texto text, p_grupo boolean default false) returns jsonb language sql as $$
  select jsonb_build_object('type', 'ReceivedCallback', 'isGroup', p_grupo, 'fromMe', false, 'phone', p_tel, 'messageId', p_id, 'text', jsonb_build_object('message', p_texto)) $$;

select t.ok('wa','canal desligado: nada é tratado', wa.receber(t.zapi('5513999996001', 'W1', 'oi'))->>'acao' = 'ignorar');
update core.config set valor = 'true' where chave = 'wa.ativo';
select t.ok('wa','grupo é só repasse', wa.receber(t.zapi('120363000000000000', 'W2', 'oi', true))->>'acao' = 'ignorar');
select t.ok('wa','número de fora é ignorado', wa.receber(t.zapi('5511900000000', 'W3', 'oi'))->>'motivo' = 'número não autorizado');
select t.ok('wa','gerente (sem papel de diretoria) é ignorado', wa.receber(t.zapi('5513999996002', 'W4', 'oi'))->>'acao' = 'ignorar');
select set_config('t.w', wa.receber(t.zapi('5513999996001', 'W5', 'o caixa de ontem bateu?'))::text, false);
select t.ok('wa','admin no privado é tratado, com nome e lojas', current_setting('t.w')::jsonb->>'acao' = 'tratar'
  and current_setting('t.w')::jsonb->>'nome' = 'Admin Painel' and jsonb_array_length(current_setting('t.w')::jsonb->'unidades') > 0);
select t.ok('wa','mensagem repetida da Z-API não é tratada de novo', wa.receber(t.zapi('5513999996001', 'W5', 'o caixa de ontem bateu?'))->>'motivo' = 'repetida');

select wa.responder((current_setting('t.w')::jsonb->>'id')::bigint, 'Bateu sim.');
select t.ok('wa','resposta vai para a fila', jsonb_array_length(wa.fila()) = 1 and wa.fila()->0->>'texto' = 'Bateu sim.');
select wa.marcar_envio((wa.fila()->0->>'id')::bigint, true);
select t.ok('wa','enviada sai da fila', jsonb_array_length(wa.fila()) = 0);

-- arquivo
select set_config('t.a', wa.receber(jsonb_build_object('type','ReceivedCallback','isGroup',false,'fromMe',false,'phone','5513999996001','messageId','W6',
  'document', jsonb_build_object('documentUrl','https://storage.z-api.io/x.pdf','fileName','extrato.pdf','mimeType','application/pdf','caption','extrato p_a')))::text, false);
select t.ok('wa','documento chega como arquivo', current_setting('t.a')::jsonb->>'tipo' = 'documento' and current_setting('t.a')::jsonb->'arquivo'->>'nome' = 'extrato.pdf');
select set_config('t.e', wa.envio_iniciar((current_setting('t.a')::jsonb->>'id')::bigint, 'p_a', 'extrato.pdf', 'application/pdf', 1000, repeat('a', 64))::text, false);
select t.ok('wa','arquivo vira envio da loja, pela pessoa', exists (select 1 from fin.envios e where e.id = (current_setting('t.e')::jsonb->>'id')::uuid
  and e.unidade_id = 'p_a' and e.enviado_por = '00000000-0000-0000-0000-0000000060a1' and e.status = 'aguardando_arquivo'));
update fin.envios set status = 'conferir', checagens = '{"itens": 12}' where id = (current_setting('t.e')::jsonb->>'id')::uuid;
select wa.preparar_avisos();
select t.ok('wa','quando a leitura termina, a pessoa recebe o retorno', exists (select 1 from wa.mensagens where direcao = 'saida' and origem = 'arquivo'
  and texto like 'Li o arquivo extrato.pdf%12 linha(s)%'));
select wa.preparar_avisos();
select t.ok('wa','retorno do arquivo não repete', (select count(*) from wa.mensagens where origem = 'arquivo') = 1);
delete from fin.envios where id = (current_setting('t.e')::jsonb->>'id')::uuid;

-- urgências
update core.config set valor = 'true' where chave = 'wa.urgencias';
update core.config set valor = (now() - interval '1 minute')::text where chave = 'wa.urgencias_desde';
insert into cx.alertas (tipo, referencia, unidade_id, dia, detalhe) values
  ('nao_encontrado', 'wa-teste', 'p_a', current_date - 2, '{"rotulo":"Pix","valor":150,"quantidade":1,"fonte":"banco"}');
select wa.preparar_avisos();
select t.ok('wa','urgência nova vira mensagem para a diretoria (valor em reais)', exists (select 1 from wa.mensagens where origem = 'urgencia' and telefone = '5513999996001'
  and texto like '%Pix de R$ 150,00 não achado no extrato%'), (select string_agg(telefone, ',') from wa.mensagens where origem = 'urgencia'));
select set_config('t.nu', (select count(*) from wa.mensagens where origem = 'urgencia')::text, false);
select wa.preparar_avisos();
select t.ok('wa','a mesma urgência não é avisada duas vezes', (select count(*) from wa.mensagens where origem = 'urgencia') = current_setting('t.nu')::int);

-- conversa sobre o aviso
select wa.aviso_conversar((current_setting('t.w')::jsonb->>'id')::bigint, 'nao_encontrado', 'wa-teste', 'esse Pix caiu na conta da outra loja', 'Confirmado no extrato de p_b.', true);
select t.ok('wa','conversa pelo WhatsApp fica no aviso e pode explicar', (select count(*) from core.avisos_conversa where referencia = 'wa-teste') = 2
  and exists (select 1 from cx.alertas where referencia = 'wa-teste' and status = 'explicado'));
delete from core.avisos_conversa where referencia = 'wa-teste'; delete from cx.alertas where referencia = 'wa-teste';

-- consulta só de leitura
do $$ declare ok1 boolean := true; ok2 boolean := false; ok3 boolean := false; begin
  set local role wa_leitura;
  begin perform count(*) from cx.dias; exception when others then ok1 := false; end;
  begin delete from cx.alertas where false; exception when insufficient_privilege then ok2 := true; end;
  begin perform count(*) from multi.capturas; exception when insufficient_privilege then ok3 := true; end;
  reset role;
  perform t.ok('wa','papel de leitura lê o caixa', ok1);
  perform t.ok('wa','papel de leitura não altera nada', ok2);
  perform t.ok('wa','papel de leitura não vê CPF cru do Multicrediário', ok3);
end $$;

-- garantia de execução (08/11)
select t.ok('saude','saúde lista agentes e robôs com o combinado', (select count(*) from core.saude()) >= 15
  and exists (select 1 from core.saude() where id = 'robo_multicrediario') and exists (select 1 from core.saude() where id = 'avisos_conversa'));
insert into cx.alertas (tipo, referencia, unidade_id, dia, detalhe) values ('caixa_inconsistente', 'saude-x', 'p_a', current_date - 1, '{"caixa":1,"soma_formas":2}');
insert into core.avisos_conversa (area, tipo, referencia, unidade_id, papel, autor_nome, texto) values ('caixa', 'caixa_inconsistente', 'saude-x', 'p_a', 'pessoa', 'Teste', 'entrou duplicado');
select t.ok('saude','mensagem do painel é pega uma vez só (sem resposta dobrada)',
  jsonb_array_length(public.agente_avisos_pegar(10)) = 1 and jsonb_array_length(public.agente_avisos_pegar(10)) = 0);
update core.avisos_conversa set criado_em = now() - interval '2 hours' where referencia = 'saude-x';
select t.ok('saude','mensagem sem resposta há mais de 30 min fica atrasada', (select atrasado from core.saude() where id = 'avisos_conversa'));
delete from core.avisos_conversa where referencia = 'saude-x'; delete from cx.alertas where referencia = 'saude-x';
do $$ declare ok1 boolean := false; begin
  set local role wa_leitura;
  ok1 := (select count(*) from cx.dias) = (select count(*) from cx.dias);  -- lê sem erro
  reset role;
  perform t.ok('saude','leitura do WhatsApp enxerga as linhas mesmo com RLS', (select rolbypassrls from pg_roles where rolname = 'wa_leitura') and ok1);
end $$;

update core.config set valor = 'false' where chave in ('wa.ativo', 'wa.urgencias');
delete from wa.mensagens;
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),200) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DO WHATSAPP FALHANDO'; end if; end $$;
