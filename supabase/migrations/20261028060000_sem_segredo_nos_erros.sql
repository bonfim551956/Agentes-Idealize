-- =============================================================================
-- Idealize AI — nenhuma senha ou token em mensagem de erro  · Migração 20261028060000
-- Achado ao ligar o RH (28/10): com o endereço do RH 360 mal formado, o erro trazia o endereço inteiro (com a senha)
-- e ele foi gravado na tarefa, na execução, no incidente e na auditoria. A senha foi trocada pelo Diego.
-- Agora, no banco, TODA mensagem de erro passa por core._sem_segredo() antes de ser gravada (vale para qualquer
-- agente, mesmo que a função esqueça de limpar): some endereço com usuário/senha, "password=", "token=", "Bearer ...".
-- As cópias que ficaram na tarefa, na execução e no incidente são limpas aqui; a da auditoria é imutável por desenho
-- (a senha que ela guarda já não vale).
-- =============================================================================
create or replace function core._sem_segredo(p text) returns text
language sql immutable set search_path = pg_catalog as $$
  select case when p is null then null else
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(p,
      'postgres(ql)?://[^@]{0,250}@[^\s''"]*', '[endereço]', 'gi'),         -- endereço de banco, mesmo com espaço na senha
      '[a-z][a-z0-9+.-]*://[^\s''"]*@[^\s''"]*', '[endereço]', 'gi'),         -- esquema://usuario:senha@servidor...
      'postgres(ql)?://\S*', '[endereço]', 'gi'),                              -- qualquer endereço de banco, mesmo quebrado
      '(password|passwd|senha|secret|token|access_token|apikey|api_key)(["'']?\s*[=:]\s*)[^\s,;&"'']+', '\1\2[oculto]', 'gi'),
      'Bearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [oculto]', 'gi')
  end
$$;
revoke all on function core._sem_segredo(text) from public;

create or replace function core.registrar_execucao(p_tarefa uuid, p_executor text, p_status text,
  p_efeito_externo_id text default null, p_resultado jsonb default null, p_erro text default null) returns text
language plpgsql security definer set search_path = core, pg_catalog as $$
declare t record; v_novo text; v_back int;
begin
  p_erro := core._sem_segredo(p_erro);   -- nada de senha/token gravado em erro (achado 28/10)
  select * into t from core.tarefas where id = p_tarefa for update;
  if t.status <> 'executando' or t.executor is distinct from p_executor then
    raise exception 'tarefa não está em execução por este executor (status=%)', t.status;
  end if;
  update core.execucoes set status = p_status, fim_em = now(), efeito_externo_id = p_efeito_externo_id,
    evidencia = p_resultado, erro = p_erro
   where tarefa_id = p_tarefa and tentativa = t.tentativas;
  if p_status = 'sucesso' then
    v_novo := 'validando';
    update core.tarefas set status = v_novo, lease_ate = null, resultado = p_resultado, motivo = null where id = p_tarefa;
  elsif p_status = 'incerto' then
    v_novo := 'incerta';
    update core.tarefas set status = v_novo, lease_ate = null, motivo = coalesce(p_erro, 'resultado indeterminado') where id = p_tarefa;
    perform core.abrir_incidente('incerta:' || p_tarefa, 'alta', 'Tarefa em estado incerto', t.agente_id, null, p_tarefa);
  elsif p_status = 'erro' then
    if t.tentativas >= t.max_tentativas then
      v_novo := 'falhou';
      update core.tarefas set status = v_novo, lease_ate = null, motivo = p_erro where id = p_tarefa;
      perform core.abrir_incidente('falha:' || t.agente_id || ':' || t.tipo, 'media',
        'Falhas repetidas em ' || t.tipo, t.agente_id, null, p_tarefa, jsonb_build_object('erro', p_erro));
    else
      v_novo := 'pronta';
      v_back := least(30 * power(2, t.tentativas - 1)::int, 3600);
      update core.tarefas set status = v_novo, lease_ate = null, motivo = p_erro,
        proximo_em = now() + make_interval(secs => v_back) where id = p_tarefa;
    end if;
  else
    raise exception 'status de execução inválido: %', p_status;
  end if;
  return v_novo;
end $$;

create or replace function fin.envio_erro_leitura(p_tarefa uuid, p_executor text, p_erro text) returns text
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare t record; v text;
begin
  p_erro := core._sem_segredo(p_erro);
  select * into t from core.tarefas where id = p_tarefa;
  v := core.registrar_execucao(p_tarefa, p_executor, 'erro', null, null, left(p_erro, 300));
  if v = 'falhou' then
    update fin.envios set status = 'erro', motivo = 'não consegui ler o arquivo: ' || left(p_erro, 200), atualizado_em = now()
     where id = (t.payload->>'envio')::uuid;
  end if;
  return v;
end $$;

-- falhas de leitura da fonte informadas ao Supervisor também passam pelo filtro
create or replace function sup.concluir_verificacao(p_tarefa uuid, p_executor text, p_amostras jsonb default '{}', p_falhas jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = sup, core, pg_catalog as $$
declare t record; v jsonb; k text; am jsonb := '[]';
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'supervisor' or t.tipo is distinct from 'sup_verificacao' then raise exception 'tarefa não é verificação do supervisor'; end if;
  if p_amostras is not null and jsonb_typeof(p_amostras) <> 'object' then raise exception 'amostras inválidas'; end if;
  for k in select jsonb_object_keys(coalesce(p_amostras, '{}')) loop
    am := am || sup.amostra_registrar(p_tarefa, k, p_amostras->k);
  end loop;
  if p_falhas is not null and jsonb_typeof(p_falhas) = 'object' then
    insert into sup.amostras (tarefa_id, agente_id, conferidos, iguais, mudaram_depois, nao_encontrados, divergentes, erro)
    select p_tarefa, f.key, 0, 0, 0, 0, 0, left(regexp_replace(core._sem_segredo(f.value #>> '{}'), '[0-9]{10,13}', '#', 'g'), 200)
    from jsonb_each(p_falhas) f where f.key in ('cobrancas','comercial','laboratorio');
  end if;
  v := sup.verificar(p_tarefa) || jsonb_build_object('amostras', am);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', null, v);
  return v;
end $$;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function core._sem_segredo(text) from anon, authenticated';
    execute 'revoke all on function sup.concluir_verificacao(uuid, text, jsonb, jsonb) from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function sup.concluir_verificacao(uuid, text, jsonb, jsonb) to service_role';
  end if;
end $$;

-- limpa as cópias que já existem (a auditoria guarda o histórico, imutável por desenho)
update core.tarefas set motivo = core._sem_segredo(motivo) where motivo is distinct from core._sem_segredo(motivo);
update core.execucoes set erro = core._sem_segredo(erro) where erro is distinct from core._sem_segredo(erro);
update core.incidentes set detalhes = core._sem_segredo(detalhes::text)::jsonb
 where detalhes is not null and detalhes::text is distinct from core._sem_segredo(detalhes::text);
update fin.envios set motivo = core._sem_segredo(motivo) where motivo is distinct from core._sem_segredo(motivo);
update sup.amostras set erro = core._sem_segredo(erro) where erro is distinct from core._sem_segredo(erro);
