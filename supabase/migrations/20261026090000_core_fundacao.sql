-- =============================================================================
-- Idealize AI — Fundação reutilizável (schema core)
-- Migração 20261026090000 — v0.1.0
--
-- Escopo: unidades, departamentos, agentes, principais (usuários e agentes),
-- matriz de autorização versionada, motor de tarefas (fila, lease, idempotência,
-- dependências, retentativas seguras, estado "incerta"), aprovações vinculadas
-- à operação (hash), validação independente, auditoria append-only com cadeia
-- de hash, incidentes agrupados, custos com limite, integrações e kill switch.
--
-- Segurança: schema NÃO exposto ao PostgREST; RLS ligado sem políticas em todas
-- as tabelas; funções SECURITY DEFINER com search_path fixo; EXECUTE só para
-- service_role. Nenhum dado de produção é tocado por esta migração.
-- =============================================================================

create schema if not exists core;
revoke all on schema core from public;

-- ---------------------------------------------------------------------------
-- 1. Cadastros
-- ---------------------------------------------------------------------------
create table core.unidades (
  id        text primary key check (id ~ '^[a-z0-9_]{2,40}$'),
  nome      text not null,
  ativo     boolean not null default true,
  criado_em timestamptz not null default now()
);

create table core.departamentos (
  id        text primary key check (id ~ '^[a-z0-9_]{2,40}$'),
  nome      text not null,
  ativo     boolean not null default true
);

create table core.agentes (
  id                  text primary key check (id ~ '^[a-z0-9_]{2,40}$'),
  nome                text not null,
  departamento_id     text not null references core.departamentos(id),
  status              text not null default 'pausado'
                      check (status in ('ativo','pausado','indisponivel','desativado')),
  versao              text not null default '0.0.0',
  limite_custo_mensal numeric(12,2),            -- null = sem limite configurado
  descricao           text,
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now()
);

-- Principal = quem age: pessoa (usuario) ou agente. Toda autorização parte daqui.
create table core.principais (
  id         uuid primary key default gen_random_uuid(),
  tipo       text not null check (tipo in ('usuario','agente')),
  nome       text not null,
  auth_uid   uuid unique,                        -- usuário do Supabase Auth (painel)
  telefone   text unique check (telefone ~ '^[0-9]{10,15}$'),
  agente_id  text unique references core.agentes(id),
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now(),
  check ((tipo = 'agente') = (agente_id is not null))
);

create table core.papeis (
  id    text primary key check (id ~ '^[a-z0-9_]{2,40}$'),
  nome  text not null
);

-- Papel do principal, opcionalmente restrito a uma unidade (null = todas)
create table core.principal_papeis (
  principal_id uuid not null references core.principais(id),
  papel_id     text not null references core.papeis(id),
  unidade_id   text references core.unidades(id),
  valido_ate   timestamptz,
  criado_em    timestamptz not null default now()
);
create unique index principal_papeis_uk
  on core.principal_papeis (principal_id, papel_id, coalesce(unidade_id, '*'));

-- ---------------------------------------------------------------------------
-- 2. Matriz de autorização (versionada; agentes nunca escrevem aqui)
-- ---------------------------------------------------------------------------
create table core.politicas (
  id                  bigserial primary key,
  versao              int not null default 1,
  papel_id            text not null references core.papeis(id),
  recurso             text not null,             -- ex.: finance.lancamento
  operacao            text not null,             -- ex.: registrar, consultar
  unidade_id          text references core.unidades(id),   -- null = todas
  departamento_id     text references core.departamentos(id),
  risco               text not null check (risco in ('baixo','medio','alto','critico')),
  categoria           text not null check (categoria in ('automatica','aprovacao','proibida')),
  limite_valor        numeric(14,2),             -- acima disso a automática vira aprovação
  aprovadores_minimos int not null default 1 check (aprovadores_minimos between 1 and 5),
  papel_aprovador     text references core.papeis(id),
  aprovacao_validade  interval not null default interval '24 hours',
  valido_de           timestamptz not null default now(),
  valido_ate          timestamptz,
  ativo               boolean not null default true,
  criado_por          uuid references core.principais(id),
  criado_em           timestamptz not null default now(),
  check (categoria <> 'aprovacao' or papel_aprovador is not null)
);
create index politicas_busca on core.politicas (papel_id, recurso, operacao) where ativo;

-- ---------------------------------------------------------------------------
-- 3. Configuração, integrações
-- ---------------------------------------------------------------------------
create table core.config (
  chave         text primary key,
  valor         text not null,
  atualizado_em timestamptz not null default now()
);

create table core.integracoes (
  id                text primary key,
  nome              text not null,
  status            text not null default 'nao_verificada'
                    check (status in ('nao_verificada','ok','degradada','indisponivel','isolada')),
  escrita_habilitada boolean not null default false,  -- leitura primeiro, sempre
  credencial_leitura text,                -- NOME do segredo no Vault, nunca o valor
  credencial_escrita text,
  ultimo_ok_em      timestamptz,
  observacoes       text
);

