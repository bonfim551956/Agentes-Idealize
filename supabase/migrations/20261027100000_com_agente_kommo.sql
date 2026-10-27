-- =============================================================================
-- Idealize AI — Agente Comercial / Kommo (v0.1.0)  · Migração 20261027100000
--
-- Primeira versão = LEITURA e MEDIÇÃO (Prompt Master §5.4). O agente lê a Kommo (API v4) e guarda um espelho SEM
-- dados pessoais: leads só com números, datas, etapa e responsável (sem nome, telefone ou e-mail do cliente) e o
-- HORÁRIO das mensagens do chat (sem o texto). Mede tempo de resposta, clientes esperando, conversão e valor
-- ganho por loja e por atendente. Nada é enviado nem alterado na Kommo (política proibida).
-- Nasce PAUSADO e com a sincronização DESLIGADA (com.sync.ativo = false).
-- Inclui índices que faltaram no laboratório (boas práticas: índice em chave estrangeira).
-- =============================================================================

create index if not exists lab_sincronizacoes_tarefa on lab.sincronizacoes (tarefa_id);
create index if not exists lab_alertas_origem on lab.alertas (id_origem);

create schema if not exists com;
revoke all on schema com from public;

-- ---------------------------------------------------------------------------
-- 1. Espelho
-- ---------------------------------------------------------------------------
create table com.usuarios (               -- atendentes da Kommo (dados de trabalho, sem e-mail)
  id            bigint primary key,
  nome          text not null,
  ativo         boolean not null default true,
  atualizado_em timestamptz not null default now()
);

create table com.funis (
  id            bigint primary key,
  nome          text not null,
  unidade_id    text references core.unidades(id),   -- loja do funil: definida pelo Diego (null = sem loja)
  atualizado_em timestamptz not null default now()
);
create index com_funis_unidade on com.funis (unidade_id);

create table com.etapas (
  funil_id  bigint not null references com.funis(id),
  id        bigint not null,
  nome      text not null,
  tipo      text not null check (tipo in ('entrada','aberta','ganha','perdida')),
  ordem     int not null default 0,
  primary key (funil_id, id)
);

create table com.leads (
  id               bigint primary key,
  funil_id         bigint not null references com.funis(id),
  etapa_id         bigint not null,
  responsavel_id   bigint,
  valor            numeric(14,2) not null default 0 check (valor >= 0),
  criado_em        timestamptz not null,
  atualizado_em    timestamptz not null,
  fechado_em       timestamptz,
  motivo_perda_id  bigint,
  excluido         boolean not null default false,
  hash_origem      text not null,
  sincronizacao_id uuid,
  foreign key (funil_id, etapa_id) references com.etapas (funil_id, id)
);
create index com_leads_funil_etapa on com.leads (funil_id, etapa_id);
create index com_leads_responsavel on com.leads (responsavel_id);
create index com_leads_criado on com.leads (criado_em);
create index com_leads_fechado on com.leads (fechado_em) where fechado_em is not null;
create index com_leads_sinc on com.leads (sincronizacao_id);

-- Só o momento e o lado da mensagem (cliente ou atendente). O texto nunca sai da Kommo.
create table com.mensagens (
  evento_id        text primary key,
  entidade_tipo    text not null check (entidade_tipo in ('lead','contact','company','customer')),
  entidade_id      bigint not null,
  sentido          text not null check (sentido in ('cliente','atendente')),
  usuario_id       bigint,
  em               timestamptz not null,
  sincronizacao_id uuid
);
create index com_mensagens_entidade on com.mensagens (entidade_tipo, entidade_id, em);
create index com_mensagens_em on com.mensagens (em);
create index com_mensagens_sinc on com.mensagens (sincronizacao_id);

