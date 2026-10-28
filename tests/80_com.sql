-- Agente Comercial / Kommo (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into core.unidades (id, nome) values ('campinas','Campinas'), ('sorocaba','Sorocaba') on conflict (id) do nothing;

-- A. Travas e privacidade
select t.ok('travas','agente nasce pausado', (select status from core.agentes where id = 'comercial') = 'pausado');
select t.ok('travas','sincronização nasce desligada', core.cfg('com.sync.ativo') = 'false' and com.agendar_sincronizacao() is null);
select t.ok('travas','proibido enviar mensagem, alterar, criar ou excluir na Kommo',
  (select bool_and((core.autorizar(p.id, 'com.kommo', op, null)).categoria = 'proibida')
   from core.principais p, unnest(array['enviar_mensagem','alterar_lead','criar_lead','excluir']) op where p.agente_id = 'comercial'));
select t.ok('privacidade','mensagens não têm coluna de texto', not exists (select 1 from information_schema.columns
  where table_schema = 'com' and table_name = 'mensagens' and column_name in ('texto','text','mensagem','conteudo','message')));
select t.ok('privacidade','leads não têm nome, telefone ou e-mail', not exists (select 1 from information_schema.columns
  where table_schema = 'com' and table_name = 'leads' and column_name in ('nome','name','telefone','phone','email','contato')));

update core.agentes set status = 'ativo' where id = 'comercial';
update core.config set valor = 'true' where chave = 'com.sync.ativo';

create function t.ep(i interval) returns bigint language sql as $$ select floor(extract(epoch from date_trunc('minute', now()) - i))::bigint $$;
create function t.lote_com(extra_eventos jsonb default '[]') returns jsonb language sql as $$
  select jsonb_build_object('desde', t.ep('3 days'), 'ate', t.ep('0 min'),
    'usuarios', jsonb_build_array(jsonb_build_object('id',1,'nome','Atendente A','ativo',true,'email','a@x.com'),
                                  jsonb_build_object('id',2,'nome','Atendente B','ativo',true)),
    'funis', jsonb_build_array(
      jsonb_build_object('id',10,'nome','Funil Campinas','etapas', jsonb_build_array(
        jsonb_build_object('id',1,'nome','Entrada','tipo','entrada','ordem',0), jsonb_build_object('id',2,'nome','Em contato','tipo','aberta','ordem',1),
        jsonb_build_object('id',142,'nome','Venda ganha','tipo','ganha','ordem',9), jsonb_build_object('id',143,'nome','Venda perdida','tipo','perdida','ordem',10))),
      jsonb_build_object('id',20,'nome','Funil Sorocaba','etapas', jsonb_build_array(
        jsonb_build_object('id',2,'nome','Em contato','tipo','aberta','ordem',1), jsonb_build_object('id',142,'nome','Venda ganha','tipo','ganha','ordem',9)))),
    'leads', jsonb_build_array(
      jsonb_build_object('id',100,'funil_id',10,'etapa_id',2,'responsavel_id',1,'valor',0,'criado_em',t.ep('2 days'),'atualizado_em',t.ep('1 hour'),
                         'nome','Cliente Fulano','telefone','5519999990000'),
      jsonb_build_object('id',101,'funil_id',10,'etapa_id',142,'responsavel_id',1,'valor',500,'criado_em',t.ep('2 days'),'atualizado_em',t.ep('1 day'),'fechado_em',t.ep('1 day')),
      jsonb_build_object('id',102,'funil_id',10,'etapa_id',143,'responsavel_id',2,'valor',300,'criado_em',t.ep('2 days'),'atualizado_em',t.ep('1 day'),'fechado_em',t.ep('1 day')),
      jsonb_build_object('id',103,'funil_id',20,'etapa_id',2,'responsavel_id',0,'valor',0,'criado_em',t.ep('1 day'),'atualizado_em',t.ep('1 day')),
      jsonb_build_object('id',104,'funil_id',10,'etapa_id',2,'responsavel_id',2,'valor',0,'criado_em',t.ep('10 days'),'atualizado_em',t.ep('5 days')),
      jsonb_build_object('id',105,'funil_id',99,'etapa_id',2,'responsavel_id',1,'criado_em',t.ep('1 day'),'atualizado_em',t.ep('1 day'))),
    'eventos', jsonb_build_array(
      jsonb_build_object('id','e1','tipo','incoming_chat_message','entidade_tipo','lead','entidade_id',100,'em',t.ep('90 min'),'texto','oi, quero óculos'),
      jsonb_build_object('id','e2','tipo','outgoing_chat_message','entidade_tipo','lead','entidade_id',100,'usuario_id',1,'em',t.ep('80 min')),
      jsonb_build_object('id','e3','tipo','incoming_chat_message','entidade_tipo','lead','entidade_id',100,'em',t.ep('60 min')),
      jsonb_build_object('id','e4','tipo','incoming_chat_message','entidade_tipo','lead','entidade_id',101,'em',t.ep('3 hours')),
      jsonb_build_object('id','e5','tipo','outgoing_chat_message','entidade_tipo','lead','entidade_id',101,'usuario_id',2,'em',t.ep('2 hours')),
      jsonb_build_object('id','e6','tipo','incoming_chat_message','entidade_tipo','contact','entidade_id',555,'em',t.ep('45 min')),
      jsonb_build_object('id','e7','tipo','note_added','entidade_tipo','lead','entidade_id',100,'em',t.ep('30 min'))) || extra_eventos)
$$;

create function t.sync_com(lote jsonb, validar boolean default true) returns jsonb language plpgsql as $$
declare v_t uuid; v jsonb;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'comercial'), 'comercial', 'com_sincronizacao',
    'com.kommo', 'sincronizar', null, '{"origem":"kommo"}', 'com:teste:' || gen_random_uuid(), null, 6);
  perform core.reivindicar('comercial', 'kommo-sync', 120);
  v := com.concluir_sincronizacao(v_t, 'kommo-sync', lote);
  if validar then v := v || jsonb_build_object('validacao', com.validar_sincronizacao(v_t, 'validador_sql')); end if;
  return v || jsonb_build_object('tarefa', v_t);
