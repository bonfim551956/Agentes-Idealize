-- Agente Supervisor (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into core.unidades (id, nome) values ('sup_a','Loja Supervisor') on conflict (id) do nothing;

select t.ok('travas','agente nasce pausado', (select status from core.agentes where id = 'supervisor') = 'pausado');
select t.ok('travas','verificação nasce desligada', core.cfg('sup.sync.ativo') = 'false' and sup.agendar_verificacao() is null);
select t.ok('travas','envio nasce desligado (modo sombra)', core.cfg('sup.enviar') = 'false');
select t.ok('travas','proibido desligar o modo seguro, mexer em agente/política/auditoria/dados ou mandar para terceiros',
  (select bool_and((core.autorizar(sup._principal(), v.r, v.o, null)).categoria = 'proibida')
   from (values ('core.plataforma','desligar_modo_seguro'), ('sup.verificacao','alterar_agente'), ('sup.verificacao','alterar_politica'),
                ('sup.verificacao','apagar_auditoria'), ('sup.verificacao','alterar_dados'), ('sup.verificacao','excluir'),
                ('sup.notificacao','enviar_para_terceiros')) v(r, o)));
select t.ok('travas','pode só: verificar, avisar e LIGAR o modo seguro',
  (select bool_and((core.autorizar(sup._principal(), v.r, v.o, null)).categoria = 'automatica')
   from (values ('sup.verificacao','sincronizar'), ('sup.notificacao','enviar_resumo'), ('core.plataforma','acionar_modo_seguro')) v(r, o)));

update core.agentes set status = 'ativo' where id = 'supervisor';
update core.config set valor = 'true' where chave = 'sup.sync.ativo';
-- resumo fora do horário atual (os testes de resumo ligam o horário de propósito)
update core.config set valor = ((extract(hour from now() at time zone 'America/Sao_Paulo')::int + 12) % 24)::text where chave = 'sup.horarios_resumo';

create function t.sup(amostras jsonb default '{}', validar boolean default true) returns jsonb language plpgsql as $$
declare v_t uuid; v jsonb;
begin
  v_t := core.criar_tarefa(sup._principal(), 'supervisor', 'sup_verificacao', 'sup.verificacao', 'sincronizar', null,
    '{"origem":"teste"}', 'sup:teste:' || gen_random_uuid(), null, 1, null, '{}', null, true);
  perform core.reivindicar('supervisor', 'supervisor-sync', 120);
  v := sup.concluir_verificacao(v_t, 'supervisor-sync', amostras);
  if validar then v := v || jsonb_build_object('validacao', sup.validar_verificacao(v_t, 'validador_sql')); end if;
  return v || jsonb_build_object('tarefa', v_t);
end $$;
create function t.achado(p_tipo text, p_ref text) returns sup.achados language sql as $$
  select * from sup.achados where tipo = p_tipo and referencia = p_ref order by id desc limit 1 $$;

select set_config('t.s1', t.sup()::text, false);
select t.ok('ciclo','verificação roda e o conferente independente aprova', current_setting('t.s1')::jsonb->>'validacao' = 'concluida', current_setting('t.s1'));
select t.ok('ciclo','agendamento é de monitoramento: roda mesmo com modo seguro ligado',
  (select monitoramento from core.tarefas where id = (current_setting('t.s1')::jsonb->>'tarefa')::uuid));
select t.ok('ciclo','agendamento: uma verificação por hora (mesma chave, mesma tarefa)', sup.agendar_verificacao() = sup.agendar_verificacao());
select t.ok('saude','agentes pausados e desligados não contam como atrasados',
  not exists (select 1 from sup.achados where status = 'aberto' and tipo = 'agente_atrasado'));

-- 1. agente ligado sem ler no prazo
update core.agentes set status = 'ativo', atualizado_em = now() - interval '2 days' where id = 'laboratorio';
update lab.sincronizacoes set em = least(em, now() - interval '3 hours');
update core.config set valor = 'true' where chave = 'lab.sync.ativo';
insert into lab.sincronizacoes (origem, recebidas, aplicadas, novas, atualizadas, ignoradas, alertas_abertos, alertas_resolvidos, hash_lote, em)
values ('teste', 0, 0, 0, 0, 0, 0, 0, 'x', now() - interval '3 hours');
select t.sup();
select t.ok('saude','Laboratório ligado e sem ler há 3 h (limite 1 h): achado grave',
  (t.achado('agente_atrasado','laboratorio')).status = 'aberto' and (t.achado('agente_atrasado','laboratorio')).severidade = 'alta',
  (t.achado('agente_atrasado','laboratorio')).titulo);
insert into lab.sincronizacoes (origem, recebidas, aplicadas, novas, atualizadas, ignoradas, alertas_abertos, alertas_resolvidos, hash_lote, em)
values ('teste', 0, 0, 0, 0, 0, 0, 0, 'y', now());
select t.sup();
select t.ok('saude','voltou a ler: achado se resolve sozinho', (t.achado('agente_atrasado','laboratorio')).status = 'resolvido');
update core.agentes set status = 'pausado' where id = 'laboratorio';
update core.config set valor = 'false' where chave = 'lab.sync.ativo';

-- 2. ligado pela metade
update core.agentes set status = 'ativo' where id = 'comercial';
select t.sup();
select t.ok('saude','Comercial ativo com a leitura desligada: avisa "ligado pela metade"', (t.achado('ligado_pela_metade','comercial')).status = 'aberto');
update core.agentes set status = 'pausado' where id = 'comercial';

-- 3/4/6. conferência reprovada, tarefa presa, aprovação parada
insert into core.tarefas (id, chave_idempotencia, agente_id, tipo, recurso, operacao, hash_operacao, categoria, status, motivo)
values ('00000000-0000-0000-0000-0000000005a1', 'sup:t:reprovada', 'caixa', 'cx_sincronizacao', 'cx.conferencia', 'sincronizar', 'h', 'automatica', 'bloqueada', 'validação rejeitada: soma não fecha');
insert into core.tarefas (id, chave_idempotencia, agente_id, tipo, recurso, operacao, hash_operacao, categoria, status, atualizado_em)
values ('00000000-0000-0000-0000-0000000005a2', 'sup:t:presa', 'rh', 'rh_sincronizacao', 'rh.prazos', 'sincronizar', 'h', 'automatica', 'validando', now() - interval '2 hours');
insert into core.tarefas (id, chave_idempotencia, agente_id, tipo, recurso, operacao, hash_operacao, categoria, status, criado_em)
values ('00000000-0000-0000-0000-0000000005a3', 'sup:t:aprovacao', 'financeiro', 'fin_x', 'fin.x', 'pagar', 'h', 'aprovacao', 'aguardando_aprovacao', now() - interval '6 hours');
select t.sup();
select t.ok('tarefas','conferência reprovada vira achado grave (o core não abria incidente)',
  (t.achado('conferencia_reprovada','00000000-0000-0000-0000-0000000005a1')).severidade = 'alta');
select t.ok('tarefas','leitura feita e não conferida há 2 h: tarefa presa', (t.achado('tarefa_presa','00000000-0000-0000-0000-0000000005a2')).status = 'aberto');
select t.ok('tarefas','pedido esperando aprovação há 6 h', (t.achado('aprovacao_parada','00000000-0000-0000-0000-0000000005a3')).status = 'aberto');
update core.tarefas set status = 'cancelada' where id in ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-0000000005a3');
select t.sup();
select t.ok('tarefas','tarefa tratada: achados se resolvem', (t.achado('tarefa_presa','00000000-0000-0000-0000-0000000005a2')).status = 'resolvido'
  and (t.achado('aprovacao_parada','00000000-0000-0000-0000-0000000005a3')).status = 'resolvido');

-- 5. incidentes
select set_config('t.inc', core.abrir_incidente('sup:teste:inc', 'media', 'Incidente de teste')::text, false);
select t.sup();
select t.ok('incidentes','incidente aberto aparece com a mesma gravidade', (t.achado('incidente', current_setting('t.inc'))).severidade = 'media');
update core.incidentes set status = 'resolvido', resolvido_em = now() where id = current_setting('t.inc')::bigint;
select t.sup();
select t.ok('incidentes','incidente resolvido: achado resolvido', (t.achado('incidente', current_setting('t.inc'))).status = 'resolvido');

-- 7/8. custo e integração
update core.agentes set limite_custo_mensal = 100 where id = 'marketing';
insert into core.custos (agente_id, tipo_tarefa, valor) values ('marketing', 'teste', 85);
update core.integracoes set status = 'indisponivel' where id = 'meta_ads';
select t.sup();
select t.ok('custo','85% do limite de custo: atenção', (t.achado('custo','marketing')).severidade = 'media', (t.achado('custo','marketing')).titulo);
select t.ok('integracao','integração indisponível: grave', not exists (select 1 from core.integracoes where id = 'meta_ads')
  or (t.achado('integracao','meta_ads')).severidade = 'alta');

-- Avisos em modo sombra
select set_config('t.m1', sup.preparar_mensagens((select tarefa_id from sup.verificacoes order by em desc limit 1))::text, false);
select t.ok('avisos','modo sombra: nada é devolvido para envio', current_setting('t.m1')::jsonb = '[]'::jsonb);
select t.ok('avisos','aviso urgente registrado em sombra, com os graves ainda não avisados',
  exists (select 1 from sup.mensagens where tipo = 'urgente' and status = 'sombra' and texto like 'Idealize AI — ATENÇÃO%' and texto like '%conferente reprovou%'));
select t.ok('avisos','graves avisados ficam marcados (não repete toda hora)',
  not exists (select 1 from sup.achados where status = 'aberto' and sup._sev(severidade) >= 4 and notificado_em is null));
select set_config('t.n_urg', (select count(*) from sup.mensagens where tipo = 'urgente')::text, false);
select t.sup();
select sup.preparar_mensagens((select tarefa_id from sup.verificacoes order by em desc limit 1));
select t.ok('avisos','sem grave novo: sem aviso urgente novo', (select count(*) from sup.mensagens where tipo = 'urgente') = current_setting('t.n_urg')::int);

-- custo subiu para 100%: gravidade sobe → avisa de novo
insert into core.custos (agente_id, tipo_tarefa, valor) values ('marketing', 'teste', 20);
select t.sup();
select t.ok('avisos','gravidade subiu (custo estourou): volta a ser avisado', (t.achado('custo','marketing')).severidade = 'alta'
  and (t.achado('custo','marketing')).notificado_em is null);
update core.config set valor = 'true' where chave = 'sup.enviar';
select set_config('t.m2', sup.preparar_mensagens((select tarefa_id from sup.verificacoes order by em desc limit 1))::text, false);
select t.ok('avisos','envio ligado e com destinatário cadastrado: aviso sai para envio', jsonb_array_length(current_setting('t.m2')::jsonb) = 1
  and current_setting('t.m2')::jsonb->0->>'texto' like '%limite de custo%', current_setting('t.m2'));
select t.ok('avisos','destinatários: só pessoas com o papel configurado e telefone válido', '5513999996001' = any(sup.destinos())
  and not exists (select 1 from unnest(sup.destinos()) d where d !~ '^55[0-9]{10,11}$'
    or not exists (select 1 from core.principais p join core.principal_papeis pp on pp.principal_id = p.id where p.telefone = d and pp.papel_id = 'admin'))
  and not ('5513999996002' = any(sup.destinos())), array_to_string(sup.destinos(), ','));
select t.ok('avisos','envio confirmado: mensagem enviada', sup.mensagem_resultado((current_setting('t.m2')::jsonb->0->>'id')::bigint, true) = 'enviada');
select t.erro('avisos','mensagem já enviada não muda de novo', format('select sup.mensagem_resultado(%s, false, %L)', current_setting('t.m2')::jsonb->0->>'id', 'x'), 'não está pendente');

-- resumo no horário configurado (uma vez por hora)
update core.config set valor = extract(hour from now() at time zone 'America/Sao_Paulo')::text where chave = 'sup.horarios_resumo';
select set_config('t.s9', t.sup()::text, false);
select set_config('t.m3', sup.preparar_mensagens((current_setting('t.s9')::jsonb->>'tarefa')::uuid)::text, false);
select t.ok('resumo','resumo da hora sai uma vez', (select count(*) from sup.mensagens where tipo = 'resumo'
  and chave = 'resumo:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDDHH24')) = 1
  and exists (select 1 from jsonb_array_elements(current_setting('t.m3')::jsonb) x where x->>'tipo' = 'resumo'));