-- ---------------------------------------------------------------------------
-- 4. Motor de tarefas
-- ---------------------------------------------------------------------------
create table core.tarefas (
  id                 uuid primary key default gen_random_uuid(),
  correlacao_id      uuid not null default gen_random_uuid(),
  chave_idempotencia text not null unique,
  agente_id          text not null references core.agentes(id),
  tipo               text not null,
  recurso            text not null,
  operacao           text not null,
  unidade_id         text references core.unidades(id),
  payload            jsonb not null default '{}'::jsonb,
  valor              numeric(14,2),
  hash_operacao      text not null,          -- aprovações ficam presas a este hash
  prioridade         int not null default 5 check (prioridade between 1 and 9), -- 1 = crítica
  risco              text not null default 'baixo',
  categoria          text not null,          -- resultado da autorização na criação
  politica_id        bigint references core.politicas(id),
  status             text not null default 'pendente' check (status in (
                       'pendente','aguardando_aprovacao','pronta','executando','validando',
                       'concluida','falhou','bloqueada','incerta','cancelada','rejeitada')),
  monitoramento      boolean not null default false, -- pode rodar com plataforma pausada
  tentativas         int not null default 0,
  max_tentativas     int not null default 3 check (max_tentativas between 1 and 10),
  prazo              timestamptz,
  proximo_em         timestamptz not null default now(),
  lease_ate          timestamptz,
  executor           text,
  resultado          jsonb,
  motivo             text,
  solicitante_id     uuid references core.principais(id),
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now()
);
create index tarefas_fila on core.tarefas (agente_id, prioridade, criado_em)
  where status = 'pronta';
create index tarefas_lease on core.tarefas (lease_ate) where status = 'executando';
create index tarefas_correlacao on core.tarefas (correlacao_id);

create table core.tarefa_dependencias (
  tarefa_id  uuid not null references core.tarefas(id),
  depende_de uuid not null references core.tarefas(id),
  primary key (tarefa_id, depende_de),
  check (tarefa_id <> depende_de)
);

create table core.execucoes (
  id                 bigserial primary key,
  tarefa_id          uuid not null references core.tarefas(id),
  tentativa          int not null,
  executor           text not null,
  inicio_em          timestamptz not null default now(),
  fim_em             timestamptz,
  status             text not null default 'em_andamento'
                     check (status in ('em_andamento','sucesso','erro','incerto','lease_expirado')),
  efeito_externo_id  text,     -- id devolvido pelo sistema externo (prova de efetivação)
  evidencia          jsonb,
  erro               text,
  unique (tarefa_id, tentativa)
);

create table core.aprovacoes (
  id            bigserial primary key,
  tarefa_id     uuid not null references core.tarefas(id),
  aprovador_id  uuid not null references core.principais(id),
  decisao       text not null check (decisao in ('aprovar','rejeitar')),
  hash_operacao text not null,
  canal         text not null default 'painel' check (canal in ('painel','whatsapp','api')),
  comentario    text,
  expira_em     timestamptz not null,
  criado_em     timestamptz not null default now(),
  unique (tarefa_id, aprovador_id)
);

