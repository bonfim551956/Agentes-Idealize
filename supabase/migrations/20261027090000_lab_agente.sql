-- =============================================================================
-- Idealize AI — Agente de Laboratório (v0.1.0)  · Migração 20261027090000
--
-- Primeira versão = CONSULTA e ACOMPANHAMENTO (Prompt Master §5.3). Nada é criado, alterado ou cancelado no
-- laboratório nem no kanban. O agente lê o kanban das lojas (Sistema ADM, só leitura), guarda um espelho SEM dados
-- pessoais (sem cliente, telefone, receita ou valores) e gera alertas que se resolvem sozinhos quando a situação
-- deixa de existir. Nasce PAUSADO e com a sincronização DESLIGADA (lab.sync.ativo = false).
-- =============================================================================

create schema if not exists lab;
revoke all on schema lab from public;

-- ---------------------------------------------------------------------------
-- 1. Cadastros
-- ---------------------------------------------------------------------------
-- Etapas do kanban (coluna numérica do ADM → nome). confirmada=false até o Diego conferir os nomes.
create table lab.etapas (
  col          int primary key,
  nome         text,
  ordem        int not null,
  situacao     text not null check (situacao in ('andamento','aguardando_cliente','encerrada')),
  parado_dias  int check (parado_dias > 0),           -- acima disso parado na etapa vira alerta
  confirmada   boolean not null default false
);
insert into lab.etapas (col, nome, ordem, situacao, parado_dias) values
  (0, 'Pedido',               0, 'andamento',          2),
  (1, 'Aguardando lentes',    1, 'andamento',          7),
  (2, 'Aguardando montagem',  2, 'andamento',          3),
  (3, 'Em montagem',          3, 'andamento',          3),
  (4, 'Avisado',              4, 'aguardando_cliente', 15),
  (5, 'Entregue',             5, 'encerrada',          null),
  (6, 'Não retirado',         6, 'encerrada',          null),
  (7, 'Cancelado',            7, 'encerrada',          null),
  (8, null,                   8, 'andamento',          null);   -- nome desconhecido: gera alerta até ser confirmado

-- Nome da unidade no kanban → unidade do core
create table lab.unidades_origem (
  origem     text primary key,
  unidade_id text not null references core.unidades(id)
);
do $$ begin
  insert into lab.unidades_origem (origem, unidade_id)
  select v.o, v.u from (values ('campinas','campinas'), ('piracicaba','piracicaba'), ('saovicente','sao_vicente'), ('sorocaba','sorocaba')) v(o, u)
  where exists (select 1 from core.unidades where id = v.u);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Espelho das ordens de serviço (sem dados pessoais)
-- ---------------------------------------------------------------------------
create table lab.os (
  id_origem         text primary key,
  unidade_id        text not null references core.unidades(id),
  os                text,
  pedido            text,
  tipo              text,
  laboratorio       text,
  col               int not null,
  dt_venda          date,
  prazo             date,
  urgente           boolean not null default false,
  refeito           boolean not null default false,
  cancelado         boolean not null default false,
  nao_retirado      boolean not null default false,
  saldo_aberto      boolean not null default false,
  ultima_mov        timestamptz,
  entrou_etapa_em   timestamptz,
  hash_origem       text not null,
  sincronizacao_id  uuid,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now()
);
create index lab_os_unidade_col on lab.os (unidade_id, col);

create table lab.sincronizacoes (
  id                 uuid primary key default gen_random_uuid(),
  tarefa_id          uuid references core.tarefas(id),
  origem             text not null,
  recebidas          int not null,
  aplicadas          int not null,          -- novas + atualizadas + sem mudança
  novas              int not null,
  atualizadas        int not null,
  ignoradas          int not null,
  alertas_abertos    int not null,
  alertas_resolvidos int not null,
  hash_lote          text not null,
  em                 timestamptz not null default now()
);

create table lab.alertas (
  id           bigserial primary key,
  tipo         text not null check (tipo in ('prazo_vencido','parado_na_etapa','aguardando_retirada',
                                              'sem_pedido_lab','refeito','etapa_desconhecida','unidade_desconhecida')),
  id_origem    text not null,
  unidade_id   text references core.unidades(id),
  detalhe      jsonb,
  status       text not null default 'aberto' check (status in ('aberto','resolvido')),
  aberto_em    timestamptz not null default now(),
  resolvido_em timestamptz,
  resolvido_por text
);
create unique index lab_alertas_abertos_uk on lab.alertas (tipo, id_origem) where status = 'aberto';
create index lab_alertas_unidade on lab.alertas (unidade_id) where status = 'aberto';