select set_config('t.s10', t.sup()::text, false);
select sup.preparar_mensagens((current_setting('t.s10')::jsonb->>'tarefa')::uuid);
select t.ok('resumo','mesma hora: não repete', (select count(*) from sup.mensagens where tipo = 'resumo'
  and chave = 'resumo:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDDHH24')) = 1);
select t.ok('resumo','texto do resumo: agentes, problemas, alertas, aprovações e auditoria',
  sup.texto_resumo() like 'Idealize AI — resumo das%' and sup.texto_resumo() like '%Problemas abertos:%' and sup.texto_resumo() like '%Auditoria: íntegra%',
  sup.texto_resumo());
select t.ok('privacidade','nenhum aviso tem telefone, CPF ou e-mail', not exists (select 1 from sup.mensagens
  where texto ~ '(^|[^0-9])[0-9]{10,13}([^0-9]|$)' or texto ~ '[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}' or texto ~ '[^ @]+@[^ @]+\.[a-z]{2,}'));
select set_config('t.m4', (select id::text from sup.mensagens where status = 'pendente' order by id limit 1), false);
select set_config('t.r4', sup.mensagem_resultado(current_setting('t.m4')::bigint, false, 'HTTP 500'), false);
select t.ok('avisos','falha no envio: mensagem falhou e abre incidente', current_setting('t.r4') = 'falhou'
  and exists (select 1 from core.incidentes where chave_agrupamento = 'sup:envio' and status <> 'resolvido'));
