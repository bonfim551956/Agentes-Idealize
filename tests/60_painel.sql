-- Painel administrativo — camada de acesso (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
grant usage on schema t to authenticated, anon;
grant insert, select on t.resultados to authenticated, anon;
grant usage on all sequences in schema t to authenticated, anon;

-- simula o JWT que o PostgREST entrega ao banco
create function t.jwt(sub uuid, aal text default 'aal2') returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', sub, 'aal', aal, 'role', 'authenticated')::text, false) $$;
create function t.sem_jwt() returns void language sql as $$ select set_config('request.jwt.claims', '', false) $$;

-- ---------------------------------------------------------------------------
-- Massa
-- ---------------------------------------------------------------------------
insert into core.unidades (id, nome) values ('p_a','Painel A'), ('p_b','Painel B');
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a001','admin@teste'), ('00000000-0000-0000-0000-00000000a002','gerente.b@teste'),
  ('00000000-0000-0000-0000-00000000a003','fin.a@teste'),  ('00000000-0000-0000-0000-00000000a004','diretor2@teste'),
  ('00000000-0000-0000-0000-00000000a005','semPapel@teste'), ('00000000-0000-0000-0000-00000000a006','inativo@teste'),
  ('00000000-0000-0000-0000-00000000a007','novo@teste'),    ('00000000-0000-0000-0000-00000000a008','solto@teste');
insert into core.principais (id, tipo, nome, telefone, auth_uid) values
  ('00000000-0000-0000-0000-0000000060a1','usuario','Admin Painel','5513999996001','00000000-0000-0000-0000-00000000a001'),
  ('00000000-0000-0000-0000-0000000060a2','usuario','Gerente B',  '5513999996002','00000000-0000-0000-0000-00000000a002'),
  ('00000000-0000-0000-0000-0000000060a3','usuario','Financeiro A','5513999996003','00000000-0000-0000-0000-00000000a003'),
  ('00000000-0000-0000-0000-0000000060a4','usuario','Diretor 2',  null,'00000000-0000-0000-0000-00000000a004'),
  ('00000000-0000-0000-0000-0000000060a5','usuario','Sem Papel',  null,'00000000-0000-0000-0000-00000000a005'),
  ('00000000-0000-0000-0000-0000000060a6','usuario','Inativo P',  null,'00000000-0000-0000-0000-00000000a006'),
  ('00000000-0000-0000-0000-0000000060a7','usuario','Novo',       null, null),
  ('00000000-0000-0000-0000-0000000060a8','usuario','Outro',      null, null);
update core.principais set ativo = false where id = '00000000-0000-0000-0000-0000000060a6';
insert into core.principal_papeis (principal_id, papel_id, unidade_id) values
  ('00000000-0000-0000-0000-0000000060a1','admin',null), ('00000000-0000-0000-0000-0000000060a1','diretoria',null),
  ('00000000-0000-0000-0000-0000000060a2','gerente','p_b'),
  ('00000000-0000-0000-0000-0000000060a3','financeiro','p_a'),
  ('00000000-0000-0000-0000-0000000060a4','diretoria',null),
  ('00000000-0000-0000-0000-0000000060a6','diretoria',null);

insert into core.agentes (id, nome, departamento_id, status) values ('ag_painel','Agente Painel','financeiro','pausado');
insert into core.papeis (id, nome) values ('agente_painel_teste','Agente painel (teste)');
insert into core.politicas (id, papel_id, recurso, operacao, risco, categoria, papel_aprovador, aprovadores_minimos)
  values (960001, 'agente_painel_teste','teste.painel','pagar','alto','aprovacao','diretoria',1);

insert into core.tarefas (id, chave_idempotencia, agente_id, tipo, recurso, operacao, unidade_id, payload, valor,
  hash_operacao, risco, categoria, politica_id, status, solicitante_id, prazo) values
  ('00000000-0000-0000-0000-0000000060f1','painel:t1','ag_painel','teste','teste.painel','pagar','p_a',
   '{"cpf":"123.456.789-09","telefone":"5513999990001","nota":"pagar fornecedor"}', 150,
   core.hash_operacao('teste.painel','pagar','p_a',150,'{"cpf":"123.456.789-09","telefone":"5513999990001","nota":"pagar fornecedor"}'),
   'alto','aprovacao',960001,'aguardando_aprovacao','00000000-0000-0000-0000-0000000060a3', now() - interval '1 hour'),
  ('00000000-0000-0000-0000-0000000060f2','painel:t2','ag_painel','teste','teste.painel','ler','p_b','{}',null,
   core.hash_operacao('teste.painel','ler','p_b',null,'{}'),'baixo','automatica',null,'pronta',null, null),
  ('00000000-0000-0000-0000-0000000060f3','painel:t3','ag_painel','teste','teste.painel','global',null,'{}',null,
   core.hash_operacao('teste.painel','global',null,null,'{}'),'baixo','automatica',null,'pronta',null, null),
  ('00000000-0000-0000-0000-0000000060f4','painel:t4','ag_painel','teste','teste.painel','incerta','p_a','{}',null,
   core.hash_operacao('teste.painel','incerta','p_a',null,'{}'),'medio','automatica',null,'incerta',null, null);

insert into fin.pendencias (id, tipo, unidade_id, detalhe, referencia, material) values
  (960001,'sem_classificacao','p_a','{"descricao":"PIX ENVIADO 12345678909 FULANO"}','painel-1', true),
  (960002,'divergencia','p_b','{"obs":"diferença de centavos"}','painel-2', false);
select core.abrir_incidente('painel:inc1','media','Falha de teste no painel','ag_painel', null, '00000000-0000-0000-0000-0000000060f2');
-- valores calculados como superusuário (o papel authenticated não lê o core)
select core.hash_operacao('teste.painel','pagar','p_a',150,'{"cpf":"123.456.789-09","telefone":"5513999990001","nota":"pagar fornecedor"}') as h1,
       (select id from core.principais where agente_id = 'financeiro') as ag_principal,
       (select id from core.incidentes where chave_agrupamento = 'painel:inc1') as inc1 \gset

-- ---------------------------------------------------------------------------
-- A. Quem entra
-- ---------------------------------------------------------------------------
set role anon;
select t.erro('acesso','anon não executa nenhuma função do painel', 'select public.painel_resumo()', 'permission');
select t.erro('acesso','anon não executa painel_eu', 'select public.painel_eu()', 'permission');
reset role;

set role authenticated;
select t.sem_jwt();
select t.erro('acesso','sem login → não autenticado', 'select public.painel_eu()', 'não autenticado');
select t.jwt('00000000-0000-0000-0000-00000000a008');
select t.erro('acesso','login sem vínculo com pessoa → sem acesso', 'select public.painel_eu()', 'sem acesso');
select t.jwt('00000000-0000-0000-0000-00000000a006');
select t.erro('acesso','pessoa inativa → sem acesso', 'select public.painel_eu()', 'sem acesso');
select t.jwt('00000000-0000-0000-0000-00000000a001', 'aal1');
select t.ok('acesso','painel_eu funciona sem 2FA e avisa que falta', (public.painel_eu()->>'aal2')::boolean = false);
select t.erro('acesso','sem 2FA (aal1) não lê dados', 'select public.painel_resumo()', '2FA');
select t.erro('acesso','sem 2FA não aprova', $q$select public.painel_aprovar('00000000-0000-0000-0000-0000000060f1','aprovar','x')$q$, '2FA');
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('acesso','com 2FA o admin entra', (public.painel_eu()->>'aal2')::boolean and (public.painel_eu()->'pode'->>'administrar')::boolean);
select t.erro('acesso','helpers internos não são executáveis', $q$select painel._pode('00000000-0000-0000-0000-0000000060a1','consultar')$q$, 'permission');
select t.erro('acesso','tabelas do core continuam fechadas', 'select count(*) from core.tarefas', 'permission');
select t.erro('acesso','tabelas do fin continuam fechadas', 'select count(*) from fin.pendencias', 'permission');
select t.jwt('00000000-0000-0000-0000-00000000a005');
select t.erro('acesso','pessoa sem papel não consulta', 'select public.painel_resumo()', 'sem permissão');

-- ---------------------------------------------------------------------------
-- B. Escopo por unidade
-- ---------------------------------------------------------------------------
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.ok('escopo','gerente B vê só tarefas da unidade B',
  (select bool_and(x->>'unidade_id' = 'p_b') and count(*) = 1 from jsonb_array_elements(public.painel_tarefas(null,'ag_painel')) x));
select t.erro('escopo','gerente B não abre tarefa da unidade A', $q$select public.painel_tarefa('00000000-0000-0000-0000-0000000060f1')$q$, 'alcance');
select t.erro('escopo','gerente B não abre tarefa sem unidade (global)', $q$select public.painel_tarefa('00000000-0000-0000-0000-0000000060f3')$q$, 'alcance');
select t.ok('escopo','gerente B não vê custos globais', public.painel_resumo()->'custo_mes' = 'null'::jsonb);
select t.ok('escopo','gerente B vê só a pendência da B',
  (select count(*) = 1 and bool_and(x->>'unidade_id' = 'p_b') from jsonb_array_elements(public.painel_pendencias()) x
   where (x->>'id')::bigint in (960001, 960002)));
select t.ok('escopo','gerente B vê incidente ligado à tarefa da B',
  exists (select 1 from jsonb_array_elements(public.painel_incidentes()) x where x->>'chave' = 'painel:inc1'));
select t.ok('escopo','gerente B: financeiro só com a unidade B e sem consolidado',
  (select count(*) = 1 from jsonb_array_elements(public.painel_financeiro()->'unidades') x) and public.painel_financeiro()->'consolidado' = 'null'::jsonb);
select t.erro('escopo','gerente B não lê DRE da unidade A', $q$select public.painel_dre('p_a')$q$, 'sem permissão');
select t.ok('escopo','gerente B lê DRE da própria unidade', jsonb_typeof(public.painel_dre('p_b')) = 'array');
select t.erro('escopo','gerente B não lê auditoria', 'select public.painel_auditoria()', 'sem permissão');
select t.erro('escopo','gerente B não administra usuários', 'select public.painel_usuarios()', 'sem permissão');
select t.ok('escopo','gerente B não vê aprovações da unidade A', jsonb_array_length(public.painel_aprovacoes()) = 0);
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('escopo','admin vê as 4 tarefas', jsonb_array_length(public.painel_tarefas(null,'ag_painel')) = 4);
select t.ok('escopo','filtro por status funciona', jsonb_array_length(public.painel_tarefas(array['incerta'],'ag_painel')) = 1);
select t.ok('escopo','tarefa atrasada sinalizada',
  exists (select 1 from jsonb_array_elements(public.painel_tarefas(null,'ag_painel')) x where (x->>'atrasada')::boolean));

-- ---------------------------------------------------------------------------
-- C. Mascaramento
-- ---------------------------------------------------------------------------
select t.ok('mascara','CPF e telefone do payload mascarados no detalhe',
  (select position('123.456' in p::text) = 0 and position('55139999' in p::text) = 0
          and position('-09' in p::text) > 0 and position('0001' in p::text) > 0
   from (select public.painel_tarefa('00000000-0000-0000-0000-0000000060f1')->'tarefa'->'payload' p) z));
select t.ok('mascara','CPF dentro do texto da pendência mascarado',
  (select position('12345678909' in x::text) = 0 and position('8909' in x::text) > 0
   from jsonb_array_elements(public.painel_pendencias('p_a')) x where (x->>'id')::bigint = 960001));
select t.ok('mascara','telefone na lista de usuários só com 4 dígitos',
  (select bool_and(x->>'telefone' like '••••%' and length(x->>'telefone') = 8)
   from jsonb_array_elements(public.painel_usuarios()->'principais') x where x->>'telefone' is not null));

-- ---------------------------------------------------------------------------
-- D. Aprovação (presa ao hash, alçada, nunca o solicitante)
-- ---------------------------------------------------------------------------
select t.jwt('00000000-0000-0000-0000-00000000a003');
select t.ok('aprovacao','solicitante vê a tarefa mas não pode aprovar',
  (public.painel_tarefa('00000000-0000-0000-0000-0000000060f1')->'pode'->>'aprovar')::boolean = false);
select t.erro('aprovacao','solicitante não aprova a própria operação',
  format('select public.painel_aprovar(%L,%L,%L)', '00000000-0000-0000-0000-0000000060f1','aprovar',
    :'h1'),
  'solicitou');
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('aprovacao','admin/diretoria vê a aprovação e pode aprovar',
  (select (x->>'pode_aprovar')::boolean from jsonb_array_elements(public.painel_aprovacoes()) x
   where x->>'id' = '00000000-0000-0000-0000-0000000060f1'));
select t.erro('aprovacao','hash diferente do que foi visto é recusado',
  $q$select public.painel_aprovar('00000000-0000-0000-0000-0000000060f1','aprovar','hash-velho')$q$, 'hash');
select t.erro('aprovacao','rejeição sem motivo é recusada',
  $q$select public.painel_aprovar('00000000-0000-0000-0000-0000000060f1','rejeitar','x','')$q$, 'motivo');
select t.erro('aprovacao','decisão inválida é recusada',
  $q$select public.painel_aprovar('00000000-0000-0000-0000-0000000060f1','talvez','x')$q$, 'inválida');
select t.ok('aprovacao','aprovação com o hash visto libera a tarefa',
  public.painel_aprovar('00000000-0000-0000-0000-0000000060f1','aprovar',
    (select x->>'hash_operacao' from jsonb_array_elements(public.painel_aprovacoes()) x
     where x->>'id' = '00000000-0000-0000-0000-0000000060f1'), 'ok pelo painel') = 'pronta');
reset role;
select t.ok('aprovacao','aprovação registrada com canal painel e ator real',
  exists (select 1 from core.aprovacoes where tarefa_id = '00000000-0000-0000-0000-0000000060f1'
          and aprovador_id = '00000000-0000-0000-0000-0000000060a1' and canal = 'painel')
  and exists (select 1 from core.auditoria where acao = 'aprovacao_aprovar' and entidade_id = '00000000-0000-0000-0000-0000000060f1'
              and ator_id = '00000000-0000-0000-0000-0000000060a1'));

-- ---------------------------------------------------------------------------
-- E. Pendências financeiras
-- ---------------------------------------------------------------------------
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('pendencia','gerente (sem política) não trata pendência', $q$select public.painel_pendencia_tratar(960002,'resolver','corrigido no banco')$q$, 'sem permissão');
select t.jwt('00000000-0000-0000-0000-00000000a003');
select t.erro('pendencia','financeiro não trata pendência de outra unidade', $q$select public.painel_pendencia_tratar(960002,'resolver','corrigido no banco')$q$, 'sem permissão');
select t.erro('pendencia','financeiro não aceita pendência material', $q$select public.painel_pendencia_tratar(960001,'aceitar','aceito sem corrigir')$q$, 'sem permissão');
select t.erro('pendencia','resolução exige descrição', $q$select public.painel_pendencia_tratar(960001,'resolver','ok')$q$, 'mínimo');
select public.painel_pendencia_tratar(960001,'resolver','classificado manualmente como laboratório');
reset role;
select t.ok('pendencia','financeiro resolve na própria unidade, com autor e auditoria',
  exists (select 1 from fin.pendencias where id = 960001 and status = 'resolvida' and resolvido_por = '00000000-0000-0000-0000-0000000060a3')
  and exists (select 1 from core.auditoria where acao = 'pendencia_resolvida' and entidade_id = '960001'
              and ator_id = '00000000-0000-0000-0000-0000000060a3'));
set role authenticated;
select t.erro('pendencia','pendência já resolvida não é tratada de novo', $q$select public.painel_pendencia_tratar(960001,'resolver','de novo, por engano')$q$, 'não está aberta');

-- ---------------------------------------------------------------------------
-- F. Usuários e papéis
-- ---------------------------------------------------------------------------
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.erro('usuarios','admin não altera o próprio acesso',
  $q$select public.painel_papel_conceder('00000000-0000-0000-0000-0000000060a1','consulta',null,null,'teste próprio')$q$, 'próprio');
select t.erro('usuarios','papel de agente não vai para pessoa',
  $q$select public.painel_papel_conceder('00000000-0000-0000-0000-0000000060a5','agente_financeiro',null,null,'teste de papel')$q$, 'inválido');
select t.erro('usuarios','agente não é gerenciado pelo painel',
  format('select public.painel_papel_conceder(%L,%L,null,null,%L)', :'ag_principal', 'consulta', 'teste agente'), 'agentes não');
select t.erro('usuarios','concessão exige motivo',
  $q$select public.painel_papel_conceder('00000000-0000-0000-0000-0000000060a5','consulta',null,null,'')$q$, 'mínimo');
select public.painel_papel_conceder('00000000-0000-0000-0000-0000000060a5','consulta',null,null,'acesso de leitura para teste');
select t.jwt('00000000-0000-0000-0000-00000000a005');
select t.ok('usuarios','papel concedido vale na hora', (public.painel_resumo()->>'plataforma_pausada') is not null);
select t.jwt('00000000-0000-0000-0000-00000000a001');
select public.painel_papel_revogar('00000000-0000-0000-0000-0000000060a5','consulta',null,'fim do teste de leitura');
select t.jwt('00000000-0000-0000-0000-00000000a005');
select t.erro('usuarios','papel revogado deixa de valer na hora', 'select public.painel_resumo()', 'sem permissão');
select t.jwt('00000000-0000-0000-0000-00000000a001');
select public.painel_usuario_ativo('00000000-0000-0000-0000-0000000060a2', false, 'teste de revogação imediata');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('usuarios','pessoa desativada perde o acesso na próxima chamada', 'select public.painel_eu()', 'sem acesso');
select t.jwt('00000000-0000-0000-0000-00000000a001');
select public.painel_usuario_ativo('00000000-0000-0000-0000-0000000060a2', true, 'fim do teste de revogação');
select t.erro('usuarios','vincular e-mail inexistente falha', $q$select public.painel_usuario_vincular('00000000-0000-0000-0000-0000000060a7','ninguem@teste','vínculo de teste')$q$, 'nenhum login');
select public.painel_usuario_vincular('00000000-0000-0000-0000-0000000060a7','NOVO@teste','vínculo de teste');
select t.erro('usuarios','mesmo login não vincula duas pessoas', $q$select public.painel_usuario_vincular('00000000-0000-0000-0000-0000000060a8','novo@teste','vínculo duplicado')$q$, 'outra pessoa');
select t.erro('usuarios','políticas do admin no painel não mudam pelo painel',
  $q$select public.painel_politica_definir('admin','painel','administrar','proibida','critico',null,null,1,null,'tentativa de travar')$q$, 'migração');
select t.ok('usuarios','admin define política de outro recurso pelo painel (versionada)',
  public.painel_politica_definir('consulta','teste.painel','ler','automatica','baixo',null,null,1,null,'leitura de teste') > 0);
reset role;
select t.ok('usuarios','concessões/revogações/vínculo auditados com o ator',
  (select count(distinct acao) = 5 from core.auditoria where ator_id = '00000000-0000-0000-0000-0000000060a1'
   and acao in ('papel_concedido','papel_revogado','usuario_desativado','usuario_ativado','usuario_vinculado')));

-- ---------------------------------------------------------------------------
-- G. Modo seguro e agentes
-- ---------------------------------------------------------------------------
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('operacao','gerente não pausa a plataforma', $q$select public.painel_plataforma_pausar(true,'teste de pausa')$q$, 'sem permissão');
select t.jwt('00000000-0000-0000-0000-00000000a004');
select public.painel_plataforma_pausar(true,'diretoria aciona modo seguro');
select t.ok('operacao','diretoria pausa (modo seguro)', (public.painel_resumo()->>'plataforma_pausada')::boolean);
select t.erro('operacao','diretoria não retoma (só admin)', $q$select public.painel_plataforma_pausar(false,'retomar')$q$, 'sem permissão');
select t.erro('operacao','diretoria não muda status de agente', $q$select public.painel_agente_status('ag_painel','ativo','ligar')$q$, 'sem permissão');
select t.jwt('00000000-0000-0000-0000-00000000a001');
select public.painel_plataforma_pausar(false,'admin retoma após teste');
select t.ok('operacao','admin retoma', not (public.painel_resumo()->>'plataforma_pausada')::boolean);
select t.erro('operacao','status de agente exige motivo', $q$select public.painel_agente_status('ag_painel','ativo','')$q$, 'mínimo');
select t.erro('operacao','status de agente só ativo/pausado', $q$select public.painel_agente_status('ag_painel','desativado','tentativa')$q$, 'inválido');
select public.painel_agente_status('ag_painel','ativo','teste de ativação');
select public.painel_agente_status('ag_painel','pausado','fim do teste de ativação');
select t.ok('operacao','agentes listados com métricas e economia sem número inventado',
  (select x->>'status' = 'pausado' and x->'economia_estimada' = 'null'::jsonb and x ? 'taxa_sucesso'
   from jsonb_array_elements(public.painel_agentes()) x where x->>'id' = 'ag_painel'));
select t.ok('operacao','operação mostra chaves, integrações e versões',
  (select o->'chaves' ? 'fin_whatsapp_ativo' and jsonb_array_length(o->'integracoes') > 0 and o->'versoes'->'componentes' ? 'versao_painel'
   from (select public.painel_operacao() o) z));
select t.ok('operacao','custos respondem por dimensão', public.painel_custos() ? 'por');
select t.erro('operacao','período de custos inválido é recusado', $q$select public.painel_custos('2026-10-10','2026-10-01')$q$, 'inválido');
reset role;
select t.ok('operacao','pausa/retomada e status de agente auditados com o ator',
  exists (select 1 from core.auditoria where acao = 'plataforma_pausada' and ator_id = '00000000-0000-0000-0000-0000000060a4')
  and exists (select 1 from core.auditoria where acao = 'plataforma_retomada' and ator_id = '00000000-0000-0000-0000-0000000060a1')
  and (select count(*) from core.auditoria where acao = 'agente_status' and ator_id = '00000000-0000-0000-0000-0000000060a1') = 2);

-- ---------------------------------------------------------------------------
-- H. Incidentes, reconciliação, cancelamento
-- ---------------------------------------------------------------------------
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('tratamento','gerente não trata incidente',
  format('select public.painel_incidente_tratar(%s,%L,%L)', :inc1, 'resolvido', 'resolvido pelo gerente'), 'sem permissão');
select t.erro('tratamento','gerente não cancela tarefa', $q$select public.painel_cancelar_tarefa('00000000-0000-0000-0000-0000000060f2','não precisa mais')$q$, 'sem permissão');
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.erro('tratamento','resolver incidente exige nota de 10+ caracteres',
  format('select public.painel_incidente_tratar(%s,%L,%L)', :inc1, 'resolvido', 'ok'), 'mínimo');
select public.painel_incidente_tratar(:inc1, 'resolvido', 'falha de teste, sem efeito real');
select t.ok('tratamento','incidente resolvido some da lista de abertos',
  not exists (select 1 from jsonb_array_elements(public.painel_incidentes()) x where x->>'chave' = 'painel:inc1'));
select t.jwt('00000000-0000-0000-0000-00000000a003');
select t.erro('tratamento','financeiro não reconcilia tarefa incerta', $q$select public.painel_reconciliar('00000000-0000-0000-0000-0000000060f4',false,'extrato conferido','não efetivou')$q$, 'sem permissão');
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.erro('tratamento','reconciliação exige evidência', $q$select public.painel_reconciliar('00000000-0000-0000-0000-0000000060f4',false,'','não efetivou')$q$, 'mínimo');
select t.ok('tratamento','reconciliação humana devolve à fila quando não efetivou',
  public.painel_reconciliar('00000000-0000-0000-0000-0000000060f4', false, 'conferi o sistema externo: nada gravado', 'não efetivou') = 'pronta');
select public.painel_cancelar_tarefa('00000000-0000-0000-0000-0000000060f2','não precisa mais executar');
select t.erro('tratamento','tarefa cancelada não é cancelada de novo', $q$select public.painel_cancelar_tarefa('00000000-0000-0000-0000-0000000060f2','de novo')$q$, 'encerrada');
reset role;
select t.ok('tratamento','incidente, reconciliação e cancelamento auditados',
  exists (select 1 from core.auditoria where acao = 'incidente_resolvido' and ator_id = '00000000-0000-0000-0000-0000000060a1')
  and exists (select 1 from core.auditoria where acao = 'reconciliacao' and entidade_id = '00000000-0000-0000-0000-0000000060f4')
  and exists (select 1 from core.auditoria where acao = 'tarefa_cancelada' and entidade_id = '00000000-0000-0000-0000-0000000060f2'
              and ator_id = '00000000-0000-0000-0000-0000000060a1'));

-- ---------------------------------------------------------------------------
-- I. Auditoria, registro de acessos e limite de requisições
-- ---------------------------------------------------------------------------
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('auditoria','admin verifica a cadeia pelo painel', (public.painel_auditoria_verificar()->>'integra')::boolean);
select t.ok('auditoria','listagem da auditoria mascarada e paginada', jsonb_array_length(public.painel_auditoria(null,null,5)) = 5);
reset role;
select t.ok('acessos','consultas sensíveis ficam registradas',
  exists (select 1 from core.painel_acessos where principal_id = '00000000-0000-0000-0000-0000000060a1'
          and funcao = 'tarefa' and alvo = '00000000-0000-0000-0000-0000000060f1'));
update core.config set valor = '3' where chave = 'painel.limite_por_minuto';
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a007');
do $$ begin perform public.painel_eu(); perform public.painel_eu(); perform public.painel_eu(); end $$;
select t.erro('acessos','limite por minuto bloqueia excesso', 'select public.painel_eu()', 'muitas requisições');
reset role;
update core.config set valor = '240' where chave = 'painel.limite_por_minuto';

select t.ok('auditoria','cadeia íntegra ao final', core.verificar_auditoria() is null);
select t.sem_jwt();

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DO PAINEL FALHANDO'; end if; end $$;