insert into core.config (chave, valor) values
  ('lab.sync.ativo', 'false'),
  ('lab.sync.origem', 'adm_os_cards'),
  ('versao_lab', '0.1.0')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------------
-- 3. Agente, papel, política e integração (nasce pausado)
-- ---------------------------------------------------------------------------
insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('laboratorio', 'Agente de Laboratório', 'operacoes', 'pausado', '0.1.0',
   'Acompanha as ordens de serviço do kanban dos laboratórios: prazos, pedidos parados, óculos não retirados. Só leitura: não cria, altera nem cancela pedidos.')
on conflict (id) do nothing;
insert into core.papeis (id, nome) values ('agente_laboratorio', 'Agente de laboratório (máquina)') on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', 'Agente de Laboratório', 'laboratorio'
where not exists (select 1 from core.principais where agente_id = 'laboratorio');
insert into core.principal_papeis (principal_id, papel_id)
select id, 'agente_laboratorio' from core.principais where agente_id = 'laboratorio'
on conflict do nothing;
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_laboratorio', 'lab.os', 'sincronizar', 'baixo', 'automatica'
where not exists (select 1 from core.politicas where papel_id = 'agente_laboratorio' and recurso = 'lab.os' and operacao = 'sincronizar' and ativo);
-- explícito: o agente de laboratório nunca escreve no laboratório (pedido, alteração ou cancelamento)
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_laboratorio', 'lab.pedido', v.op, 'alto', 'proibida'
from (values ('criar'), ('alterar'), ('cancelar')) v(op)
where not exists (select 1 from core.politicas where papel_id = 'agente_laboratorio' and recurso = 'lab.pedido' and operacao = v.op and ativo);

insert into core.integracoes (id, nome, status, escrita_habilitada, credencial_leitura, observacoes) values
  ('adm_kanban', 'Kanban dos laboratórios (Sistema ADM)', 'nao_verificada', false, 'ADM_LEITURA_DB_URL',
   'Leitura de public.os_cards por uma visão sem dados pessoais e um usuário só de leitura (a criar no ADM com autorização).')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 4. Regras dos alertas (uma função só, usada na aplicação; o validador tem a sua própria conferência)
-- ---------------------------------------------------------------------------
create or replace function lab._hoje() returns date
language sql stable set search_path = pg_catalog as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create or replace function lab._alertas_devidos(o lab.os) returns table (tipo text, detalhe jsonb)
language sql stable security definer set search_path = lab, pg_catalog as $$
  with e as (select * from lab.etapas where col = o.col)
  select 'etapa_desconhecida', jsonb_build_object('col', o.col)
   where not exists (select 1 from e where e.nome is not null)
  union all
  select 'prazo_vencido', jsonb_build_object('prazo', o.prazo, 'dias', lab._hoje() - o.prazo, 'etapa', e.nome)
    from e where e.situacao = 'andamento' and o.prazo < lab._hoje() and not o.cancelado
  union all
  select 'parado_na_etapa', jsonb_build_object('etapa', e.nome, 'desde', o.entrou_etapa_em,
           'dias', (lab._hoje() - (o.entrou_etapa_em at time zone 'America/Sao_Paulo')::date), 'limite_dias', e.parado_dias)
    from e where e.situacao = 'andamento' and e.parado_dias is not null and not o.cancelado
     and o.entrou_etapa_em < now() - make_interval(days => e.parado_dias)
  union all
  select 'aguardando_retirada', jsonb_build_object('desde', o.entrou_etapa_em,
           'dias', (lab._hoje() - (o.entrou_etapa_em at time zone 'America/Sao_Paulo')::date), 'limite_dias', e.parado_dias,
           'saldo_aberto', o.saldo_aberto)
    from e where e.situacao = 'aguardando_cliente' and e.parado_dias is not null and not o.cancelado
     and o.entrou_etapa_em < now() - make_interval(days => e.parado_dias)
  union all
  select 'sem_pedido_lab', jsonb_build_object('etapa', e.nome, 'laboratorio', o.laboratorio)
    from e where e.situacao = 'andamento' and e.ordem between 1 and 3 and not o.cancelado
     and coalesce(btrim(o.pedido), '') = '' and o.tipo in ('venda','gar-pedido','cortesia-pedido')
  union all
  select 'refeito', jsonb_build_object('etapa', e.nome)
    from e where e.situacao = 'andamento' and o.refeito and not o.cancelado
$$;