update sup.mensagens set status = 'sombra' where status = 'pendente';
update core.config set valor = 'false' where chave = 'sup.enviar';
update core.config set valor = '7,12,18' where chave = 'sup.horarios_resumo';
update core.incidentes set status = 'resolvido', resolvido_em = now() where chave_agrupamento = 'sup:envio' and status <> 'resolvido';
update core.agentes set limite_custo_mensal = null where id = 'marketing';
update core.integracoes set status = 'nao_verificada' where id = 'meta_ads';

-- 9. Amostragem na fonte
insert into cob.asaas (id, unidade_id, valor, vencimento, status) values
  ('pay_sup1', 'sup_a', 100, sup._hoje() + 10, 'PENDING'), ('pay_sup2', 'sup_a', 50, sup._hoje() - 3, 'PENDING'),
  ('pay_sup3', 'sup_a', 70, sup._hoje() - 9, 'RECEIVED'), ('pay_sup4', 'sup_a', 80, sup._hoje() - 20, 'OVERDUE'),
  ('pay_sup5', 'sup_a', 90, sup._hoje() - 1, 'PENDING');
select set_config('t.s11', t.sup(jsonb_build_object('cobrancas', jsonb_build_array(
  jsonb_build_object('id','pay_sup1','encontrado',true,'campos',jsonb_build_object('status','PENDING','valor',100)),
  jsonb_build_object('id','pay_sup2','encontrado',true,'campos',jsonb_build_object('status','OVERDUE','valor',50)),
  jsonb_build_object('id','pay_sup3','encontrado',true,'campos',jsonb_build_object('status','RECEIVED','valor',75)),
  jsonb_build_object('id','pay_sup4','encontrado',false),
  jsonb_build_object('id','pay_sup5','encontrado',true,'campos',jsonb_build_object('status','RECEIVED','valor',90,'pagamento',sup._hoje())),
  jsonb_build_object('id','pay_naoexiste','encontrado',true,'campos',jsonb_build_object('status','PENDING','valor',1)))))::text, false);