create table com.sincronizacoes (
  id                 uuid primary key default gen_random_uuid(),
  tarefa_id          uuid references core.tarefas(id),
  desde              timestamptz not null,
  ate                timestamptz not null check (ate >= desde),
  usuarios           int not null,
  funis              int not null,
  leads              int not null,
  mensagens_recebidas int not null,
  mensagens_novas    int not null,
  ignoradas          int not null,
  alertas_abertos    int not null,
  alertas_resolvidos int not null,
  hash_lote          text not null,
  em                 timestamptz not null default now()
);
create index com_sincronizacoes_tarefa on com.sincronizacoes (tarefa_id);
create index com_sincronizacoes_ate on com.sincronizacoes (ate desc);

create table com.alertas (
  id            bigserial primary key,
  tipo          text not null check (tipo in ('cliente_sem_resposta','lead_sem_responsavel','lead_parado','funil_sem_loja')),
  referencia    text not null,                 -- 'lead:123', 'contact:456', 'funil:789'
  unidade_id    text references core.unidades(id),
  responsavel_id bigint,
  detalhe       jsonb,
  status        text not null default 'aberto' check (status in ('aberto','resolvido')),
  aberto_em     timestamptz not null default now(),
  resolvido_em  timestamptz,
  resolvido_por text
);
create unique index com_alertas_abertos_uk on com.alertas (tipo, referencia) where status = 'aberto';
create index com_alertas_unidade on com.alertas (unidade_id) where status = 'aberto';
create index com_alertas_referencia on com.alertas (referencia);

insert into core.config (chave, valor) values
  ('com.sync.ativo', 'false'),
  ('com.limite_resposta_min', '30'),          -- cliente esperando mais que isso = alerta
  ('com.lead_parado_dias', '3'),              -- lead aberto sem movimento há mais que isso = alerta
  ('com.lead_parado_janela_dias', '60'),      -- só leads criados nos últimos N dias entram no alerta de parado
  ('com.sync.primeira_janela_dias', '30'),
  ('versao_com', '0.1.0')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Agente, papel, políticas e integração (nasce pausado; nunca escreve na Kommo)
-- ---------------------------------------------------------------------------
insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('comercial', 'Agente Comercial', 'comercial', 'pausado', '0.1.0',
   'Mede o atendimento na Kommo: tempo de resposta, clientes esperando, conversão e valor ganho por loja e atendente. Só leitura: não envia mensagens nem altera leads.')
on conflict (id) do nothing;
insert into core.papeis (id, nome) values ('agente_comercial', 'Agente comercial (máquina)') on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', 'Agente Comercial', 'comercial' where not exists (select 1 from core.principais where agente_id = 'comercial');
insert into core.principal_papeis (principal_id, papel_id)
select id, 'agente_comercial' from core.principais where agente_id = 'comercial' on conflict do nothing;
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_comercial', 'com.kommo', 'sincronizar', 'baixo', 'automatica'
where not exists (select 1 from core.politicas where papel_id = 'agente_comercial' and recurso = 'com.kommo' and operacao = 'sincronizar' and ativo);
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_comercial', 'com.kommo', v.op, 'alto', 'proibida'
from (values ('enviar_mensagem'), ('alterar_lead'), ('criar_lead'), ('excluir')) v(op)
where not exists (select 1 from core.politicas where papel_id = 'agente_comercial' and recurso = 'com.kommo' and operacao = v.op and ativo);

update core.integracoes set credencial_leitura = 'KOMMO_TOKEN',
  observacoes = 'API v4 (prevendasidealize). Token de integração privada; o agente só faz GET. Escrita proibida pela matriz.'
 where id = 'kommo';

-- ---------------------------------------------------------------------------
-- 3. Regras dos alertas (recalculadas a cada lote para o estado inteiro; resolvem sozinhas)
-- ---------------------------------------------------------------------------
create or replace function com._cfg_int(p_chave text, p_padrao int) returns int
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(nullif(core.cfg(p_chave, p_padrao::text), '')::int, p_padrao)
$$;

-- Última mensagem de cada conversa e se o cliente está esperando
create or replace view com.v_conversas with (security_invoker = true) as
select distinct on (m.entidade_tipo, m.entidade_id)
  m.entidade_tipo, m.entidade_id, m.sentido as ultimo_sentido, m.em as ultima_em,
  (select max(x.em) from com.mensagens x where x.entidade_tipo = m.entidade_tipo and x.entidade_id = m.entidade_id
     and x.sentido = 'atendente') as ultima_resposta_em