-- ---------------------------------------------------------------------------
-- 5. Aplicação de um lote (snapshot) — idempotente; execução + resultado na mesma transação
-- ---------------------------------------------------------------------------
create or replace function lab.aplicar_lote(p_tarefa uuid, p_origem text, p_linhas jsonb) returns jsonb
language plpgsql security definer set search_path = lab, core, pg_catalog as $$
declare r jsonb; v_s uuid := gen_random_uuid(); v_un text; v_hash text; o lab.os; a record;
  n_rec int := 0; n_nov int := 0; n_atu int := 0; n_ign int := 0; n_ab int := 0; n_res int := 0; v_ids text[] := '{}';
  v_col int; v_ent timestamptz;
begin
  if jsonb_typeof(p_linhas) is distinct from 'array' then raise exception 'lote inválido'; end if;
  for r in select * from jsonb_array_elements(p_linhas) loop
    n_rec := n_rec + 1;
    if coalesce(r->>'id', '') = '' or (r->>'col') is null or (r->>'col') !~ '^-?[0-9]+$' then n_ign := n_ign + 1; continue; end if;
    select unidade_id into v_un from lab.unidades_origem where origem = lower(btrim(coalesce(r->>'unidade', '')));
    if v_un is null then
      n_ign := n_ign + 1;
      insert into lab.alertas (tipo, id_origem, detalhe) values ('unidade_desconhecida', r->>'id',
        jsonb_build_object('unidade', left(r->>'unidade', 40)))
      on conflict (tipo, id_origem) where status = 'aberto' do nothing;
      continue;
    end if;
    v_col := (r->>'col')::int;
    v_hash := md5(r::text);
    v_ent := case when r->>'entrou_etapa_ms' ~ '^[0-9]{10,}$' then to_timestamp((r->>'entrou_etapa_ms')::bigint / 1000.0) end;
    select * into o from lab.os where id_origem = r->>'id' for update;
    if o.id_origem is null then
      n_nov := n_nov + 1;
    elsif o.hash_origem <> v_hash then
      n_atu := n_atu + 1;
    end if;
    insert into lab.os as x (id_origem, unidade_id, os, pedido, tipo, laboratorio, col, dt_venda, prazo, urgente, refeito,
      cancelado, nao_retirado, saldo_aberto, ultima_mov, entrou_etapa_em, hash_origem, sincronizacao_id)
    values (r->>'id', v_un, left(r->>'os', 40), left(r->>'ped', 60), left(r->>'tipo', 40), upper(btrim(left(r->>'lab', 60))), v_col,
      nullif(r->>'dt_venda', '')::date, nullif(r->>'prazo', '')::date, coalesce((r->>'urgente')::boolean, false),
      coalesce((r->>'refeito')::boolean, false), coalesce((r->>'cancelado')::boolean, false),
      coalesce((r->>'nao_retirado')::boolean, false), coalesce((r->>'saldo_aberto')::boolean, false),
      case when r->>'ts' ~ '^[0-9]{10,}$' then to_timestamp((r->>'ts')::bigint / 1000.0) end,
      coalesce(v_ent, now()), v_hash, v_s)
    on conflict (id_origem) do update set unidade_id = excluded.unidade_id, os = excluded.os, pedido = excluded.pedido,
      tipo = excluded.tipo, laboratorio = excluded.laboratorio, col = excluded.col, dt_venda = excluded.dt_venda,
      prazo = excluded.prazo, urgente = excluded.urgente, refeito = excluded.refeito, cancelado = excluded.cancelado,
      nao_retirado = excluded.nao_retirado, saldo_aberto = excluded.saldo_aberto, ultima_mov = excluded.ultima_mov,
      -- sem a data da origem: só reinicia a contagem se a etapa mudou
      entrou_etapa_em = coalesce(v_ent, case when x.col = excluded.col then x.entrou_etapa_em else now() end),
      hash_origem = excluded.hash_origem, sincronizacao_id = excluded.sincronizacao_id,
      atualizado_em = case when x.hash_origem = excluded.hash_origem then x.atualizado_em else now() end;
    v_ids := v_ids || (r->>'id');
  end loop;

  -- alertas: abre os devidos e resolve os que deixaram de valer (só para as OS deste lote)
  for a in
    select x.id_origem, x.unidade_id, d.tipo, d.detalhe from lab.os x, lateral lab._alertas_devidos(x) d
    where x.id_origem = any(v_ids)
  loop
    insert into lab.alertas (tipo, id_origem, unidade_id, detalhe) values (a.tipo, a.id_origem, a.unidade_id, a.detalhe)
    on conflict (tipo, id_origem) where status = 'aberto' do update set detalhe = excluded.detalhe;
    if found then n_ab := n_ab + 1; end if;
  end loop;
  with devidos as (select x.id_origem, d.tipo from lab.os x, lateral lab._alertas_devidos(x) d where x.id_origem = any(v_ids))
  update lab.alertas al set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente_laboratorio: situação deixou de existir'
   where al.status = 'aberto' and al.id_origem = any(v_ids)
     and not exists (select 1 from devidos dv where dv.id_origem = al.id_origem and dv.tipo = al.tipo);
  get diagnostics n_res = row_count;

  insert into lab.sincronizacoes (id, tarefa_id, origem, recebidas, aplicadas, novas, atualizadas, ignoradas,
    alertas_abertos, alertas_resolvidos, hash_lote)
  values (v_s, p_tarefa, p_origem, n_rec, cardinality(v_ids), n_nov, n_atu, n_ign, n_ab, n_res, md5(p_linhas::text));

  return jsonb_build_object('sincronizacao', v_s, 'recebidas', n_rec, 'aplicadas', cardinality(v_ids), 'novas', n_nov,
    'atualizadas', n_atu, 'ignoradas', n_ign, 'alertas_ativos_no_lote', n_ab, 'alertas_resolvidos', n_res,
    'hash_lote', md5(p_linhas::text));