select t.ok('amostra','Asaas: 5 conferidos — 1 igual, 2 mudaram depois (venceu / foi pago), 1 valor diferente, 1 sumiu; id fora do espelho ignorado',
  (select conferidos = 5 and iguais = 1 and mudaram_depois = 2 and divergentes = 1 and nao_encontrados = 1 from sup.amostras where agente_id = 'cobrancas' order by id desc limit 1),
  current_setting('t.s11'));
select t.ok('amostra','diferença real vira achado grave com o id e o campo (sem dado pessoal)',
  (t.achado('fonte_diverge','cobrancas')).severidade = 'alta'
  and (t.achado('fonte_diverge','cobrancas')).detalhe->'itens' @> '[{"id":"pay_sup3","campos":["valor"]}]');
select t.ok('amostra','validador confere a conta da amostra', current_setting('t.s11')::jsonb->>'validacao' = 'concluida');
select t.sup(jsonb_build_object('cobrancas', jsonb_build_array(
  jsonb_build_object('id','pay_sup1','encontrado',true,'campos',jsonb_build_object('status','PENDING','valor',100)))));
select t.ok('amostra','nova amostra limpa: achado se resolve', (t.achado('fonte_diverge','cobrancas')).status = 'resolvido');

insert into com.funis (id, nome, unidade_id) values (9901, 'Funil Sup', 'sup_a') on conflict (id) do nothing;
insert into com.etapas (funil_id, id, nome, tipo, ordem) values (9901, 1, 'Novo', 'aberta', 1), (9901, 2, 'Atendendo', 'aberta', 2) on conflict do nothing;
insert into com.leads (id, funil_id, etapa_id, responsavel_id, valor, criado_em, atualizado_em, hash_origem) values
  (99001, 9901, 1, 11, 0, now() - interval '2 days', '2026-01-01 00:00:00+00', 'h'),
  (99002, 9901, 1, 11, 0, now() - interval '2 days', '2026-01-01 00:00:00+00', 'h'),
  (99003, 9901, 1, 11, 0, now() - interval '2 days', '2026-01-01 00:00:00+00', 'h');