from com.mensagens m
order by m.entidade_tipo, m.entidade_id, m.em desc, m.sentido;  -- empate: 'atendente' < 'cliente' → cliente vence (mais conservador)

-- Tempo de resposta: cada mensagem do cliente que abre uma "vez" do cliente, até a primeira resposta da equipe
create or replace view com.v_respostas with (security_invoker = true) as
with ord as (
  select m.*, lag(m.sentido) over (partition by m.entidade_tipo, m.entidade_id order by m.em, m.evento_id) as anterior
  from com.mensagens m
)
select o.entidade_tipo, o.entidade_id, o.em as cliente_em, r.em as resposta_em, r.usuario_id,
       extract(epoch from (r.em - o.em)) / 60.0 as minutos
from ord o
left join lateral (
  select x.em, x.usuario_id from com.mensagens x
  where x.entidade_tipo = o.entidade_tipo and x.entidade_id = o.entidade_id and x.sentido = 'atendente' and x.em >= o.em
  order by x.em limit 1) r on true
where o.sentido = 'cliente' and coalesce(o.anterior, 'atendente') = 'atendente';

create or replace function com.recalcular_alertas() returns jsonb
language plpgsql security definer set search_path = com, core, pg_catalog as $$
declare v_lim int := com._cfg_int('com.limite_resposta_min', 30);
  v_par int := com._cfg_int('com.lead_parado_dias', 3); v_jan int := com._cfg_int('com.lead_parado_janela_dias', 60);
  n_ab int; n_res int;
begin
  drop table if exists _devidos;
  create temp table _devidos (tipo text, referencia text, unidade_id text, responsavel_id bigint, detalhe jsonb) on commit drop;

  insert into _devidos
  select 'cliente_sem_resposta', c.entidade_tipo || ':' || c.entidade_id, f.unidade_id, l.responsavel_id,
         jsonb_build_object('desde', c.ultima_em, 'minutos', floor(extract(epoch from now() - c.ultima_em) / 60), 'limite_min', v_lim)
  from com.v_conversas c
  left join com.leads l on c.entidade_tipo = 'lead' and l.id = c.entidade_id
  left join com.funis f on f.id = l.funil_id
  where c.ultimo_sentido = 'cliente' and c.ultima_em < now() - make_interval(mins => v_lim)
    and c.ultima_em > now() - interval '7 days'              -- conversa abandonada há mais de 7 dias não é "esperando"
    and coalesce(l.excluido, false) = false;

  insert into _devidos
  select 'lead_sem_responsavel', 'lead:' || l.id, f.unidade_id, null, jsonb_build_object('criado_em', l.criado_em)
  from com.leads l join com.funis f on f.id = l.funil_id join com.etapas e on e.funil_id = l.funil_id and e.id = l.etapa_id
  where e.tipo in ('entrada','aberta') and not l.excluido and coalesce(l.responsavel_id, 0) = 0;

  insert into _devidos
  select 'lead_parado', 'lead:' || l.id, f.unidade_id, l.responsavel_id,
         jsonb_build_object('etapa', e.nome, 'atualizado_em', l.atualizado_em,
           'dias', floor(extract(epoch from now() - l.atualizado_em) / 86400), 'limite_dias', v_par)
  from com.leads l join com.funis f on f.id = l.funil_id join com.etapas e on e.funil_id = l.funil_id and e.id = l.etapa_id
  where e.tipo in ('entrada','aberta') and not l.excluido
    and l.atualizado_em < now() - make_interval(days => v_par) and l.criado_em > now() - make_interval(days => v_jan);

  insert into _devidos
  select 'funil_sem_loja', 'funil:' || f.id, null, null, jsonb_build_object('funil', f.nome)
  from com.funis f where f.unidade_id is null and exists (select 1 from com.leads l where l.funil_id = f.id and not l.excluido);

  insert into com.alertas (tipo, referencia, unidade_id, responsavel_id, detalhe)
  select tipo, referencia, unidade_id, responsavel_id, detalhe from _devidos
  on conflict (tipo, referencia) where status = 'aberto'
  do update set detalhe = excluded.detalhe, unidade_id = excluded.unidade_id, responsavel_id = excluded.responsavel_id;
  get diagnostics n_ab = row_count;

  update com.alertas a set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente_comercial: situação deixou de existir'
   where a.status = 'aberto' and not exists (select 1 from _devidos d where d.tipo = a.tipo and d.referencia = a.referencia);
  get diagnostics n_res = row_count;
  return jsonb_build_object('ativos', n_ab, 'resolvidos', n_res);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Aplicação de um lote — tudo em operações em conjunto (sem laço por linha); idempotente
