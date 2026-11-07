-- =============================================================================
-- Idealize AI — incidente de falha fecha sozinho quando o agente volta a funcionar  · Migração 20261107010000
-- Pedido do Diego (07/11): depois de corrigido, o incidente deve se atualizar com a data da correção.
--  • Quando uma tarefa termina com sucesso, o incidente "falha:<agente>:<tipo>" daquele agente e tipo é fechado,
--    com detalhes.corrigido_auto = true e detalhes.corrigido_em = hora do sucesso.
--  • Se a mesma falha voltar, o incidente corrigido automaticamente é REABERTO (contador somado e o histórico
--    das correções guardado em detalhes.correcoes), em vez de nascer um incidente novo sem passado.
--    Incidente fechado à mão no painel continua como antes: uma falha nova abre outro incidente.
--  • Os incidentes de falha já abertos e já corrigidos são fechados com a data real do primeiro sucesso depois deles.
-- =============================================================================

create or replace function core._fechar_incidente_corrigido(p_chave text, p_tarefa uuid, p_quando timestamptz)
returns void language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_id bigint;
begin
  select id into v_id from core.incidentes where chave_agrupamento = p_chave and status <> 'resolvido' for update;
  if v_id is null then return; end if;
  update core.incidentes set status = 'resolvido', resolvido_em = p_quando,
    detalhes = coalesce(detalhes, '{}'::jsonb) || jsonb_build_object('corrigido_auto', true,
      'corrigido_em', p_quando, 'corrigido_pela_tarefa', p_tarefa)
   where id = v_id;
  perform core.auditar(null, 'sistema', 'incidente_corrigido', 'incidente', v_id::text,
    jsonb_build_object('status', 'aberto'), jsonb_build_object('status', 'resolvido', 'corrigido_em', p_quando),
    'o agente voltou a rodar com sucesso depois da falha');
end $$;
revoke all on function core._fechar_incidente_corrigido(text, uuid, timestamptz) from public;

create or replace function core.abrir_incidente(p_chave text, p_severidade text, p_titulo text,
  p_agente text default null, p_integracao text default null, p_tarefa uuid default null,
  p_detalhes jsonb default null) returns bigint
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_id bigint; v_sev text; r record;
  ordem constant text[] := array['info','baixa','media','alta','critica'];
begin
  select id, severidade into v_id, v_sev from core.incidentes
   where chave_agrupamento = p_chave and status <> 'resolvido' for update;
  if v_id is null then
    -- a mesma falha voltando depois de uma correção automática reabre o incidente (com o histórico)
    select * into r from core.incidentes
     where chave_agrupamento = p_chave and status = 'resolvido' and coalesce(detalhes->>'corrigido_auto', '') = 'true'
     order by resolvido_em desc nulls last limit 1 for update;
    if r.id is not null then
      update core.incidentes set status = 'aberto', resolvido_em = null, ocorrencias = ocorrencias + 1, ultima_em = now(),
        tarefa_id = coalesce(p_tarefa, tarefa_id),
        escalonado = escalonado or array_position(ordem, p_severidade) > array_position(ordem, severidade),
        severidade = case when array_position(ordem, p_severidade) > array_position(ordem, severidade) then p_severidade else severidade end,
        detalhes = (coalesce(p_detalhes, detalhes, '{}'::jsonb) - 'corrigido_auto' - 'corrigido_em' - 'corrigido_pela_tarefa')
          || jsonb_build_object('correcoes', coalesce(detalhes->'correcoes', '[]'::jsonb)
               || jsonb_build_array(jsonb_build_object('corrigido_em', detalhes->'corrigido_em', 'voltou_em', now())))
       where id = r.id;
      perform core.auditar(null, 'sistema', 'incidente_reaberto', 'incidente', r.id::text,
        jsonb_build_object('status', 'resolvido'), jsonb_build_object('status', 'aberto'), 'a mesma falha voltou depois da correção');
      return r.id;
    end if;
    insert into core.incidentes (chave_agrupamento, severidade, titulo, agente_id, integracao_id, tarefa_id, detalhes)
    values (p_chave, p_severidade, p_titulo, p_agente, p_integracao, p_tarefa, p_detalhes) returning id into v_id;
    perform core.auditar(null, 'sistema', 'incidente_aberto', 'incidente', v_id::text, null,
      jsonb_build_object('severidade', p_severidade, 'titulo', p_titulo));
  else
    update core.incidentes set ocorrencias = ocorrencias + 1, ultima_em = now(),
      escalonado = escalonado or array_position(ordem, p_severidade) > array_position(ordem, v_sev),
      severidade = case when array_position(ordem, p_severidade) > array_position(ordem, v_sev) then p_severidade else severidade end,
      detalhes = coalesce(p_detalhes, detalhes)
    where id = v_id;
  end if;
  return v_id;
end $$;

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
    -- o agente voltou a funcionar: o incidente de falhas repetidas deste agente/tipo fecha com a data da correção (07/11)
    perform core._fechar_incidente_corrigido('falha:' || t.agente_id || ':' || t.tipo, p_tarefa, now());
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

-- incidentes de falha que já estão abertos mas cujo agente já voltou a rodar bem: fecha com a data real da correção
do $$ declare r record; begin
  for r in
    select i.chave_agrupamento, s.tarefa_id, s.fim_em
      from core.incidentes i
      join core.tarefas ti on ti.id = i.tarefa_id
      cross join lateral (
        select e.tarefa_id, e.fim_em from core.execucoes e join core.tarefas t on t.id = e.tarefa_id
         where t.agente_id = ti.agente_id and t.tipo = ti.tipo and e.status = 'sucesso' and e.fim_em > i.ultima_em
         order by e.fim_em limit 1) s
     where i.status <> 'resolvido' and i.chave_agrupamento = 'falha:' || ti.agente_id || ':' || ti.tipo
  loop
    perform core._fechar_incidente_corrigido(r.chave_agrupamento, r.tarefa_id, r.fim_em);
  end loop;
end $$;