select t.sup(jsonb_build_object('comercial', jsonb_build_array(
  jsonb_build_object('id','99001','encontrado',true,'campos',jsonb_build_object('funil_id',9901,'etapa_id',1,'responsavel_id',11,'valor',0,
    'atualizado_em', floor(extract(epoch from timestamptz '2026-01-01 00:00:00+00')))),
  jsonb_build_object('id','99002','encontrado',true,'campos',jsonb_build_object('funil_id',9901,'etapa_id',2,'responsavel_id',11,'valor',0,
    'atualizado_em', floor(extract(epoch from now())))),
  jsonb_build_object('id','99003','encontrado',true,'campos',jsonb_build_object('funil_id',9901,'etapa_id',1,'responsavel_id',12,'valor',0,
    'atualizado_em', floor(extract(epoch from timestamptz '2026-01-01 00:00:00+00')))))));
select t.ok('amostra','Kommo: lead mexido depois da leitura não é erro; responsável diferente sem mexer é',
  (select iguais = 1 and mudaram_depois = 1 and divergentes = 1 from sup.amostras where agente_id = 'comercial' order by id desc limit 1)
  and (t.achado('fonte_diverge','comercial')).detalhe->'itens' @> '[{"id":"99003","campos":["responsavel"]}]');

insert into lab.os (id_origem, unidade_id, col, hash_origem, ultima_mov) values
  ('sup-os-1', 'sup_a', 1, 'h', '2026-01-01 00:00:00+00'), ('sup-os-2', 'sup_a', 1, 'h', '2026-01-01 00:00:00+00');
select t.sup(jsonb_build_object('laboratorio', jsonb_build_array(
  jsonb_build_object('id','sup-os-1','encontrado',true,'campos',jsonb_build_object('col',1,'cancelado',false,'nao_retirado',false,
    'ts', floor(extract(epoch from timestamptz '2026-01-01 00:00:00+00') * 1000))),
  jsonb_build_object('id','sup-os-2','encontrado',true,'campos',jsonb_build_object('col',2,'cancelado',false,'nao_retirado',false,
    'ts', floor(extract(epoch from now()) * 1000))))));
select t.ok('amostra','ADM/laboratório: OS que andou depois da leitura conta como "mudou depois"',
  (select conferidos = 2 and iguais = 1 and mudaram_depois = 1 and divergentes = 0 from sup.amostras where agente_id = 'laboratorio' order by id desc limit 1));