end $$;

-- B. Primeira leitura
select set_config('t.c1', t.sync_com(t.lote_com())::text, false);
select t.ok('sync','5 leads aplicados, lead de funil desconhecido e evento que não é chat ignorados',
  (current_setting('t.c1')::jsonb->>'leads')::int = 5 and (current_setting('t.c1')::jsonb->>'ignoradas')::int = 2, current_setting('t.c1'));
select t.ok('sync','6 mensagens de chat gravadas', (current_setting('t.c1')::jsonb->>'mensagens_novas')::int = 6);
select t.ok('sync','validador independente aprovou', current_setting('t.c1')::jsonb->>'validacao' = 'concluida');
select t.ok('privacidade','nome/telefone do lead, e-mail do atendente e texto da mensagem não gravados',
  not exists (select 1 from com.leads where row_to_json(leads.*)::text ~ '(Fulano|5519999990000)')
  and not exists (select 1 from com.usuarios where row_to_json(usuarios.*)::text ~ 'a@x.com')
  and not exists (select 1 from com.mensagens where row_to_json(mensagens.*)::text ~ 'óculos'));
select t.ok('medida','tempo de resposta: 10 min no lead 100 e 60 min no lead 101',
  (select round(minutos) from com.v_respostas where entidade_tipo = 'lead' and entidade_id = 100 and resposta_em is not null) = 10
  and (select round(minutos) from com.v_respostas where entidade_tipo = 'lead' and entidade_id = 101) = 60);