-- Formato: {desde, ate, usuarios:[{id,nome,ativo}], funis:[{id,nome,etapas:[{id,nome,tipo,ordem}]}],
--           leads:[{id,funil_id,etapa_id,responsavel_id,valor,criado_em,atualizado_em,fechado_em,motivo_perda_id,excluido}],
--           eventos:[{id,tipo,entidade_tipo,entidade_id,usuario_id,em}]}   (datas em segundos Unix, como na Kommo)
-- ---------------------------------------------------------------------------
create or replace function com.aplicar_lote(p_tarefa uuid, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = com, core, pg_catalog as $$
declare v_s uuid := gen_random_uuid(); v_desde timestamptz; v_ate timestamptz;
  n_us int; n_fu int; n_le int; n_ev int; n_evn int; n_ign int := 0; v_al jsonb;
begin
  if jsonb_typeof(p_lote) is distinct from 'object' then raise exception 'lote inválido'; end if;
  if coalesce(p_lote->>'desde', '') !~ '^[0-9]{9,11}$' or coalesce(p_lote->>'ate', '') !~ '^[0-9]{9,11}$' then raise exception 'lote sem janela (desde/ate)'; end if;
  v_desde := to_timestamp((p_lote->>'desde')::bigint); v_ate := to_timestamp((p_lote->>'ate')::bigint);

  insert into com.usuarios as u (id, nome, ativo, atualizado_em)
  select r.id, left(btrim(r.nome), 120), coalesce(r.ativo, true), now()
  from jsonb_to_recordset(coalesce(p_lote->'usuarios', '[]')) r(id bigint, nome text, ativo boolean)
  where r.id is not null and coalesce(btrim(r.nome), '') <> ''
  on conflict (id) do update set nome = excluded.nome, ativo = excluded.ativo, atualizado_em = now()
   where (u.nome, u.ativo) is distinct from (excluded.nome, excluded.ativo);
  select jsonb_array_length(coalesce(p_lote->'usuarios', '[]')) into n_us;

  insert into com.funis as f (id, nome, atualizado_em)
  select r.id, left(btrim(r.nome), 120), now()
  from jsonb_to_recordset(coalesce(p_lote->'funis', '[]')) r(id bigint, nome text)
  where r.id is not null and coalesce(btrim(r.nome), '') <> ''
  on conflict (id) do update set nome = excluded.nome, atualizado_em = now() where f.nome is distinct from excluded.nome;
  select jsonb_array_length(coalesce(p_lote->'funis', '[]')) into n_fu;

  insert into com.etapas as e (funil_id, id, nome, tipo, ordem)
  select (fu->>'id')::bigint, r.id, left(btrim(r.nome), 120), r.tipo, coalesce(r.ordem, 0)
  from jsonb_array_elements(coalesce(p_lote->'funis', '[]')) fu,
       jsonb_to_recordset(coalesce(fu->'etapas', '[]')) r(id bigint, nome text, tipo text, ordem int)
  where r.id is not null and r.tipo in ('entrada','aberta','ganha','perdida') and coalesce(btrim(r.nome), '') <> ''
    and exists (select 1 from com.funis where id = (fu->>'id')::bigint)
  on conflict (funil_id, id) do update set nome = excluded.nome, tipo = excluded.tipo, ordem = excluded.ordem
   where (e.nome, e.tipo, e.ordem) is distinct from (excluded.nome, excluded.tipo, excluded.ordem);

  -- leads: só os que têm funil/etapa conhecidos; o resto é contado como ignorado
  with r as (
    select x.*, md5(row(x.*)::text) h
    from jsonb_to_recordset(coalesce(p_lote->'leads', '[]')) x(id bigint, funil_id bigint, etapa_id bigint, responsavel_id bigint,
      valor numeric, criado_em bigint, atualizado_em bigint, fechado_em bigint, motivo_perda_id bigint, excluido boolean)
  ), ok as (
    select r.* from r join com.etapas e on e.funil_id = r.funil_id and e.id = r.etapa_id
    where r.id is not null and r.criado_em > 0 and r.atualizado_em > 0
  ), up as (
    insert into com.leads as l (id, funil_id, etapa_id, responsavel_id, valor, criado_em, atualizado_em, fechado_em,
      motivo_perda_id, excluido, hash_origem, sincronizacao_id)
    select id, funil_id, etapa_id, nullif(responsavel_id, 0), greatest(coalesce(valor, 0), 0), to_timestamp(criado_em), to_timestamp(atualizado_em),
           case when fechado_em > 0 then to_timestamp(fechado_em) end, nullif(motivo_perda_id, 0), coalesce(excluido, false), h, v_s
    from ok
    on conflict (id) do update set funil_id = excluded.funil_id, etapa_id = excluded.etapa_id, responsavel_id = excluded.responsavel_id,
      valor = excluded.valor, criado_em = excluded.criado_em, atualizado_em = excluded.atualizado_em, fechado_em = excluded.fechado_em,
      motivo_perda_id = excluded.motivo_perda_id, excluido = excluded.excluido, hash_origem = excluded.hash_origem,
      sincronizacao_id = excluded.sincronizacao_id
    returning 1)
  select (select count(*) from up), (select count(*) from r) - (select count(*) from ok) into n_le, n_ign;

  -- mensagens: só tipos de chat conhecidos; texto nunca vem
  with r as (
    select x.* from jsonb_to_recordset(coalesce(p_lote->'eventos', '[]')) x(id text, tipo text, entidade_tipo text, entidade_id bigint,
      usuario_id bigint, em bigint)
  ), ok as (
    select * from r where coalesce(id, '') <> '' and tipo in ('incoming_chat_message','outgoing_chat_message')
      and entidade_tipo in ('lead','contact','company','customer') and entidade_id > 0 and em > 0
  ), ins as (
    insert into com.mensagens (evento_id, entidade_tipo, entidade_id, sentido, usuario_id, em, sincronizacao_id)
    select left(id, 80), entidade_tipo, entidade_id, case when tipo = 'incoming_chat_message' then 'cliente' else 'atendente' end,
           nullif(usuario_id, 0), to_timestamp(em), v_s
    from ok on conflict (evento_id) do nothing returning 1)
  select (select count(*) from r), (select count(*) from ins), n_ign + (select count(*) from r) - (select count(*) from ok)
    into n_ev, n_evn, n_ign;

  v_al := com.recalcular_alertas();

  insert into com.sincronizacoes (id, tarefa_id, desde, ate, usuarios, funis, leads, mensagens_recebidas, mensagens_novas, ignoradas,
    alertas_abertos, alertas_resolvidos, hash_lote)
  values (v_s, p_tarefa, v_desde, v_ate, n_us, n_fu, n_le, n_ev, n_evn, n_ign, (v_al->>'ativos')::int, (v_al->>'resolvidos')::int,
    md5(p_lote::text));
  return jsonb_build_object('sincronizacao', v_s, 'desde', v_desde, 'ate', v_ate, 'usuarios', n_us, 'funis', n_fu, 'leads', n_le,
    'mensagens_recebidas', n_ev, 'mensagens_novas', n_evn, 'ignoradas', n_ign, 'alertas', v_al, 'hash_lote', md5(p_lote::text));
end $$;

create or replace function com.concluir_sincronizacao(p_tarefa uuid, p_executor text, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = com, core, pg_catalog as $$
declare t record; v jsonb;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id <> 'comercial' or t.tipo <> 'com_sincronizacao' then raise exception 'tarefa não é sincronização do comercial'; end if;
  v := com.aplicar_lote(p_tarefa, p_lote);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', v->>'hash_lote', v);
  return v;
end $$;

-- Janela da próxima leitura: continua de onde a última terminou (10 min de sobreposição), no máximo 3 dias por vez
create or replace function com.proxima_janela() returns jsonb
language sql stable security definer set search_path = com, core, pg_catalog as $$
  with ult as (select max(ate) ate from com.sincronizacoes),
  d as (select coalesce((select ate from ult) - interval '10 minutes',
                        now() - make_interval(days => com._cfg_int('com.sync.primeira_janela_dias', 30))) desde)
  select jsonb_build_object('desde', floor(extract(epoch from d.desde))::bigint,
                            'ate', floor(extract(epoch from least(now(), d.desde + interval '3 days')))::bigint)
  from d
$$;

-- ---------------------------------------------------------------------------
-- 5. Validador independente (reconta o espelho e reavalia o alerta principal por conta própria)
-- ---------------------------------------------------------------------------
create or replace function com.validar_sincronizacao(p_tarefa uuid, p_validador text) returns text
language plpgsql security definer set search_path = com, core, pg_catalog as $$
declare t record; s record; v_erros text[] := '{}'; n int; v_lim int := com._cfg_int('com.limite_resposta_min', 30);
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  select * into s from com.sincronizacoes where tarefa_id = p_tarefa order by em desc limit 1;
  if s.id is null then
    v_erros := v_erros || 'sincronização sem registro';
  else
    select count(*) into n from com.leads where sincronizacao_id = s.id;
    if n <> s.leads then v_erros := v_erros || format('espelho tem %s leads do lote, registro diz %s', n, s.leads); end if;
    select count(*) into n from com.mensagens where sincronizacao_id = s.id;
    if n <> s.mensagens_novas then v_erros := v_erros || format('espelho tem %s mensagens novas, registro diz %s', n, s.mensagens_novas); end if;
    if s.ate < s.desde then v_erros := v_erros || 'janela invertida'; end if;
    -- completude, com consulta própria: toda conversa recente cuja última mensagem é do cliente e passou do limite tem alerta
    select count(*) into n from (
      select distinct on (entidade_tipo, entidade_id) entidade_tipo, entidade_id, sentido, em
      from com.mensagens order by entidade_tipo, entidade_id, em desc, sentido) c
    where c.sentido = 'cliente' and c.em < now() - make_interval(mins => v_lim) and c.em > now() - interval '7 days'
      and not exists (select 1 from com.leads l where c.entidade_tipo = 'lead' and l.id = c.entidade_id and l.excluido)
      and not exists (select 1 from com.alertas a where a.tipo = 'cliente_sem_resposta' and a.status = 'aberto'
                      and a.referencia = c.entidade_tipo || ':' || c.entidade_id);
    if n > 0 then v_erros := v_erros || format('%s conversas esperando resposta sem alerta', n); end if;
    -- coerência: alerta de espera aberto em conversa já respondida
    select count(*) into n from com.alertas a
     where a.tipo = 'cliente_sem_resposta' and a.status = 'aberto'
       and exists (select 1 from com.mensagens m where m.entidade_tipo || ':' || m.entidade_id = a.referencia and m.sentido = 'atendente'
                   and m.em >= (a.detalhe->>'desde')::timestamptz);
    if n > 0 then v_erros := v_erros || format('%s alertas de espera abertos em conversa já respondida', n); end if;
  end if;
  if array_length(v_erros, 1) is null then
    return core.registrar_validacao(p_tarefa, p_validador, true, null, jsonb_build_object('sincronizacao', s.id));
  end if;
  return core.registrar_validacao(p_tarefa, p_validador, false, array_to_string(v_erros, '; '),
    jsonb_build_object('sincronizacao', s.id, 'erros', to_jsonb(v_erros)));
end $$;

create or replace function com.agendar_sincronizacao() returns uuid
language plpgsql security definer set search_path = com, core, pg_catalog as $$
declare v_p uuid; v_janela text;
begin
  if core.cfg('com.sync.ativo', 'false') <> 'true' then return null; end if;
  select id into v_p from core.principais where agente_id = 'comercial';
  v_janela := to_char(date_trunc('hour', now()) + floor(extract(minute from now()) / 15) * interval '15 minutes', 'YYYYMMDDHH24MI');
  return core.criar_tarefa(v_p, 'comercial', 'com_sincronizacao', 'com.kommo', 'sincronizar', null,
    jsonb_build_object('origem', 'kommo'), 'com:sync:' || v_janela, null, 6);
end $$;

-- Loja de cada funil: decisão humana, auditada (o Diego diz qual funil é de qual loja)
create or replace function com.definir_loja_funil(p_funil bigint, p_unidade text, p_ator uuid, p_motivo text) returns void
language plpgsql security definer set search_path = com, core, pg_catalog as $$
declare v_antes text;
begin
  if not exists (select 1 from core.principais where id = p_ator and tipo = 'usuario' and ativo) then
    raise exception 'definição de loja é feita por pessoa' using errcode = '42501';
  end if;
  select unidade_id into v_antes from com.funis where id = p_funil for update;
  if not found then raise exception 'funil inexistente'; end if;
  update com.funis set unidade_id = p_unidade, atualizado_em = now() where id = p_funil;
  perform com.recalcular_alertas();
  perform core.auditar(p_ator, null, 'funil_loja', 'com.funil', p_funil::text, jsonb_build_object('unidade', v_antes),
    jsonb_build_object('unidade', p_unidade), p_motivo);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Painel (mesmas regras: login vinculado, 2FA, escopo por unidade; funil sem loja só para escopo global)
-- ---------------------------------------------------------------------------
create or replace function public.painel_comercial(p_unidade text default null, p_dias int default 7) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[]; g boolean; d int := least(greatest(coalesce(p_dias, 7), 1), 90); v_ini timestamptz;
  v_lim int := com._cfg_int('com.limite_resposta_min', 30);
begin
  v_eu := painel._entrar('comercial', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; g := false; end if;
  v_ini := now() - make_interval(days => d);
  return jsonb_build_object(
    'periodo_dias', d, 'limite_resposta_min', v_lim,
    'sincronizacao', jsonb_build_object('ativa', core.cfg('com.sync.ativo', 'false') = 'true',
       'agente', (select status from core.agentes where id = 'comercial'),
       'ultima', (select jsonb_build_object('em', em, 'ate', ate, 'leads', leads, 'mensagens_novas', mensagens_novas)
                  from com.sincronizacoes order by em desc limit 1)),
    'lojas', (select coalesce(jsonb_agg(x order by x->>'nome'), '[]'::jsonb) from (
      select jsonb_build_object('id', coalesce(f.unidade_id, '_sem_loja'),
        'nome', coalesce((select nome from core.unidades where id = f.unidade_id), 'Funis sem loja definida'),
        'leads_novos', count(*) filter (where l.criado_em >= v_ini),
        'ganhos', count(*) filter (where e.tipo = 'ganha' and l.fechado_em >= v_ini),
        'perdidos', count(*) filter (where e.tipo = 'perdida' and l.fechado_em >= v_ini),
        'valor_ganho', coalesce(sum(l.valor) filter (where e.tipo = 'ganha' and l.fechado_em >= v_ini), 0),
        'em_aberto', count(*) filter (where e.tipo in ('entrada','aberta'))) x
      from com.leads l join com.funis f on f.id = l.funil_id join com.etapas e on e.funil_id = l.funil_id and e.id = l.etapa_id
      where not l.excluido and ((g and f.unidade_id is null) or f.unidade_id = any(un))
      group by f.unidade_id) q),
    'atendentes', (select coalesce(jsonb_agg(x order by (x->>'respondidas')::int desc), '[]'::jsonb) from (
      select jsonb_build_object('id', u.id, 'nome', u.nome,
        'respondidas', count(r.*),
        'mediana_min', round((percentile_cont(0.5) within group (order by r.minutos))::numeric, 1),
        'no_limite_pct', round(100.0 * count(*) filter (where r.minutos <= v_lim) / nullif(count(r.*), 0), 1),
        'ganhos', (select count(*) from com.leads l2 join com.etapas e2 on e2.funil_id = l2.funil_id and e2.id = l2.etapa_id
                   join com.funis f2 on f2.id = l2.funil_id
                   where l2.responsavel_id = u.id and e2.tipo = 'ganha' and l2.fechado_em >= v_ini and not l2.excluido
                     and ((g and f2.unidade_id is null) or f2.unidade_id = any(un)))) x
      from com.usuarios u
      join com.v_respostas r on r.usuario_id = u.id and r.cliente_em >= v_ini
      left join com.leads l on r.entidade_tipo = 'lead' and l.id = r.entidade_id
      left join com.funis f on f.id = l.funil_id
      where (g and f.unidade_id is null) or f.unidade_id = any(un)
      group by u.id, u.nome) q),
    'resposta_geral', (select jsonb_build_object('respondidas', count(*) filter (where r.resposta_em is not null),
        'mediana_min', round((percentile_cont(0.5) within group (order by r.minutos))::numeric, 1),
        'no_limite_pct', round(100.0 * count(*) filter (where r.minutos <= v_lim) / nullif(count(*) filter (where r.resposta_em is not null), 0), 1))
      from com.v_respostas r
      left join com.leads l on r.entidade_tipo = 'lead' and l.id = r.entidade_id
      left join com.funis f on f.id = l.funil_id
      where r.cliente_em >= v_ini and ((g and f.unidade_id is null) or f.unidade_id = any(un))),
    'alertas', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'referencia', a.referencia, 'unidade_id', a.unidade_id,
        'responsavel', (select nome from com.usuarios where id = a.responsavel_id), 'aberto_em', a.aberto_em,
        'detalhe', painel._mascarar(a.detalhe)) x
      from com.alertas a
      where a.status = 'aberto' and ((g and a.unidade_id is null) or a.unidade_id = any(un))
      order by case a.tipo when 'cliente_sem_resposta' then 0 when 'lead_sem_responsavel' then 1 when 'funil_sem_loja' then 2 else 3 end,
               a.aberto_em
      limit 300) q),
    'funis', case when g then (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'nome', f.nome, 'unidade_id', f.unidade_id)
        order by f.nome), '[]'::jsonb) from com.funis f) end);