select set_config('t.tf', core.criar_tarefa(sup._principal(), 'supervisor', 'sup_verificacao', 'sup.verificacao', 'sincronizar', null,
    '{}', 'sup:teste:' || gen_random_uuid(), null, 1, null, '{}', null, true)::text, false);
select core.reivindicar('supervisor', 'supervisor-sync', 120);
select sup.concluir_verificacao(current_setting('t.tf')::uuid, 'supervisor-sync', '{}', '{"laboratorio":"falha na leitura da fonte: connect ECONNREFUSED"}');
select sup.validar_verificacao(current_setting('t.tf')::uuid, 'validador_sql');
select t.ok('amostra','fonte que não pôde ser lida vira aviso de atenção (e não apaga a última conferência boa)',
  (t.achado('amostra_falhou','laboratorio')).status = 'aberto' and (t.achado('amostra_falhou','laboratorio')).titulo like '%não consegui conferir%');
select t.sup(jsonb_build_object('laboratorio', jsonb_build_array(
  jsonb_build_object('id','sup-os-1','encontrado',true,'campos',jsonb_build_object('col',1,'cancelado',false,'nao_retirado',false,
    'ts', floor(extract(epoch from timestamptz '2026-01-01 00:00:00+00') * 1000))),
  jsonb_build_object('id','sup-os-2','encontrado',true,'campos',jsonb_build_object('col',2,'cancelado',false,'nao_retirado',false,
    'ts', floor(extract(epoch from now()) * 1000))))));
select t.ok('amostra','leitura voltou: aviso de falha se resolve', (t.achado('amostra_falhou','laboratorio')).status = 'resolvido');
select t.ok('amostra','sorteio respeita o tamanho pedido', jsonb_array_length(sup.amostra_pedir('cobrancas', 3)) <= 3
  and jsonb_array_length(sup.amostra_pedir('cobrancas', 3)) > 0);
select t.erro('amostra','agente sem conferência na fonte é recusado', $$select sup.amostra_pedir('rh', 3)$$, 'sem conferência');
select t.erro('amostra','amostra com mais de 50 itens é recusada',
  $$select sup.amostra_registrar(null, 'cobrancas', (select jsonb_agg(jsonb_build_object('id', 'x' || g)) from generate_series(1, 51) g))$$, 'até 50');

-- 10. auditoria adulterada → crítico + modo seguro
select set_config('t.aud_id', (select min(id)::text from core.auditoria where motivo is null), false);
alter table core.auditoria disable trigger user;
update core.auditoria set motivo = 'adulterado' where id = current_setting('t.aud_id')::bigint;
alter table core.auditoria enable trigger user;
select set_config('t.s12', t.sup()::text, false);
select t.ok('auditoria','adulteração detectada: achado CRÍTICO', (t.achado('auditoria_adulterada','cadeia')).severidade = 'critica'
  and (current_setting('t.s12')::jsonb->>'auditoria_ok')::boolean is false);
select t.ok('auditoria','modo seguro ligado sozinho, com incidente crítico e registro na auditoria',
  core.cfg('plataforma_pausada') = 'true'
  and exists (select 1 from core.incidentes where chave_agrupamento = 'auditoria:adulterada' and severidade = 'critica' and status <> 'resolvido')
  and exists (select 1 from core.auditoria where acao = 'modo_seguro_acionado' and ator = 'supervisor'));
select t.ok('auditoria','validador refaz a auditoria e aprova a verificação (resultado coerente)', current_setting('t.s12')::jsonb->>'validacao' = 'concluida');
select t.ok('auditoria','com modo seguro ligado o Supervisor continua rodando', sup.agendar_verificacao() is not null
  and (select status from core.tarefas where id = sup.agendar_verificacao()) <> 'bloqueada');
select set_config('t.m5', sup.preparar_mensagens((current_setting('t.s12')::jsonb->>'tarefa')::uuid)::text, false);
select t.ok('auditoria','aviso urgente leva o CRÍTICO', exists (select 1 from sup.mensagens where tarefa_id = (current_setting('t.s12')::jsonb->>'tarefa')::uuid
  and tipo = 'urgente' and texto like '%[CRÍTICO] Auditoria%'));