end $$;

create or replace function lab.concluir_sincronizacao(p_tarefa uuid, p_executor text, p_linhas jsonb) returns jsonb
language plpgsql security definer set search_path = lab, core, pg_catalog as $$
declare t record; v jsonb;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id <> 'laboratorio' or t.tipo <> 'lab_sincronizacao' then raise exception 'tarefa não é sincronização do laboratório'; end if;
  v := lab.aplicar_lote(p_tarefa, coalesce(t.payload->>'origem', 'desconhecida'), p_linhas);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', v->>'hash_lote', v);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Validador independente: não usa o resumo do executor; reconta o espelho e reavalia os alertas por conta própria
-- ---------------------------------------------------------------------------
create or replace function lab.validar_sincronizacao(p_tarefa uuid, p_validador text) returns text
language plpgsql security definer set search_path = lab, core, pg_catalog as $$
declare t record; s record; v_erros text[] := '{}'; n int;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  select * into s from lab.sincronizacoes where tarefa_id = p_tarefa order by em desc limit 1;
  if s.id is null then
    v_erros := v_erros || 'sincronização sem registro';
  else
    select count(*) into n from lab.os where sincronizacao_id = s.id;
    if n <> s.aplicadas then v_erros := v_erros || format('espelho tem %s OS do lote, registro diz %s', n, s.aplicadas); end if;
    if s.recebidas <> s.aplicadas + s.ignoradas then v_erros := v_erros || 'recebidas ≠ aplicadas + ignoradas'; end if;
    -- completude: toda OS em andamento com prazo vencido precisa de alerta aberto
    select count(*) into n from lab.os o join lab.etapas e on e.col = o.col
     where o.sincronizacao_id = s.id and e.situacao = 'andamento' and not o.cancelado
       and o.prazo < (now() at time zone 'America/Sao_Paulo')::date
       and not exists (select 1 from lab.alertas a where a.id_origem = o.id_origem and a.tipo = 'prazo_vencido' and a.status = 'aberto');
    if n > 0 then v_erros := v_erros || format('%s OS com prazo vencido sem alerta', n); end if;
    -- coerência: nenhum alerta de prazo aberto para OS encerrada
    select count(*) into n from lab.alertas a join lab.os o on o.id_origem = a.id_origem join lab.etapas e on e.col = o.col
     where o.sincronizacao_id = s.id and a.status = 'aberto' and a.tipo in ('prazo_vencido','parado_na_etapa') and e.situacao <> 'andamento';
    if n > 0 then v_erros := v_erros || format('%s alertas abertos em OS encerrada/aguardando cliente', n); end if;
    -- nada de dado pessoal no espelho (defesa): telefone/CPF não podem aparecer nos campos texto
    select count(*) into n from lab.os where sincronizacao_id = s.id
       and (coalesce(os,'') || ' ' || coalesce(pedido,'') || ' ' || coalesce(laboratorio,'')) ~ '[0-9]{10,}';
    if n > 0 then v_erros := v_erros || format('%s OS com sequência longa de dígitos (possível dado pessoal)', n); end if;
  end if;
  if array_length(v_erros, 1) is null then
    return core.registrar_validacao(p_tarefa, p_validador, true, null, jsonb_build_object('sincronizacao', s.id));
  end if;
  return core.registrar_validacao(p_tarefa, p_validador, false, array_to_string(v_erros, '; '),
    jsonb_build_object('sincronizacao', s.id, 'erros', to_jsonb(v_erros)));