end $$;

create or replace function public.painel_comercial_funil_loja(p_funil bigint, p_unidade text, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('comercial_funil_loja', p_funil::text);
  perform painel._exigir(v_eu, 'administrar');
  if p_unidade is not null and not exists (select 1 from core.unidades where id = p_unidade and ativo) then
    raise exception 'loja inválida' using errcode = '22023';
  end if;
  perform com.definir_loja_funil(p_funil, p_unidade, v_eu, painel._texto(5, p_motivo, 'motivo'));
end $$;

-- ---------------------------------------------------------------------------
-- 7. Endurecimento (mesmo padrão)
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'com' loop
    execute format('alter table com.%I enable row level security', r.tablename);
    execute format('alter table com.%I force row level security', r.tablename);
    execute format('revoke all on com.%I from public', r.tablename);
  end loop;
  execute 'revoke all on com.v_conversas, com.v_respostas from public';
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'com' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', r.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema com from anon, authenticated';
    execute 'revoke all on function public.painel_comercial(text, int) from public, anon';
    execute 'revoke all on function public.painel_comercial_funil_loja(bigint, text, text) from public, anon';
    execute 'grant execute on function public.painel_comercial(text, int) to authenticated';
    execute 'grant execute on function public.painel_comercial_funil_loja(bigint, text, text) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema com to service_role';
    execute 'grant select on all tables in schema com to service_role';
    execute 'grant execute on function public.painel_comercial(text, int) to service_role';
    execute 'grant execute on function public.painel_comercial_funil_loja(bigint, text, text) to service_role';
  end if;
end $$;