alter table core.auditoria disable trigger user;
update core.auditoria set motivo = null where id = current_setting('t.aud_id')::bigint;
alter table core.auditoria enable trigger user;
update core.config set valor = 'false' where chave = 'plataforma_pausada';
update core.incidentes set status = 'resolvido', resolvido_em = now() where chave_agrupamento = 'auditoria:adulterada' and status <> 'resolvido';
select t.sup();
select t.ok('auditoria','cadeia restaurada: achado crítico resolvido', (t.achado('auditoria_adulterada','cadeia')).status = 'resolvido');

-- Validador independente
select set_config('t.s13', t.sup('{}', false)::text, false);
insert into sup.achados (tipo, referencia, severidade, titulo) values ('teste', 'intruso', 'baixa', 'achado colocado por fora');
insert into sup.mensagens (chave, tipo, texto, status, tarefa_id) values ('teste:pend', 'resumo', 'x', 'pendente', (current_setting('t.s13')::jsonb->>'tarefa')::uuid);
select t.ok('validador','achado colocado por fora: conferente reprova e bloqueia',
  sup.validar_verificacao((current_setting('t.s13')::jsonb->>'tarefa')::uuid, 'validador_sql') = 'bloqueada');
select t.ok('validador','reprovação abre incidente crítico e segura os avisos pendentes',
  exists (select 1 from core.incidentes where chave_agrupamento = 'sup:validacao' and severidade = 'critica' and status <> 'resolvido')
  and (select status from sup.mensagens where chave = 'teste:pend') = 'bloqueada');
delete from sup.achados where tipo = 'teste';
select set_config('t.s14', t.sup('{}', false)::text, false);
select t.erro('validador','executor não valida a própria verificação',
  format('select sup.validar_verificacao(%L, %L)', current_setting('t.s14')::jsonb->>'tarefa', 'supervisor-sync'), 'própria');
select sup.validar_verificacao((current_setting('t.s14')::jsonb->>'tarefa')::uuid, 'validador_sql');
update core.incidentes set status = 'resolvido', resolvido_em = now() where chave_agrupamento = 'sup:validacao' and status <> 'resolvido';
select set_config('t.s15', t.sup()::text, false);
select t.ok('saude','próximo ciclo enxerga a conferência reprovada do próprio Supervisor', current_setting('t.s15')::jsonb->>'validacao' = 'concluida'
  and (t.achado('conferencia_reprovada', current_setting('t.s13')::jsonb->>'tarefa')).status = 'aberto');

-- Painel e segurança
select set_config('t.ndest', cardinality(sup.destinos())::text, false);
set role anon;
select t.erro('seguranca','anon não chama o painel do Supervisor', 'select public.painel_supervisor()', 'permission');
reset role;
set role authenticated;
select t.erro('seguranca','usuário logado não lê o schema do Supervisor', 'select count(*) from sup.achados', 'permission');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('painel','gerente de uma loja não vê o Supervisor (visão da plataforma inteira)', 'select public.painel_supervisor()', 'sem permissão');
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('painel','admin vê saúde dos agentes, achados, avisos e a prévia do resumo',
  jsonb_array_length(public.painel_supervisor()->'agentes') >= 8 and jsonb_array_length(public.painel_supervisor()->'achados') > 0
  and public.painel_supervisor()->>'previa' like 'Idealize AI%' and (public.painel_supervisor()->'config'->>'destinos')::int = current_setting('t.ndest')::int,
  left(public.painel_supervisor()::text, 300));
select t.ok('painel','amostra mais recente aparece no agente', (select x->'amostra'->>'conferidos' from jsonb_array_elements(public.painel_supervisor()->'agentes') x
  where x->>'agente_id' = 'laboratorio') = '2');
reset role;
select t.sem_jwt();

select t.ok('auditoria','cadeia íntegra', core.verificar_auditoria() is null);
update sup.achados set status = 'resolvido', resolvido_em = now() where status = 'aberto';
update core.agentes set status = 'pausado' where id = 'supervisor';
update core.config set valor = 'false' where chave = 'sup.sync.ativo';

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DO SUPERVISOR FALHANDO'; end if; end $$;