select t.ok('alertas','cliente esperando há 60 min (limite 30) no lead 100', exists (select 1 from com.alertas where tipo = 'cliente_sem_resposta' and referencia = 'lead:100' and status = 'aberto'));
select t.ok('alertas','contato sem lead também conta como esperando', exists (select 1 from com.alertas where tipo = 'cliente_sem_resposta' and referencia = 'contact:555' and status = 'aberto'));
select t.ok('alertas','conversa respondida não gera alerta de espera', not exists (select 1 from com.alertas where referencia = 'lead:101' and tipo = 'cliente_sem_resposta'));
select t.ok('alertas','lead aberto sem responsável', exists (select 1 from com.alertas where tipo = 'lead_sem_responsavel' and referencia = 'lead:103' and status = 'aberto'));
select t.ok('alertas','lead parado há 5 dias (limite 3)', exists (select 1 from com.alertas where tipo = 'lead_parado' and referencia = 'lead:104' and status = 'aberto'));
select t.ok('alertas','lead ganho/perdido não fica parado', not exists (select 1 from com.alertas where referencia in ('lead:101','lead:102')));
select t.ok('alertas','funis ainda sem loja sinalizados', (select count(*) from com.alertas where tipo = 'funil_sem_loja' and status = 'aberto') = 2);

-- C. Idempotência e resolução automática
select set_config('t.c2', t.sync_com(t.lote_com())::text, false);
select t.ok('sync','mesmo lote: nenhuma mensagem nova, alertas sem duplicar',
  (current_setting('t.c2')::jsonb->>'mensagens_novas')::int = 0
  and (select count(*) from com.alertas where status = 'aberto' and referencia = 'lead:100') = 1, current_setting('t.c2'));
select set_config('t.c3', t.sync_com(t.lote_com(jsonb_build_array(
  jsonb_build_object('id','e8','tipo','outgoing_chat_message','entidade_tipo','lead','entidade_id',100,'usuario_id',1,'em',t.ep('1 min')))))::text, false);
select t.ok('resolucao','atendente respondeu: alerta de espera resolvido sozinho',
  not exists (select 1 from com.alertas where tipo = 'cliente_sem_resposta' and referencia = 'lead:100' and status = 'aberto')
  and exists (select 1 from com.alertas where tipo = 'cliente_sem_resposta' and referencia = 'lead:100' and status = 'resolvido'
              and resolvido_por like 'agente_comercial%'));
select t.ok('resolucao','validação da leitura seguinte aprovou', current_setting('t.c3')::jsonb->>'validacao' = 'concluida');
select t.ok('janela','próxima janela continua de onde parou (com sobreposição de 10 min)',
  (com.proxima_janela()->>'desde')::bigint = (current_setting('t.c3')::jsonb->>'ate')::timestamptz::date - '1970-01-01'::date
  or abs((com.proxima_janela()->>'desde')::bigint - (extract(epoch from (current_setting('t.c3')::jsonb->>'ate')::timestamptz) - 600)) < 2);
-- pedaço configurável (achado ao ligar, 28/10: mais de 5 mil mensagens em 3 dias)
update core.config set valor = '12' where chave = 'com.sync.janela_horas';
select t.ok('janela','cada leitura cobre no máximo o pedaço configurado (12 h)',
  (com.proxima_janela()->>'ate')::bigint - (com.proxima_janela()->>'desde')::bigint <= 12 * 3600);

-- D. Validador e atomicidade
do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'comercial'), 'comercial', 'com_sincronizacao',
    'com.kommo', 'sincronizar', null, '{"origem":"kommo"}', 'com:teste:validador', null, 6);
  perform core.reivindicar('comercial', 'kommo-sync', 120);
  perform com.concluir_sincronizacao(v_t, 'kommo-sync', t.lote_com());
  update com.alertas set status = 'resolvido', resolvido_em = now(), resolvido_por = 'teste: sumiu indevidamente'
   where tipo = 'cliente_sem_resposta' and referencia = 'contact:555' and status = 'aberto';
  perform set_config('t.cv', com.validar_sincronizacao(v_t, 'validador_sql'), false);