create table core.validacoes (
  id         bigserial primary key,
  tarefa_id  uuid not null references core.tarefas(id),
  validador  text not null,
  resultado  text not null check (resultado in ('aprovada','rejeitada')),
  motivo     text,
  evidencia  jsonb,
  em         timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 5. Incidentes e custos
-- ---------------------------------------------------------------------------
create table core.incidentes (
  id                 bigserial primary key,
  chave_agrupamento  text not null,
  severidade         text not null check (severidade in ('info','baixa','media','alta','critica')),
  status             text not null default 'aberto' check (status in ('aberto','em_tratamento','resolvido')),
  titulo             text not null,
  agente_id          text references core.agentes(id),
  integracao_id      text references core.integracoes(id),
  tarefa_id          uuid references core.tarefas(id),
  ocorrencias        int not null default 1,
  escalonado         boolean not null default false,  -- severidade subiu desde o último alerta
  primeira_em        timestamptz not null default now(),
  ultima_em          timestamptz not null default now(),
  resolvido_em       timestamptz,
  detalhes           jsonb
);
create unique index incidentes_abertos_uk on core.incidentes (chave_agrupamento) where status <> 'resolvido';

create table core.custos (
  id           bigserial primary key,
  agente_id    text not null references core.agentes(id),
  unidade_id   text references core.unidades(id),
  tarefa_id    uuid references core.tarefas(id),
  tipo_tarefa  text,
  modelo       text,
  integracao   text,
  tokens_in    int,
  tokens_out   int,
  valor        numeric(12,4) not null check (valor >= 0),
  confirmado   boolean not null default false,  -- estimado ≠ confirmado
  em           timestamptz not null default now()
);
create index custos_agente_mes on core.custos (agente_id, em);

-- ---------------------------------------------------------------------------
-- 6. Auditoria append-only com cadeia de hash
-- ---------------------------------------------------------------------------
create sequence core.auditoria_id_seq;
create table core.auditoria (
  id            bigint primary key,   -- atribuído pelo trigger, sob lock (sem lacunas, ordem = cadeia)
  em            timestamptz not null default clock_timestamp(),
  ator_id       uuid,
  ator          text,               -- nome/identificador legível do ator ou serviço
  acao          text not null,
  entidade      text not null,
  entidade_id   text,
  antes         jsonb,
  depois        jsonb,
  motivo        text,
  hash_anterior text not null,
  hash          text not null
);

create or replace function core._aud_encadear() returns trigger
language plpgsql set search_path = core, pg_catalog as $$
declare ant text;
begin
  perform pg_advisory_xact_lock(hashtext('core.auditoria'));
  -- o id é sorteado AQUI, depois do lock: ordem do id = ordem da cadeia, mesmo com concorrência
  new.id := nextval('core.auditoria_id_seq');
  select hash into ant from core.auditoria order by id desc limit 1;
  new.hash_anterior := coalesce(ant, repeat('0', 64));
  new.em := clock_timestamp();
  new.hash := encode(sha256(convert_to(
    new.hash_anterior || '|' || extract(epoch from new.em)::text || '|' || coalesce(new.ator_id::text,'') || '|' ||
    coalesce(new.ator,'') || '|' || new.acao || '|' || new.entidade || '|' ||
    coalesce(new.entidade_id,'') || '|' || coalesce(new.antes::text,'') || '|' ||
    coalesce(new.depois::text,'') || '|' || coalesce(new.motivo,''), 'UTF8')), 'hex');
  return new;
end $$;
create trigger aud_encadear before insert on core.auditoria
  for each row execute function core._aud_encadear();

create or replace function core._aud_imutavel() returns trigger
language plpgsql as $$
begin
  raise exception 'core.auditoria é append-only (% bloqueado)', tg_op using errcode = '42501';
end $$;
create trigger aud_sem_update before update or delete on core.auditoria
  for each row execute function core._aud_imutavel();
create trigger aud_sem_truncate before truncate on core.auditoria
  for each statement execute function core._aud_imutavel();

create or replace function core.auditar(p_ator_id uuid, p_ator text, p_acao text, p_entidade text,
  p_entidade_id text, p_antes jsonb, p_depois jsonb, p_motivo text default null) returns void
language sql security definer set search_path = core, pg_catalog as $$
  insert into core.auditoria (ator_id, ator, acao, entidade, entidade_id, antes, depois, motivo, hash_anterior, hash)
  values (p_ator_id, p_ator, p_acao, p_entidade, p_entidade_id, p_antes, p_depois, p_motivo, '', '');
$$;

-- Recalcula a cadeia inteira; devolve o primeiro id adulterado (null = íntegra)
create or replace function core.verificar_auditoria() returns bigint
language plpgsql stable security definer set search_path = core, pg_catalog as $$
declare r record; ant text := repeat('0', 64); calc text;
begin
  for r in select * from core.auditoria order by id loop
    calc := encode(sha256(convert_to(
      ant || '|' || extract(epoch from r.em)::text || '|' || coalesce(r.ator_id::text,'') || '|' ||
      coalesce(r.ator,'') || '|' || r.acao || '|' || r.entidade || '|' ||
      coalesce(r.entidade_id,'') || '|' || coalesce(r.antes::text,'') || '|' ||
      coalesce(r.depois::text,'') || '|' || coalesce(r.motivo,''), 'UTF8')), 'hex');
    if r.hash_anterior <> ant or r.hash <> calc then return r.id; end if;
    ant := r.hash;
  end loop;
  return null;
end $$;

-- Toda mudança de status de tarefa e de política vira trilha de auditoria
create or replace function core._aud_tarefa() returns trigger
language plpgsql security definer set search_path = core, pg_catalog as $$
begin
  new.atualizado_em := now();
  if tg_op = 'INSERT' then
    perform core.auditar(new.solicitante_id, null, 'tarefa_criada', 'tarefa', new.id::text, null,
      jsonb_build_object('status', new.status, 'agente', new.agente_id, 'operacao', new.recurso||'.'||new.operacao,
                         'unidade', new.unidade_id, 'valor', new.valor, 'categoria', new.categoria), new.motivo);
  elsif new.status is distinct from old.status then
    perform core.auditar(null, new.executor, 'tarefa_status', 'tarefa', new.id::text,
      jsonb_build_object('status', old.status), jsonb_build_object('status', new.status, 'tentativas', new.tentativas), new.motivo);
  end if;
  return new;
end $$;
create trigger aud_tarefa_ins after insert on core.tarefas for each row execute function core._aud_tarefa();
create trigger aud_tarefa_upd before update on core.tarefas for each row execute function core._aud_tarefa();

create or replace function core._aud_generico() returns trigger
language plpgsql security definer set search_path = core, pg_catalog as $$
begin
  perform core.auditar(null, current_user, lower(tg_op), tg_table_name,
    coalesce((case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id',
             (case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'chave'),
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return coalesce(new, old);
end $$;
create trigger aud_politicas after insert or update or delete on core.politicas
  for each row execute function core._aud_generico();
create trigger aud_principal_papeis after insert or update or delete on core.principal_papeis
  for each row execute function core._aud_generico();
create trigger aud_agentes after insert or update or delete on core.agentes
  for each row execute function core._aud_generico();
create trigger aud_config after insert or update or delete on core.config
  for each row execute function core._aud_generico();
create trigger aud_integracoes after insert or update or delete on core.integracoes
  for each row execute function core._aud_generico();

-- Políticas nunca são apagadas: desative criando nova versão
create or replace function core._politica_sem_delete() returns trigger language plpgsql as $$
begin raise exception 'políticas não são apagadas; desative (ativo=false)' using errcode='42501'; end $$;
create trigger politicas_sem_delete before delete on core.politicas
  for each row execute function core._politica_sem_delete();

-- ---------------------------------------------------------------------------
-- 7. Helpers
-- ---------------------------------------------------------------------------
create or replace function core.cfg(p_chave text, p_padrao text default null) returns text
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce((select valor from core.config where chave = p_chave), p_padrao);
$$;

create or replace function core.hash_operacao(p_recurso text, p_operacao text, p_unidade text,
  p_valor numeric, p_payload jsonb) returns text
language sql immutable set search_path = core, pg_catalog as $$
  select encode(sha256(convert_to(p_recurso||'|'||p_operacao||'|'||coalesce(p_unidade,'*')||'|'||
    coalesce(p_valor::text,'')||'|'||coalesce(p_payload::text,'{}'), 'UTF8')), 'hex');
$$;

create or replace function core.custo_mes(p_agente text) returns numeric
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(sum(valor), 0) from core.custos
  where agente_id = p_agente and em >= date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
$$;

-- Abre ou agrupa incidente; marca escalonamento quando a severidade sobe
create or replace function core.abrir_incidente(p_chave text, p_severidade text, p_titulo text,
  p_agente text default null, p_integracao text default null, p_tarefa uuid default null,
  p_detalhes jsonb default null) returns bigint
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_id bigint; v_sev text;
  ordem constant text[] := array['info','baixa','media','alta','critica'];
begin
  select id, severidade into v_id, v_sev from core.incidentes
   where chave_agrupamento = p_chave and status <> 'resolvido' for update;
  if v_id is null then
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

-- ---------------------------------------------------------------------------
-- 8. Autorização (negação por padrão)
-- ---------------------------------------------------------------------------
create or replace function core.autorizar(p_principal uuid, p_recurso text, p_operacao text,
  p_unidade text, p_valor numeric default null,
  out categoria text, out politica_id bigint, out motivo text)
language plpgsql stable security definer set search_path = core, pg_catalog as $$
declare p record; v_ativo boolean;
begin
  select pr.ativo into v_ativo from core.principais pr where pr.id = p_principal;
  if v_ativo is distinct from true then
    categoria := 'proibida'; motivo := 'principal inexistente ou inativo'; return;
  end if;
  if p_unidade is not null and not exists (select 1 from core.unidades u where u.id = p_unidade and u.ativo) then
    categoria := 'proibida'; motivo := 'unidade inexistente ou inativa'; return;
  end if;

  -- políticas aplicáveis: papel vigente do principal, escopo de unidade compatível nos dois lados
  for p in
    select po.* from core.politicas po
    join core.principal_papeis pp on pp.papel_id = po.papel_id and pp.principal_id = p_principal
    where po.ativo and po.recurso = p_recurso and po.operacao = p_operacao
      and po.valido_de <= now() and (po.valido_ate is null or po.valido_ate > now())
      and (pp.valido_ate is null or pp.valido_ate > now())
      and (pp.unidade_id is null or pp.unidade_id = p_unidade)
      and (po.unidade_id is null or po.unidade_id = p_unidade)
    order by case po.categoria when 'proibida' then 0 when 'automatica' then 1 else 2 end, po.id
  loop
    if p.categoria = 'proibida' then
      categoria := 'proibida'; politica_id := p.id; motivo := 'política proíbe a operação'; return;
    end if;
    if p.categoria = 'automatica' and (p.limite_valor is null or coalesce(p_valor, 0) <= p.limite_valor) then
      categoria := 'automatica'; politica_id := p.id; motivo := 'autorizada automaticamente'; return;
    end if;
    if p.categoria = 'aprovacao' and categoria is null then
      categoria := 'aprovacao'; politica_id := p.id; motivo := 'exige aprovação';
    end if;
    if p.categoria = 'automatica' and categoria is null then
      motivo := 'acima do limite automático'; -- continua procurando política de aprovação
    end if;
  end loop;

  if categoria is null then
    categoria := 'proibida'; motivo := coalesce(motivo || '; ', '') || 'nenhuma política autoriza (negação por padrão)';
  end if;
end $$;

-- Só pessoa com papel admin altera a matriz. Agentes são recusados.
create or replace function core.politica_definir(p_ator uuid, p_papel text, p_recurso text, p_operacao text,
  p_categoria text, p_risco text, p_unidade text default null, p_limite numeric default null,
  p_aprovadores int default 1, p_papel_aprovador text default null) returns bigint
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_tipo text; v_id bigint; v_versao int;
begin
  select tipo into v_tipo from core.principais where id = p_ator and ativo;
  if v_tipo is distinct from 'usuario' then
    raise exception 'somente pessoas alteram a matriz de permissões' using errcode = '42501';
  end if;
  if not exists (select 1 from core.principal_papeis where principal_id = p_ator and papel_id = 'admin'
                 and unidade_id is null and (valido_ate is null or valido_ate > now())) then
    raise exception 'ator sem papel admin global' using errcode = '42501';
  end if;
  select coalesce(max(versao), 0) + 1 into v_versao from core.politicas
   where papel_id = p_papel and recurso = p_recurso and operacao = p_operacao and unidade_id is not distinct from p_unidade;
  update core.politicas set ativo = false, valido_ate = now()
   where ativo and papel_id = p_papel and recurso = p_recurso and operacao = p_operacao and unidade_id is not distinct from p_unidade;
  insert into core.politicas (versao, papel_id, recurso, operacao, unidade_id, risco, categoria, limite_valor,
    aprovadores_minimos, papel_aprovador, criado_por)
  values (v_versao, p_papel, p_recurso, p_operacao, p_unidade, p_risco, p_categoria, p_limite,
    p_aprovadores, p_papel_aprovador, p_ator) returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 9. Orquestração de tarefas
-- ---------------------------------------------------------------------------
create or replace function core.criar_tarefa(
  p_solicitante uuid, p_agente text, p_tipo text, p_recurso text, p_operacao text,
  p_unidade text, p_payload jsonb, p_chave_idempotencia text,
  p_valor numeric default null, p_prioridade int default 5, p_correlacao uuid default null,
  p_depende_de uuid[] default '{}', p_prazo timestamptz default null, p_monitoramento boolean default false)
returns uuid
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_id uuid; v_ag record; v_principal uuid; a record; v_status text; v_motivo text; v_lim numeric;
begin
  if p_chave_idempotencia is null or length(p_chave_idempotencia) < 8 then
    raise exception 'chave de idempotência obrigatória (mín. 8 caracteres)';
  end if;
  -- idempotência: mesma chave devolve a mesma tarefa, sem recriar
  select id into v_id from core.tarefas where chave_idempotencia = p_chave_idempotencia;
  if v_id is not null then return v_id; end if;

  select * into v_ag from core.agentes where id = p_agente;
  if v_ag is null then raise exception 'agente % inexistente', p_agente; end if;
  select id into v_principal from core.principais where agente_id = p_agente;

  -- quem solicita precisa existir e estar ativo (nunca anônimo)
  if p_solicitante is null or not exists (select 1 from core.principais where id = p_solicitante and ativo) then
    raise exception 'solicitante inexistente ou inativo' using errcode = '42501';
  end if;

  -- o agente executor precisa de autorização para a operação nessa unidade
  select * into a from core.autorizar(v_principal, p_recurso, p_operacao, p_unidade, p_valor);

  if a.categoria = 'proibida' then
    v_status := 'rejeitada'; v_motivo := a.motivo;
  elsif v_ag.status <> 'ativo' then
    v_status := 'bloqueada'; v_motivo := 'agente ' || v_ag.status;
  elsif core.cfg('plataforma_pausada', 'false') = 'true' and not p_monitoramento then
    v_status := 'bloqueada'; v_motivo := 'plataforma pausada (modo seguro)';
  else
    v_lim := v_ag.limite_custo_mensal;
    if v_lim is not null and core.custo_mes(p_agente) >= v_lim and p_prioridade > 1 then
      v_status := 'bloqueada'; v_motivo := 'limite de custo mensal do agente atingido';
    elsif a.categoria = 'aprovacao' then
      v_status := 'aguardando_aprovacao'; v_motivo := a.motivo;
    else
      v_status := 'pronta'; v_motivo := a.motivo;
    end if;
  end if;

  insert into core.tarefas (chave_idempotencia, correlacao_id, agente_id, tipo, recurso, operacao, unidade_id,
    payload, valor, hash_operacao, prioridade, risco, categoria, politica_id, status, motivo,
    solicitante_id, prazo, monitoramento)
  values (p_chave_idempotencia, coalesce(p_correlacao, gen_random_uuid()), p_agente, p_tipo, p_recurso, p_operacao,
    p_unidade, coalesce(p_payload, '{}'::jsonb), p_valor,
    core.hash_operacao(p_recurso, p_operacao, p_unidade, p_valor, coalesce(p_payload,'{}'::jsonb)),
    p_prioridade, coalesce((select risco from core.politicas where id = a.politica_id), 'alto'),
    a.categoria, a.politica_id, v_status, v_motivo, p_solicitante, p_prazo, p_monitoramento)
  returning id into v_id;

  insert into core.tarefa_dependencias (tarefa_id, depende_de)
  select v_id, d from unnest(coalesce(p_depende_de, '{}')) d;

  if v_status = 'bloqueada' and v_motivo like 'limite de custo%' then
    perform core.abrir_incidente('custo:' || p_agente, 'media', 'Limite de custo mensal atingido', p_agente);
  end if;
  return v_id;
end $$;

-- Decisão humana, presa ao hash exato da operação. Agentes nunca aprovam.
create or replace function core.aprovar(p_tarefa uuid, p_aprovador uuid, p_decisao text,
  p_hash_visto text, p_canal text default 'painel', p_comentario text default null) returns text
language plpgsql security definer set search_path = core, pg_catalog as $$
declare t record; po record; v_tipo text; v_validos int;
begin
  select * into t from core.tarefas where id = p_tarefa for update;
  if t is null then raise exception 'tarefa inexistente'; end if;
  if t.status <> 'aguardando_aprovacao' then
    raise exception 'tarefa não está aguardando aprovação (status=%)', t.status;
  end if;
  select tipo into v_tipo from core.principais where id = p_aprovador and ativo;
  if v_tipo is distinct from 'usuario' then
    raise exception 'somente pessoas ativas aprovam' using errcode = '42501';
  end if;
  if p_aprovador = t.solicitante_id then
    raise exception 'quem solicitou não pode aprovar a própria operação' using errcode = '42501';
  end if;
  if p_hash_visto is distinct from t.hash_operacao then
    raise exception 'aprovação não corresponde à operação atual (hash divergente)' using errcode = '42501';
  end if;
  select * into po from core.politicas where id = t.politica_id;
  if not exists (select 1 from core.principal_papeis pp where pp.principal_id = p_aprovador
       and pp.papel_id = po.papel_aprovador and (pp.unidade_id is null or pp.unidade_id = t.unidade_id)
       and (pp.valido_ate is null or pp.valido_ate > now())) then
    raise exception 'aprovador fora da alçada' using errcode = '42501';
  end if;

  insert into core.aprovacoes (tarefa_id, aprovador_id, decisao, hash_operacao, canal, comentario, expira_em)
  values (p_tarefa, p_aprovador, p_decisao, p_hash_visto, p_canal, p_comentario, now() + po.aprovacao_validade);
  perform core.auditar(p_aprovador, null, 'aprovacao_' || p_decisao, 'tarefa', p_tarefa::text, null,
    jsonb_build_object('canal', p_canal, 'hash', p_hash_visto), p_comentario);

  if p_decisao = 'rejeitar' then
    update core.tarefas set status = 'rejeitada', motivo = 'rejeitada por aprovador' where id = p_tarefa;
    return 'rejeitada';
  end if;

  select count(*) into v_validos from core.aprovacoes
   where tarefa_id = p_tarefa and decisao = 'aprovar' and hash_operacao = t.hash_operacao and expira_em > now();
  if v_validos >= po.aprovadores_minimos then
    update core.tarefas set status = 'pronta', motivo = 'aprovada (' || v_validos || ')' where id = p_tarefa;
    return 'pronta';
  end if;
  return 'aguardando_aprovacao';
end $$;

-- Reivindica a próxima tarefa (lease). Lease vencido NUNCA é reexecutado às cegas: vira 'incerta'.
create or replace function core.reivindicar(p_agente text, p_executor text, p_lease_segundos int default 120)
returns setof core.tarefas
language plpgsql security definer set search_path = core, pg_catalog as $$
declare t core.tarefas; a record; v_principal uuid; po record; v_validos int; v_pausada boolean;
begin
  -- 1) leases vencidos → estado de incerteza + incidente (exige reconciliação)
  for t in select * from core.tarefas where status = 'executando' and lease_ate < now() for update skip locked loop
    update core.execucoes set status = 'lease_expirado', fim_em = now()
     where tarefa_id = t.id and status = 'em_andamento';
    update core.tarefas set status = 'incerta', lease_ate = null,
      motivo = 'execução interrompida: verificar se o efeito externo ocorreu' where id = t.id;
    perform core.abrir_incidente('incerta:' || t.id, 'alta', 'Tarefa em estado incerto', t.agente_id, null, t.id);
  end loop;

  if exists (select 1 from core.agentes where id = p_agente and status <> 'ativo') then return; end if;
  v_pausada := core.cfg('plataforma_pausada', 'false') = 'true';
  select id into v_principal from core.principais where agente_id = p_agente;

  loop
    select * into t from core.tarefas x
     where x.agente_id = p_agente and x.status = 'pronta' and x.proximo_em <= now()
       and (not v_pausada or x.monitoramento)
       and not exists (select 1 from core.tarefa_dependencias d join core.tarefas dt on dt.id = d.depende_de
                        where d.tarefa_id = x.id and dt.status <> 'concluida')
     order by x.prioridade, x.criado_em
     limit 1 for update skip locked;
    if t.id is null then return; end if;

    -- 2) revalida autorização imediatamente antes de executar
    select * into a from core.autorizar(v_principal, t.recurso, t.operacao, t.unidade_id, t.valor);
    if a.categoria = 'proibida' then
      update core.tarefas set status = 'bloqueada', motivo = 'revalidação negou: ' || a.motivo where id = t.id;
      continue;
    end if;
    if t.categoria = 'aprovacao' then
      select * into po from core.politicas where id = t.politica_id;
      select count(*) into v_validos from core.aprovacoes
       where tarefa_id = t.id and decisao = 'aprovar' and hash_operacao = t.hash_operacao and expira_em > now();
      if v_validos < coalesce(po.aprovadores_minimos, 1) then
        update core.tarefas set status = 'aguardando_aprovacao', motivo = 'aprovação expirada; reaprovar' where id = t.id;
        continue;
      end if;
    end if;

    update core.tarefas set status = 'executando', tentativas = tentativas + 1, executor = p_executor,
      lease_ate = now() + make_interval(secs => p_lease_segundos)
     where id = t.id returning * into t;
    insert into core.execucoes (tarefa_id, tentativa, executor) values (t.id, t.tentativas, p_executor);
    return next t;
    return;
  end loop;
end $$;

-- Resultado de uma execução.
--  sucesso  → validando (nunca conclui direto)
--  erro     → só use quando é CERTO que nada foi efetivado fora; retenta com backoff
--  incerto  → timeout/queda após possível escrita externa → incerta + incidente
create or replace function core.registrar_execucao(p_tarefa uuid, p_executor text, p_status text,
  p_efeito_externo_id text default null, p_resultado jsonb default null, p_erro text default null) returns text
language plpgsql security definer set search_path = core, pg_catalog as $$
declare t record; v_novo text; v_back int;
begin
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
      v_back := least(30 * power(2, t.tentativas - 1)::int, 3600);  -- 30s, 60s, 120s… máx 1h
      update core.tarefas set status = v_novo, lease_ate = null, motivo = p_erro,
        proximo_em = now() + make_interval(secs => v_back) where id = p_tarefa;
    end if;
  else
    raise exception 'status de execução inválido: %', p_status;
  end if;
  return v_novo;
end $$;

-- Validador independente: não pode ser o mesmo executor da tarefa
create or replace function core.registrar_validacao(p_tarefa uuid, p_validador text, p_aprovada boolean,
  p_motivo text default null, p_evidencia jsonb default null) returns text
language plpgsql security definer set search_path = core, pg_catalog as $$
declare t record;
begin
  select * into t from core.tarefas where id = p_tarefa for update;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  if p_validador = t.executor then
    raise exception 'o executor não pode validar a própria execução' using errcode = '42501';
  end if;
  if not p_aprovada and coalesce(p_motivo, '') = '' then
    raise exception 'rejeição exige motivo';
  end if;
  insert into core.validacoes (tarefa_id, validador, resultado, motivo, evidencia)
  values (p_tarefa, p_validador, case when p_aprovada then 'aprovada' else 'rejeitada' end, p_motivo, p_evidencia);
  if p_aprovada then
    update core.tarefas set status = 'concluida', motivo = null where id = p_tarefa;
    return 'concluida';
  end if;
  update core.tarefas set status = 'bloqueada', motivo = 'validação rejeitada: ' || p_motivo where id = p_tarefa;
  return 'bloqueada';
end $$;

-- Reconciliação humana de tarefa incerta
create or replace function core.reconciliar(p_tarefa uuid, p_ator uuid, p_efetivada boolean,
  p_evidencia jsonb, p_motivo text) returns text
language plpgsql security definer set search_path = core, pg_catalog as $$
declare t record;
begin
  if not exists (select 1 from core.principais where id = p_ator and tipo = 'usuario' and ativo) then
    raise exception 'reconciliação é humana' using errcode = '42501';
  end if;
  if coalesce(p_motivo,'') = '' or p_evidencia is null then raise exception 'reconciliação exige motivo e evidência'; end if;
  select * into t from core.tarefas where id = p_tarefa for update;
  if t.status <> 'incerta' then raise exception 'tarefa não está incerta (status=%)', t.status; end if;
  perform core.auditar(p_ator, null, 'reconciliacao', 'tarefa', p_tarefa::text, null,
    jsonb_build_object('efetivada', p_efetivada, 'evidencia', p_evidencia), p_motivo);
  if p_efetivada then
    update core.tarefas set status = 'validando', resultado = p_evidencia, motivo = p_motivo where id = p_tarefa;
    return 'validando';
  end if;
  update core.tarefas set status = 'pronta', proximo_em = now(), motivo = p_motivo where id = p_tarefa;
  return 'pronta';
end $$;

create or replace function core.cancelar_tarefa(p_tarefa uuid, p_ator uuid, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare t record;
begin
  if not exists (select 1 from core.principais where id = p_ator and tipo = 'usuario' and ativo) then
    raise exception 'cancelamento é humano' using errcode = '42501';
  end if;
  select * into t from core.tarefas where id = p_tarefa for update;
  if t.status in ('executando','validando','concluida','incerta') then
    raise exception 'não é possível cancelar no status %', t.status;
  end if;
  update core.tarefas set status = 'cancelada', motivo = p_motivo where id = p_tarefa;
end $$;

create or replace function core.registrar_custo(p_agente text, p_valor numeric, p_confirmado boolean,
  p_modelo text default null, p_tarefa uuid default null, p_unidade text default null,
  p_tokens_in int default null, p_tokens_out int default null, p_tipo text default null) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_lim numeric; v_total numeric;
begin
  insert into core.custos (agente_id, valor, confirmado, modelo, tarefa_id, unidade_id, tokens_in, tokens_out, tipo_tarefa)
  values (p_agente, p_valor, p_confirmado, p_modelo, p_tarefa, p_unidade, p_tokens_in, p_tokens_out, p_tipo);
  select limite_custo_mensal into v_lim from core.agentes where id = p_agente;
  v_total := core.custo_mes(p_agente);
  if v_lim is not null and v_total >= v_lim * 0.8 then
    perform core.abrir_incidente('custo:' || p_agente,
      case when v_total >= v_lim then 'media' else 'baixa' end,
      'Consumo do agente em ' || round(100 * v_total / v_lim) || '% do limite mensal', p_agente);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Visões para o painel (leitura) — expostas só via RPC no futuro
-- ---------------------------------------------------------------------------
create or replace view core.v_agentes_status as
select a.id, a.nome, a.departamento_id, a.status, a.versao, a.limite_custo_mensal,
  core.custo_mes(a.id) as custo_mes,
  (select max(atualizado_em) from core.tarefas t where t.agente_id = a.id) as ultima_atividade,
  count(*) filter (where t.status = 'concluida') as concluidas,
  count(*) filter (where t.status in ('pendente','pronta','executando','validando')) as em_andamento,
  count(*) filter (where t.status = 'aguardando_aprovacao') as aguardando_aprovacao,
  count(*) filter (where t.status in ('bloqueada','incerta')) as bloqueadas,
  count(*) filter (where t.status = 'falhou') as falhas,
  (select count(*) from core.incidentes i where i.agente_id = a.id and i.status <> 'resolvido') as incidentes_abertos
from core.agentes a left join core.tarefas t on t.agente_id = a.id
group by a.id;

-- ---------------------------------------------------------------------------
-- 11. Endurecimento
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'core' loop
    execute format('alter table core.%I enable row level security', r.tablename);
    execute format('alter table core.%I force row level security', r.tablename);
  end loop;
end $$;

revoke all on all tables in schema core from public;
revoke all on all sequences in schema core from public;
alter sequence core.auditoria_id_seq owned by core.auditoria.id;
revoke all on all functions in schema core from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema core from anon, authenticated';
    execute 'revoke all on all tables in schema core from anon, authenticated';
    execute 'revoke all on all functions in schema core from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema core to service_role';
    execute 'grant execute on all functions in schema core to service_role';
    execute 'grant select on all tables in schema core to service_role';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 12. Dados de base (sem pessoas reais; usuários são cadastrados após aprovação)
-- ---------------------------------------------------------------------------
insert into core.departamentos (id, nome) values
  ('financeiro','Financeiro'), ('rh','RH / DP'), ('operacoes','Operações e Laboratório'),
  ('comercial','Comercial e Marketing'), ('tecnologia','Tecnologia'), ('administracao','Administração');

insert into core.papeis (id, nome) values
  ('admin','Administrador da plataforma'), ('diretoria','Diretoria / sócios'),
  ('gerente','Gerente de unidade'), ('financeiro','Equipe financeira'), ('consulta','Somente consulta'),
  ('agente_financeiro','Agente financeiro (máquina)');

insert into core.config (chave, valor) values
  ('plataforma_pausada','false'), ('versao_fundacao','0.1.0');

insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('financeiro','Agente Financeiro','financeiro','pausado','0.1.0',
   'Comprovantes, extratos, conciliação, fluxo de caixa e preparação do fechamento. Não movimenta dinheiro.');
insert into core.principais (tipo, nome, agente_id) values ('agente','Agente Financeiro','financeiro');
insert into core.principal_papeis (principal_id, papel_id)
  select id, 'agente_financeiro' from core.principais where agente_id = 'financeiro';

insert into core.integracoes (id, nome, status, observacoes) values
  ('zapi','Z-API (WhatsApp)','ok','Em uso pelo Finance AI atual; não é API oficial da Meta'),
  ('anthropic','Claude API','ok','Interpretação de comprovantes'),
  ('openai_whisper','Transcrição de áudio','nao_verificada','Usada pelo finance-worker se houver chave'),
  ('acert','ACERT','nao_verificada','Sem API confirmada'),
  ('kommo','Kommo CRM','nao_verificada','API pública existe; credencial não verificada'),
  ('sicredi','Sicredi (extratos)','nao_verificada','Importação de arquivo OFX/CSV prevista'),
  ('stone','Stone','nao_verificada',null), ('asaas','Asaas','nao_verificada',null),
  ('multicredito','Multicrédito','nao_verificada',null),
  ('braslab_webpedidos','Braslab WebPedidos (Acert)','nao_verificada','Sem API conhecida');