end $$;

-- Cria a tarefa de sincronização da janela atual (15 min). Só com a chave ligada. Idempotente pela janela.
create or replace function lab.agendar_sincronizacao() returns uuid
language plpgsql security definer set search_path = lab, core, pg_catalog as $$
declare v_p uuid; v_janela text;
begin
  if core.cfg('lab.sync.ativo', 'false') <> 'true' then return null; end if;
  select id into v_p from core.principais where agente_id = 'laboratorio';
  v_janela := to_char(date_trunc('hour', now()) + floor(extract(minute from now()) / 15) * interval '15 minutes', 'YYYYMMDDHH24MI');
  return core.criar_tarefa(v_p, 'laboratorio', 'lab_sincronizacao', 'lab.os', 'sincronizar', null,
    jsonb_build_object('origem', core.cfg('lab.sync.origem', 'adm_os_cards')), 'lab:sync:' || v_janela, null, 6);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Painel (mesmas regras da camada de acesso: login vinculado, 2FA, escopo por unidade)
-- ---------------------------------------------------------------------------
create or replace function public.painel_lab(p_unidade text default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[];
begin
  v_eu := painel._entrar('lab', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  un := painel._unidades(v_eu);
  if p_unidade is not null then
    perform painel._exigir(v_eu, 'consultar', p_unidade);
    un := array[p_unidade];
  end if;
  return jsonb_build_object(
    'sincronizacao', jsonb_build_object('ativa', core.cfg('lab.sync.ativo', 'false') = 'true',
       'agente', (select status from core.agentes where id = 'laboratorio'),
       'ultima', (select jsonb_build_object('em', em, 'recebidas', recebidas, 'aplicadas', aplicadas, 'ignoradas', ignoradas)
                  from lab.sincronizacoes order by em desc limit 1)),
    'etapas', (select coalesce(jsonb_agg(jsonb_build_object('col', col, 'nome', coalesce(nome, 'Coluna ' || col), 'situacao', situacao,
                 'parado_dias', parado_dias, 'confirmada', confirmada) order by ordem), '[]'::jsonb) from lab.etapas),
    'unidades', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'nome', u.nome,
        'por_etapa', (select coalesce(jsonb_object_agg(col, n), '{}'::jsonb) from (
                        select o.col, count(*) n from lab.os o join lab.etapas e on e.col = o.col
                        where o.unidade_id = u.id and e.situacao <> 'encerrada' group by 1) x),
        'alertas', (select coalesce(jsonb_object_agg(tipo, n), '{}'::jsonb) from (
                        select tipo, count(*) n from lab.alertas where unidade_id = u.id and status = 'aberto' group by 1) y))
        order by u.nome), '[]'::jsonb)
      from core.unidades u where u.id = any(un)),
    'alertas', (select coalesce(jsonb_agg(r), '[]'::jsonb) from (
        select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'unidade_id', a.unidade_id, 'aberto_em', a.aberto_em,
          'detalhe', painel._mascarar(a.detalhe), 'os', o.os, 'pedido', o.pedido, 'tipo_os', o.tipo,
          'laboratorio', o.laboratorio, 'etapa', coalesce(e.nome, 'Coluna ' || o.col), 'prazo', o.prazo,
          'urgente', o.urgente, 'entrou_etapa_em', o.entrou_etapa_em) r
        from lab.alertas a join lab.os o on o.id_origem = a.id_origem left join lab.etapas e on e.col = o.col
        where a.status = 'aberto' and a.unidade_id = any(un)
        order by o.urgente desc, case a.tipo when 'prazo_vencido' then 0 when 'parado_na_etapa' then 1 when 'sem_pedido_lab' then 2
                 when 'aguardando_retirada' then 3 else 4 end, o.prazo nulls last
        limit 300) q));
end $$;

-- ---------------------------------------------------------------------------
-- 8. Endurecimento (mesmo padrão)
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'lab' loop
    execute format('alter table lab.%I enable row level security', r.tablename);
    execute format('alter table lab.%I force row level security', r.tablename);
    execute format('revoke all on lab.%I from public', r.tablename);
  end loop;
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'lab' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', r.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema lab from anon, authenticated';
    execute 'revoke all on function public.painel_lab(text) from public, anon';
    execute 'grant execute on function public.painel_lab(text) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema lab to service_role';
    execute 'grant select on all tables in schema lab to service_role';
    execute 'grant execute on function public.painel_lab(text) to service_role';
  end if;
end $$;