end $$;
select t.ok('validador','alerta sumido indevidamente: validador reprova e bloqueia', current_setting('t.cv') = 'bloqueada');
select t.sync_com(t.lote_com());   -- leitura seguinte reabre o alerta
select t.ok('validador','leitura seguinte reabre o alerta', exists (select 1 from com.alertas where referencia = 'contact:555' and tipo = 'cliente_sem_resposta' and status = 'aberto'));

do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'comercial'), 'comercial', 'com_sincronizacao',
    'com.kommo', 'sincronizar', null, '{"origem":"kommo"}', 'com:teste:atomico', null, 6);
  perform core.reivindicar('comercial', 'kommo-sync', 120);
  perform set_config('t.ca', v_t::text, false);
end $$;
select t.erro('atomico','lote sem janela é recusado inteiro',
  format('select com.concluir_sincronizacao(%L, %L, %L::jsonb)', current_setting('t.ca'), 'kommo-sync', '{"leads":[]}'), 'janela');
select t.ok('atomico','nada gravado e tarefa segue em execução',
  (select status from core.tarefas where id = current_setting('t.ca')::uuid) = 'executando'
  and not exists (select 1 from com.sincronizacoes where tarefa_id = current_setting('t.ca')::uuid));
select t.erro('validador','executor não valida a si mesmo',
  format('select com.validar_sincronizacao(%L, %L)', current_setting('t.ca'), 'kommo-sync'), 'validação');

-- E. Painel, lojas dos funis e escopo
set role anon;
select t.erro('seguranca','anon não chama o painel comercial', 'select public.painel_comercial()', 'permission');
reset role;
set role authenticated;
select t.erro('seguranca','usuário logado não lê o espelho direto', 'select count(*) from com.leads', 'permission');
select t.erro('seguranca','usuário logado não chama funções do agente', 'select com.agendar_sincronizacao()', 'permission');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('painel','gerente não define a loja de um funil', $q$select public.painel_comercial_funil_loja(10, 'campinas', 'tentativa')$q$, 'sem permissão');
select t.ok('painel','gerente de outra unidade não vê nada do comercial',
  jsonb_array_length(public.painel_comercial()->'lojas') = 0 and jsonb_array_length(public.painel_comercial()->'alertas') = 0
  and public.painel_comercial()->'funis' = 'null'::jsonb);
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('painel','admin vê os funis sem loja para mapear', jsonb_array_length(public.painel_comercial()->'funis') = 2);
select public.painel_comercial_funil_loja(10, 'campinas', 'Funil Campinas é da loja de Campinas');
select t.ok('painel','conversão da loja: 1 ganho (R$ 500), 1 perdido',
  (select x->>'ganhos' = '1' and x->>'perdidos' = '1' and (x->>'valor_ganho')::numeric = 500
   from jsonb_array_elements(public.painel_comercial('campinas')->'lojas') x));
select t.ok('painel','filtro por loja mostra só alertas dela',
  (select bool_and(x->>'unidade_id' = 'campinas') from jsonb_array_elements(public.painel_comercial('campinas')->'alertas') x));
select t.ok('painel','tempo de resposta por atendente', (select (x->>'respondidas')::int >= 1 from jsonb_array_elements(public.painel_comercial()->'atendentes') x where x->>'nome' = 'Atendente A'));
reset role;
select t.sem_jwt();
select t.ok('lojas','funil mapeado: alerta de funil sem loja resolvido e loja auditada',
  not exists (select 1 from com.alertas where referencia = 'funil:10' and status = 'aberto')
  and exists (select 1 from core.auditoria where acao = 'funil_loja' and entidade_id = '10' and ator_id = '00000000-0000-0000-0000-0000000060a1'));
select t.ok('lojas','alertas do funil herdaram a loja', (select unidade_id from com.alertas where referencia = 'lead:104' and status = 'aberto') = 'campinas');

select t.ok('auditoria','cadeia íntegra', core.verificar_auditoria() is null);
update core.agentes set status = 'pausado' where id = 'comercial';
update core.config set valor = 'false' where chave = 'com.sync.ativo';

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DO COMERCIAL FALHANDO'; end if; end $$;
