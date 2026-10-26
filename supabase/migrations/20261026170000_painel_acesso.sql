-- =============================================================================
-- Idealize AI — Painel administrativo: camada de acesso (v0.5.0)
-- Migração 20261026170000
--
-- O painel (web) só fala com o banco por funções public.painel_* (RPC do PostgREST).
-- Cada chamada:
--   1. exige usuário logado (Supabase Auth) VINCULADO a um principal humano ativo do core;
--   2. exige segundo fator confirmado (JWT com aal = aal2), exceto painel_eu (para o front saber o que pedir);
--   3. respeita limite de chamadas por minuto e fica registrada (core.painel_acessos);
--   4. decide permissão pela MESMA matriz do core (recurso 'painel'), com escopo por unidade;
--   5. devolve dados pessoais mascarados (CPF, telefone, sequências longas de dígitos).
-- Ações humanas passam pelas funções já testadas do core/fin e geram auditoria com o ator real.
-- Nada aqui é executável por anon. Desativar o principal revoga o acesso na hora (checado a cada chamada).
-- =============================================================================

create schema if not exists painel;
revoke all on schema painel from public;

-- ---------------------------------------------------------------------------
-- 1. Registro de acessos (também é a base do limite de requisições)
-- ---------------------------------------------------------------------------
create table if not exists core.painel_acessos (
  id           bigserial primary key,
  principal_id uuid not null references core.principais(id),
  funcao       text not null,
  alvo         text,
  em           timestamptz not null default now()
);
create index if not exists painel_acessos_rate on core.painel_acessos (principal_id, em);
alter table core.painel_acessos enable row level security;
alter table core.painel_acessos force row level security;
revoke all on core.painel_acessos from public;

insert into core.config (chave, valor) values
  ('painel.limite_por_minuto', '240'),
  ('painel.retencao_acessos_dias', '180'),
  ('versao_painel', '0.5.0')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Políticas do recurso 'painel' (mesma matriz versionada do core)
-- ---------------------------------------------------------------------------
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select v.papel, 'painel', v.op, v.risco, 'automatica'
from (values
  ('admin','consultar','baixo'), ('admin','consultar_auditoria','medio'), ('admin','administrar','critico'),
  ('admin','pausar_plataforma','alto'), ('admin','tratar_incidente','medio'), ('admin','reconciliar','alto'),
  ('admin','cancelar_tarefa','medio'), ('admin','tratar_pendencia','medio'), ('admin','aceitar_pendencia_material','alto'),
  ('diretoria','consultar','baixo'), ('diretoria','consultar_auditoria','medio'), ('diretoria','pausar_plataforma','alto'),
  ('diretoria','tratar_incidente','medio'), ('diretoria','reconciliar','alto'), ('diretoria','cancelar_tarefa','medio'),
  ('diretoria','tratar_pendencia','medio'), ('diretoria','aceitar_pendencia_material','alto'),
  ('financeiro','consultar','baixo'), ('financeiro','tratar_pendencia','medio'),
  ('gerente','consultar','baixo'),
  ('consulta','consultar','baixo')
) v(papel, op, risco)
where not exists (select 1 from core.politicas p
                  where p.papel_id = v.papel and p.recurso = 'painel' and p.operacao = v.op and p.ativo);

-- ---------------------------------------------------------------------------
-- 3. Auxiliares (schema painel, não exposto)
-- ---------------------------------------------------------------------------
create or replace function painel._entrar(p_funcao text, p_alvo text default null, p_exigir_2fa boolean default true)
returns uuid
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_uid uuid := auth.uid(); v_eu uuid; v_n int; v_lim int;
begin
  if v_uid is null then raise exception 'não autenticado' using errcode = '42501'; end if;
  select id into v_eu from core.principais where auth_uid = v_uid and tipo = 'usuario' and ativo;
  if v_eu is null then raise exception 'usuário sem acesso ao painel' using errcode = '42501'; end if;
  if p_exigir_2fa and coalesce(auth.jwt()->>'aal', '') <> 'aal2' then
    raise exception 'confirme o segundo fator (2FA) para continuar' using errcode = '42501';
  end if;
  v_lim := coalesce(nullif(core.cfg('painel.limite_por_minuto', '240'), '')::int, 240);
  select count(*) into v_n from core.painel_acessos where principal_id = v_eu and em > now() - interval '1 minute';
  if v_n >= v_lim then raise exception 'muitas requisições; aguarde um minuto' using errcode = '54000'; end if;
  insert into core.painel_acessos (principal_id, funcao, alvo) values (v_eu, p_funcao, p_alvo);
  if random() < 0.01 then
    delete from core.painel_acessos
     where em < now() - make_interval(days => coalesce(nullif(core.cfg('painel.retencao_acessos_dias','180'),'')::int, 180));
  end if;
  return v_eu;
end $$;

-- pode executar a operação do painel na unidade (null = escopo global)
create or replace function painel._pode(p_eu uuid, p_op text, p_unidade text default null) returns boolean
language sql stable security definer set search_path = core, pg_catalog as $$
  select (core.autorizar(p_eu, 'painel', p_op, p_unidade)).categoria = 'automatica'
$$;

create or replace function painel._unidades(p_eu uuid, p_op text default 'consultar') returns text[]
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(array_agg(u.id order by u.id), '{}'::text[])
  from core.unidades u where u.ativo and painel._pode(p_eu, p_op, u.id)
$$;

create or replace function painel._pode_algum(p_eu uuid, p_op text) returns boolean
language sql stable security definer set search_path = core, pg_catalog as $$
  select painel._pode(p_eu, p_op, null) or cardinality(painel._unidades(p_eu, p_op)) > 0
$$;

-- linha com unidade (ou sem unidade = só escopo global) está no alcance do usuário?
create or replace function painel._alcanca(p_eu uuid, p_op text, p_unidade text) returns boolean
language sql stable security definer set search_path = core, pg_catalog as $$
  select case when p_unidade is null then painel._pode(p_eu, p_op, null)
              else painel._pode(p_eu, p_op, p_unidade) end
$$;

create or replace function painel._exigir(p_eu uuid, p_op text, p_unidade text default null) returns void
language plpgsql stable security definer set search_path = core, pg_catalog as $$
begin
  if not painel._alcanca(p_eu, p_op, p_unidade) then
    raise exception 'sem permissão para % %', p_op, coalesce('na unidade ' || p_unidade, 'no escopo global')
      using errcode = '42501';
  end if;
end $$;

create or replace function painel._texto(p_min int, p_valor text, p_nome text) returns text
language plpgsql immutable set search_path = pg_catalog as $$
begin
  if p_valor is null or length(btrim(p_valor)) < p_min then
    raise exception 'informe % (mínimo % caracteres)', p_nome, p_min using errcode = '22023';
  end if;
  return btrim(p_valor);
end $$;

-- Mascaramento: CPF formatado, CPF/telefone/contas (10+ dígitos seguidos) → só os 4 últimos
create or replace function painel._mascarar_texto(s text) returns text
language sql immutable set search_path = pg_catalog as $$
  select regexp_replace(
           regexp_replace(s, '[0-9]{3}\.[0-9]{3}\.[0-9]{3}-([0-9]{2})', '***.***.***-\1', 'g'),
           '[0-9]{6,}([0-9]{4})', '******\1', 'g')
$$;

create or replace function painel._mascarar(p jsonb) returns jsonb
language plpgsql immutable set search_path = pg_catalog as $$
declare k text; v jsonb; r jsonb;
begin
  if p is null then return null; end if;
  case jsonb_typeof(p)
    when 'object' then
      r := '{}'::jsonb;
      for k, v in select * from jsonb_each(p) loop r := r || jsonb_build_object(k, painel._mascarar(v)); end loop;
      return r;
    when 'array' then
      r := '[]'::jsonb;
      for v in select * from jsonb_array_elements(p) loop r := r || jsonb_build_array(painel._mascarar(v)); end loop;
      return r;
    when 'string' then return to_jsonb(painel._mascarar_texto(p #>> '{}'));
    else return p;
  end case;
end $$;

create or replace function painel._final(s text) returns boolean
language sql immutable set search_path = pg_catalog as $$
  select s in ('concluida','falhou','cancelada','rejeitada')
$$;

-- ---------------------------------------------------------------------------
-- 4. Leitura
-- ---------------------------------------------------------------------------
create or replace function public.painel_eu() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; p record;
begin
  v_eu := painel._entrar('eu', null, false);
  select * into p from core.principais where id = v_eu;
  return jsonb_build_object(
    'nome', p.nome,
    'aal2', coalesce(auth.jwt()->>'aal', '') = 'aal2',
    'papeis', (select coalesce(jsonb_agg(jsonb_build_object('papel', pp.papel_id, 'unidade', pp.unidade_id)
                                         order by pp.papel_id, pp.unidade_id), '[]'::jsonb)
               from core.principal_papeis pp
               where pp.principal_id = v_eu and (pp.valido_ate is null or pp.valido_ate > now())),
    'unidades', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'nome', u.nome) order by u.nome), '[]'::jsonb)
                 from core.unidades u where u.id = any(painel._unidades(v_eu))),
    'pode', jsonb_build_object(
      'consultar', painel._pode_algum(v_eu, 'consultar'),
      'consultar_global', painel._pode(v_eu, 'consultar'),
      'auditoria', painel._pode(v_eu, 'consultar_auditoria'),
      'administrar', painel._pode(v_eu, 'administrar'),
      'pausar_plataforma', painel._pode(v_eu, 'pausar_plataforma'),
      'tratar_incidente', painel._pode_algum(v_eu, 'tratar_incidente'),
      'reconciliar', painel._pode_algum(v_eu, 'reconciliar'),
      'cancelar_tarefa', painel._pode_algum(v_eu, 'cancelar_tarefa'),
      'tratar_pendencia', painel._pode_algum(v_eu, 'tratar_pendencia')));
end $$;

create or replace function public.painel_resumo() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; g boolean; un text[];
begin
  v_eu := painel._entrar('resumo');
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  return jsonb_build_object(
    'plataforma_pausada', core.cfg('plataforma_pausada', 'false') = 'true',
    'agentes', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                from (select status, count(*) n from core.agentes group by 1) x),
    'tarefas', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                from (select status, count(*) n from core.tarefas t where g or t.unidade_id = any(un) group by 1) x),
    'tarefas_24h', (select count(*) from core.tarefas t where (g or t.unidade_id = any(un)) and t.criado_em > now() - interval '24 hours'),
    'atrasadas', (select count(*) from core.tarefas t where (g or t.unidade_id = any(un))
                   and t.prazo < now() and not painel._final(t.status)),
    'aprovacoes_pendentes', (select count(*) from core.tarefas t where (g or t.unidade_id = any(un)) and t.status = 'aguardando_aprovacao'),
    'incidentes', (select coalesce(jsonb_object_agg(severidade, n), '{}'::jsonb) from (
                    select i.severidade, count(*) n from core.incidentes i
                    left join core.tarefas t on t.id = i.tarefa_id
                    where i.status <> 'resolvido' and (g or t.unidade_id = any(un)) group by 1) x),
    'falhas_recorrentes', (select count(*) from core.incidentes i left join core.tarefas t on t.id = i.tarefa_id
                           where i.status <> 'resolvido' and i.ocorrencias >= 3 and (g or t.unidade_id = any(un))),
    'pendencias_fin', (select jsonb_build_object('abertas', count(*), 'materiais', count(*) filter (where p.material))
                       from fin.pendencias p where p.status = 'aberta' and (g or p.unidade_id = any(un))),
    'custo_mes', case when g then (select jsonb_build_object(
                     'confirmado', coalesce(sum(valor) filter (where confirmado), 0),
                     'estimado', coalesce(sum(valor) filter (where not confirmado), 0))
                   from core.custos where em >= date_trunc('month', now())) end,
    'integracoes', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                    from (select status, count(*) n from core.integracoes group by 1) x),
    'canal_whatsapp', jsonb_build_object('ativo', core.cfg('fin.whatsapp.ativo', 'false') = 'true',
                                         'responder', core.cfg('fin.whatsapp.responder', 'false') = 'true'),
    'auditoria_integra', case when painel._pode(v_eu, 'consultar_auditoria') then core.verificar_auditoria() is null end,
    'gerado_em', now());
end $$;

create or replace function public.painel_agentes(p_dias int default 30) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; g boolean; un text[]; d int := least(greatest(coalesce(p_dias, 30), 1), 365);
begin
  v_eu := painel._entrar('agentes');
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'nome', a.nome, 'departamento', a.departamento_id, 'status', a.status, 'versao', a.versao,
      'descricao', a.descricao, 'limite_custo_mensal', case when g then a.limite_custo_mensal end,
      'ultima_atividade', c.ultima,
      'tarefas', jsonb_build_object('concluidas', c.concluidas, 'em_andamento', c.andamento,
                   'aguardando_aprovacao', c.aguardando, 'bloqueadas', c.bloqueadas, 'incertas', c.incertas,
                   'falhas', c.falhas, 'atrasadas', c.atrasadas),
      'periodo_dias', d,
      'execucoes', x.execucoes,
      'tempo_medio_s', round(x.tempo_medio::numeric, 1),
      'taxa_sucesso', round(x.ok::numeric / nullif(x.execucoes, 0), 4),
      'erros', x.erros,
      'taxa_retrabalho', round(x.retrabalho::numeric / nullif(x.tarefas_exec, 0), 4),
      'aprovacoes_solicitadas', c.aprov_periodo,
      'custo_mes', case when g then jsonb_build_object('confirmado', coalesce(cu.conf, 0), 'estimado', coalesce(cu.est, 0)) end,
      'tokens_mes', case when g then jsonb_build_object('entrada', coalesce(cu.tin, 0), 'saida', coalesce(cu.tout, 0)) end,
      'incidentes_abertos', (select count(*) from core.incidentes i left join core.tarefas t on t.id = i.tarefa_id
                             where i.agente_id = a.id and i.status <> 'resolvido' and (g or t.unidade_id = any(un))),
      -- sem fonte de medição ainda: não inventar números
      'economia_estimada', null, 'economia_confirmada', null, 'disponibilidade', null
    ) order by a.nome), '[]'::jsonb)
  from core.agentes a
  left join lateral (
    select max(t.atualizado_em) ultima,
      count(*) filter (where t.status = 'concluida') concluidas,
      count(*) filter (where t.status in ('pendente','pronta','executando','validando')) andamento,
      count(*) filter (where t.status = 'aguardando_aprovacao') aguardando,
      count(*) filter (where t.status = 'bloqueada') bloqueadas,
      count(*) filter (where t.status = 'incerta') incertas,
      count(*) filter (where t.status = 'falhou') falhas,
      count(*) filter (where t.prazo < now() and not painel._final(t.status)) atrasadas,
      count(*) filter (where t.categoria = 'aprovacao' and t.criado_em > now() - make_interval(days => d)) aprov_periodo
    from core.tarefas t where t.agente_id = a.id and (g or t.unidade_id = any(un))) c on true
  left join lateral (
    select count(*) execucoes,
      avg(extract(epoch from e.fim_em - e.inicio_em)) filter (where e.status = 'sucesso') tempo_medio,
      count(*) filter (where e.status = 'sucesso') ok,
      count(*) filter (where e.status in ('erro','incerto','lease_expirado')) erros,
      count(distinct t.id) tarefas_exec,
      count(distinct t.id) filter (where t.tentativas > 1 or exists (
        select 1 from core.validacoes v where v.tarefa_id = t.id and v.resultado = 'rejeitada')) retrabalho
    from core.execucoes e join core.tarefas t on t.id = e.tarefa_id
    where t.agente_id = a.id and (g or t.unidade_id = any(un)) and e.inicio_em > now() - make_interval(days => d)) x on true
  left join lateral (
    select sum(valor) filter (where confirmado) conf, sum(valor) filter (where not confirmado) est,
           sum(tokens_in) tin, sum(tokens_out) tout
    from core.custos cu where cu.agente_id = a.id and cu.em >= date_trunc('month', now())) cu on true);
end $$;

create or replace function public.painel_tarefas(p_status text[] default null, p_agente text default null,
  p_unidade text default null, p_busca text default null, p_limite int default 50, p_antes timestamptz default null)
returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; g boolean; un text[]; lim int := least(greatest(coalesce(p_limite, 50), 1), 200);
begin
  v_eu := painel._entrar('tarefas');
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  return (select coalesce(jsonb_agg(r order by r->>'atualizado_em' desc), '[]'::jsonb) from (
    select jsonb_build_object('id', t.id, 'agente_id', t.agente_id, 'tipo', t.tipo, 'recurso', t.recurso,
      'operacao', t.operacao, 'unidade_id', t.unidade_id, 'valor', t.valor, 'status', t.status,
      'prioridade', t.prioridade, 'risco', t.risco, 'categoria', t.categoria, 'tentativas', t.tentativas,
      'prazo', t.prazo, 'atrasada', coalesce(t.prazo < now() and not painel._final(t.status), false),
      'motivo', painel._mascarar_texto(t.motivo), 'criado_em', t.criado_em, 'atualizado_em', t.atualizado_em) r
    from core.tarefas t
    where (g or t.unidade_id = any(un))
      and (p_status is null or t.status = any(p_status))
      and (p_agente is null or t.agente_id = p_agente)
      and (p_unidade is null or t.unidade_id = p_unidade)
      and (p_antes is null or t.atualizado_em < p_antes)
      and (p_busca is null or t.id::text = p_busca or t.tipo ilike '%' || p_busca || '%'
           or t.motivo ilike '%' || p_busca || '%' or t.operacao ilike '%' || p_busca || '%')
    order by t.atualizado_em desc limit lim) q);
end $$;

create or replace function painel._pode_aprovar(p_eu uuid, p_tarefa uuid) returns boolean
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce((
    select t.status = 'aguardando_aprovacao' and t.solicitante_id is distinct from p_eu
       and not exists (select 1 from core.aprovacoes ap where ap.tarefa_id = t.id and ap.aprovador_id = p_eu)
       and exists (select 1 from core.principal_papeis pp where pp.principal_id = p_eu and pp.papel_id = po.papel_aprovador
                    and (pp.unidade_id is null or pp.unidade_id = t.unidade_id) and (pp.valido_ate is null or pp.valido_ate > now()))
    from core.tarefas t join core.politicas po on po.id = t.politica_id where t.id = p_tarefa), false)
$$;

create or replace function public.painel_tarefa(p_id uuid) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; t record; po record;
begin
  v_eu := painel._entrar('tarefa', p_id::text);
  select * into t from core.tarefas where id = p_id;
  if t.id is null or not painel._alcanca(v_eu, 'consultar', t.unidade_id) then
    raise exception 'tarefa inexistente ou fora do seu alcance' using errcode = '42501';
  end if;
  select * into po from core.politicas where id = t.politica_id;
  return jsonb_build_object(
    'tarefa', jsonb_build_object('id', t.id, 'correlacao_id', t.correlacao_id, 'agente_id', t.agente_id, 'tipo', t.tipo,
      'recurso', t.recurso, 'operacao', t.operacao, 'unidade_id', t.unidade_id, 'valor', t.valor, 'status', t.status,
      'prioridade', t.prioridade, 'risco', t.risco, 'categoria', t.categoria, 'tentativas', t.tentativas,
      'max_tentativas', t.max_tentativas, 'prazo', t.prazo, 'proximo_em', t.proximo_em, 'executor', t.executor,
      'motivo', painel._mascarar_texto(t.motivo), 'payload', painel._mascarar(t.payload),
      'resultado', painel._mascarar(t.resultado), 'hash_operacao', t.hash_operacao,
      'solicitante', (select nome from core.principais where id = t.solicitante_id),
      'criado_em', t.criado_em, 'atualizado_em', t.atualizado_em),
    'politica', case when po.id is not null then jsonb_build_object('id', po.id, 'versao', po.versao, 'risco', po.risco,
      'categoria', po.categoria, 'aprovadores_minimos', po.aprovadores_minimos, 'papel_aprovador', po.papel_aprovador,
      'limite_valor', po.limite_valor) end,
    'execucoes', (select coalesce(jsonb_agg(jsonb_build_object('tentativa', e.tentativa, 'executor', e.executor,
        'status', e.status, 'inicio_em', e.inicio_em, 'fim_em', e.fim_em, 'efeito_externo_id', painel._mascarar_texto(e.efeito_externo_id),
        'erro', painel._mascarar_texto(e.erro), 'evidencia', painel._mascarar(e.evidencia)) order by e.tentativa), '[]'::jsonb)
      from core.execucoes e where e.tarefa_id = t.id),
    'validacoes', (select coalesce(jsonb_agg(jsonb_build_object('validador', v.validador, 'resultado', v.resultado,
        'motivo', painel._mascarar_texto(v.motivo), 'evidencia', painel._mascarar(v.evidencia), 'em', v.em) order by v.em), '[]'::jsonb)
      from core.validacoes v where v.tarefa_id = t.id),
    'aprovacoes', (select coalesce(jsonb_agg(jsonb_build_object('aprovador', pr.nome, 'decisao', ap.decisao, 'canal', ap.canal,
        'comentario', painel._mascarar_texto(ap.comentario), 'em', ap.criado_em, 'expira_em', ap.expira_em,
        'vale', ap.hash_operacao = t.hash_operacao and ap.expira_em > now()) order by ap.criado_em), '[]'::jsonb)
      from core.aprovacoes ap join core.principais pr on pr.id = ap.aprovador_id where ap.tarefa_id = t.id),
    'dependencias', (select coalesce(jsonb_agg(jsonb_build_object('id', d.depende_de, 'status', dt.status)), '[]'::jsonb)
      from core.tarefa_dependencias d join core.tarefas dt on dt.id = d.depende_de where d.tarefa_id = t.id),
    'incidentes', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'titulo', i.titulo, 'severidade', i.severidade,
        'status', i.status, 'ocorrencias', i.ocorrencias)), '[]'::jsonb) from core.incidentes i where i.tarefa_id = t.id),
    'historico', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'em', a.em, 'acao', a.acao,
        'ator', coalesce((select nome from core.principais where id = a.ator_id), a.ator),
        'antes', painel._mascarar(a.antes), 'depois', painel._mascarar(a.depois), 'motivo', painel._mascarar_texto(a.motivo))
        order by a.id), '[]'::jsonb)
      from core.auditoria a where a.entidade = 'tarefa' and a.entidade_id = t.id::text),
    'pode', jsonb_build_object(
      'aprovar', painel._pode_aprovar(v_eu, t.id),
      'reconciliar', t.status = 'incerta' and painel._alcanca(v_eu, 'reconciliar', t.unidade_id),
      'cancelar', t.status not in ('executando','validando','concluida','incerta','cancelada','rejeitada','falhou')
                  and painel._alcanca(v_eu, 'cancelar_tarefa', t.unidade_id)));
end $$;

create or replace function public.painel_aprovacoes() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; g boolean; un text[];
begin
  v_eu := painel._entrar('aprovacoes');
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id, 'agente_id', t.agente_id, 'tipo', t.tipo, 'recurso', t.recurso, 'operacao', t.operacao,
      'unidade_id', t.unidade_id, 'valor', t.valor, 'risco', t.risco, 'prioridade', t.prioridade,
      'motivo', painel._mascarar_texto(t.motivo), 'payload', painel._mascarar(t.payload),
      'hash_operacao', t.hash_operacao, 'criado_em', t.criado_em,
      'solicitante', (select nome from core.principais where id = t.solicitante_id),
      'papel_aprovador', po.papel_aprovador, 'aprovadores_minimos', po.aprovadores_minimos,
      'aprovacoes_validas', (select count(*) from core.aprovacoes ap where ap.tarefa_id = t.id and ap.decisao = 'aprovar'
                             and ap.hash_operacao = t.hash_operacao and ap.expira_em > now()),
      'pode_aprovar', painel._pode_aprovar(v_eu, t.id)) order by t.prioridade, t.criado_em), '[]'::jsonb)
    from core.tarefas t left join core.politicas po on po.id = t.politica_id
    where t.status = 'aguardando_aprovacao' and (g or t.unidade_id = any(un)));
end $$;

create or replace function public.painel_incidentes(p_abertos boolean default true, p_limite int default 100) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; g boolean; un text[]; lim int := least(greatest(coalesce(p_limite, 100), 1), 500);
begin
  v_eu := painel._entrar('incidentes');
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  return (select coalesce(jsonb_agg(r), '[]'::jsonb) from (
    select jsonb_build_object('id', i.id, 'chave', i.chave_agrupamento, 'severidade', i.severidade, 'status', i.status,
      'titulo', i.titulo, 'agente_id', i.agente_id, 'integracao_id', i.integracao_id, 'tarefa_id', i.tarefa_id,
      'unidade_id', t.unidade_id, 'ocorrencias', i.ocorrencias, 'escalonado', i.escalonado,
      'primeira_em', i.primeira_em, 'ultima_em', i.ultima_em, 'resolvido_em', i.resolvido_em,
      'detalhes', painel._mascarar(i.detalhes),
      'pode_tratar', i.status <> 'resolvido' and painel._alcanca(v_eu, 'tratar_incidente', t.unidade_id)) r
    from core.incidentes i left join core.tarefas t on t.id = i.tarefa_id
    where (g or t.unidade_id = any(un)) and (not coalesce(p_abertos, true) or i.status <> 'resolvido')
    order by case i.severidade when 'critica' then 0 when 'alta' then 1 when 'media' then 2 when 'baixa' then 3 else 4 end,
             i.ultima_em desc
    limit lim) q);
end $$;

create or replace function public.painel_pendencias(p_unidade text default null, p_tipo text default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; g boolean; un text[];
begin
  v_eu := painel._entrar('pendencias', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'tipo', p.tipo, 'unidade_id', p.unidade_id, 'material', p.material, 'referencia', p.referencia,
      'detalhe', painel._mascarar(p.detalhe), 'criado_em', p.criado_em,
      'lancamento', case when l.id is not null then jsonb_build_object('numero', l.numero, 'valor', l.valor,
          'natureza', l.natureza, 'sentido', l.sentido, 'categoria_id', l.categoria_id, 'data_competencia', l.data_competencia,
          'descricao', painel._mascarar_texto(coalesce(l.descricao, l.contraparte_nome))) end,
      'movimento', case when m.id is not null then jsonb_build_object('data', m.data, 'valor', m.valor, 'sentido', m.sentido,
          'conta_id', m.conta_id, 'descricao', painel._mascarar_texto(m.descricao)) end,
      'pode_tratar', painel._alcanca(v_eu, 'tratar_pendencia', p.unidade_id),
      'pode_aceitar', painel._alcanca(v_eu, case when p.material then 'aceitar_pendencia_material' else 'tratar_pendencia' end, p.unidade_id)
    ) order by p.material desc, p.criado_em), '[]'::jsonb)
    from fin.pendencias p
    left join fin.lancamentos l on l.id = p.lancamento_id
    left join fin.movimentos m on m.id = p.movimento_id
    where p.status = 'aberta' and (g or p.unidade_id = any(un))
      and (p_unidade is null or p.unidade_id = p_unidade) and (p_tipo is null or p.tipo = p_tipo));
end $$;

create or replace function public.painel_custos(p_inicio date default null, p_fim date default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; g boolean; un text[];
  i date := coalesce(p_inicio, date_trunc('month', now())::date); f date := coalesce(p_fim, now()::date);
begin
  v_eu := painel._entrar('custos');
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  if f < i or f - i > 400 then raise exception 'período inválido (máx. 400 dias)' using errcode = '22023'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  return (with c as (
      select cu.*, a.departamento_id from core.custos cu join core.agentes a on a.id = cu.agente_id
      where cu.em >= i and cu.em < f + 1 and (g or cu.unidade_id = any(un))),
    por as (select dim, chave, sum(valor) filter (where confirmado) conf, sum(valor) filter (where not confirmado) est,
                   sum(tokens_in) tin, sum(tokens_out) tout, count(*) n
            from (select 'agente' dim, agente_id chave, * from c union all
                  select 'departamento', departamento_id, * from c union all
                  select 'unidade', coalesce(unidade_id, '(sem unidade)'), * from c union all
                  select 'modelo', coalesce(modelo, '(sem modelo)'), * from c union all
                  select 'integracao', coalesce(integracao, '(sem integração)'), * from c union all
                  select 'tipo_tarefa', coalesce(tipo_tarefa, '(sem tipo)'), * from c union all
                  select 'dia', to_char(em, 'YYYY-MM-DD'), * from c) z
            group by 1, 2)
    select jsonb_build_object('inicio', i, 'fim', f,
      'total', (select jsonb_build_object('confirmado', coalesce(sum(valor) filter (where confirmado), 0),
                  'estimado', coalesce(sum(valor) filter (where not confirmado), 0), 'registros', count(*)) from c),
      'por', (select coalesce(jsonb_object_agg(dim, itens), '{}'::jsonb) from (
               select dim, jsonb_agg(jsonb_build_object('chave', chave, 'confirmado', coalesce(conf, 0), 'estimado', coalesce(est, 0),
                        'tokens_entrada', coalesce(tin, 0), 'tokens_saida', coalesce(tout, 0), 'registros', n)
                        order by case when dim = 'dia' then chave end, coalesce(conf, 0) + coalesce(est, 0) desc) itens
               from por group by dim) y),
      'limites', case when g then (select coalesce(jsonb_agg(jsonb_build_object('agente_id', a.id, 'nome', a.nome,
                     'limite', a.limite_custo_mensal, 'consumo_mes', core.custo_mes(a.id),
                     'percentual', round(100 * core.custo_mes(a.id) / nullif(a.limite_custo_mensal, 0), 1)) order by a.nome), '[]'::jsonb)
                   from core.agentes a) end));
end $$;

create or replace function public.painel_financeiro(p_competencia date default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; g boolean; un text[]; c date := date_trunc('month', coalesce(p_competencia, now()::date))::date;
begin
  v_eu := painel._entrar('financeiro', c::text);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  return jsonb_build_object('competencia', c,
    'unidades', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'nome', u.nome,
        'receitas', coalesce(d.rec, 0), 'despesas', coalesce(d.desp, 0), 'resultado', coalesce(d.rec, 0) - coalesce(d.desp, 0),
        'caixa_entradas', coalesce(cx.ent, 0), 'caixa_saidas', coalesce(cx.sai, 0),
        'pendencias_abertas', coalesce(pe.n, 0), 'pendencias_materiais', coalesce(pe.m, 0),
        'fechamento', (select jsonb_build_object('id', f.id, 'status', f.status, 'versao', f.versao,
                         'pendencias_materiais', f.pendencias_materiais, 'pacote_hash', f.pacote_hash,
                         'preparado_por', f.preparado_por, 'validado_por', f.validado_por,
                         'decidido_em', f.decidido_em, 'criado_em', f.criado_em)
                       from fin.fechamentos f where f.unidade_id = u.id and f.competencia = c
                       order by f.criado_em desc limit 1)) order by u.nome), '[]'::jsonb)
      from core.unidades u
      left join lateral (select sum(valor) filter (where natureza = 'receita') rec, sum(valor) filter (where natureza = 'despesa') desp
                         from fin.v_dre where unidade_id = u.id and competencia = c) d on true
      left join lateral (select sum(entradas) ent, sum(saidas) sai from fin.v_caixa_unidade
                         where unidade_id = u.id and data >= c and data < (c + interval '1 month')::date) cx on true
      left join lateral (select count(*) n, count(*) filter (where material) m from fin.pendencias
                         where unidade_id = u.id and status = 'aberta') pe on true
      where u.id = any(un)),
    'consolidado', case when g then (select jsonb_build_object(
        'receitas', coalesce(sum(valor) filter (where natureza = 'receita'), 0),
        'despesas', coalesce(sum(valor) filter (where natureza = 'despesa'), 0),
        'caixa_entradas', (select coalesce(sum(entradas), 0) from fin.v_caixa_consolidado where data >= c and data < (c + interval '1 month')::date),
        'caixa_saidas', (select coalesce(sum(saidas), 0) from fin.v_caixa_consolidado where data >= c and data < (c + interval '1 month')::date))
      from fin.v_dre where competencia = c) end);
end $$;

create or replace function public.painel_dre(p_unidade text, p_competencia date default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; c date := date_trunc('month', coalesce(p_competencia, now()::date))::date;
begin
  v_eu := painel._entrar('dre', p_unidade);
  perform painel._exigir(v_eu, 'consultar', p_unidade);
  if p_unidade is null then raise exception 'informe a unidade' using errcode = '22023'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('natureza', d.natureza, 'grupo', coalesce(ca.grupo, '(sem grupo)'),
      'categoria_id', d.categoria_id, 'categoria', coalesce(ca.nome, '(sem categoria)'), 'valor', d.valor, 'tem_rateio', d.tem_rateio)
      order by d.natureza desc, ca.grupo, d.valor desc), '[]'::jsonb)
    from fin.v_dre d left join fin.categorias ca on ca.id = d.categoria_id
    where d.unidade_id = p_unidade and d.competencia = c);
end $$;

create or replace function public.painel_auditoria(p_entidade text default null, p_busca text default null,
  p_limite int default 100, p_antes bigint default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; lim int := least(greatest(coalesce(p_limite, 100), 1), 500);
begin
  v_eu := painel._entrar('auditoria', p_entidade);
  perform painel._exigir(v_eu, 'consultar_auditoria');
  return (select coalesce(jsonb_agg(r order by (r->>'id')::bigint desc), '[]'::jsonb) from (
    select jsonb_build_object('id', a.id, 'em', a.em, 'acao', a.acao, 'entidade', a.entidade, 'entidade_id', a.entidade_id,
      'ator', coalesce((select nome from core.principais where id = a.ator_id), a.ator),
      'antes', painel._mascarar(a.antes), 'depois', painel._mascarar(a.depois),
      'motivo', painel._mascarar_texto(a.motivo), 'hash', left(a.hash, 16)) r
    from core.auditoria a
    where (p_entidade is null or a.entidade = p_entidade) and (p_antes is null or a.id < p_antes)
      and (p_busca is null or a.acao ilike '%' || p_busca || '%' or a.entidade_id = p_busca or a.motivo ilike '%' || p_busca || '%')
    order by a.id desc limit lim) q);
end $$;

create or replace function public.painel_auditoria_verificar() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_primeiro bigint;
begin
  v_eu := painel._entrar('auditoria_verificar');
  perform painel._exigir(v_eu, 'consultar_auditoria');
  v_primeiro := core.verificar_auditoria();
  return jsonb_build_object('integra', v_primeiro is null, 'primeiro_adulterado', v_primeiro,
    'eventos', (select count(*) from core.auditoria), 'verificado_em', now());
end $$;

create or replace function public.painel_operacao() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; g boolean; v_mig jsonb; v_cron jsonb;
begin
  v_eu := painel._entrar('operacao');
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar');
  if g and to_regclass('supabase_migrations.schema_migrations') is not null then
    execute 'select coalesce(jsonb_agg(jsonb_build_object(''versao'', version, ''nome'', name) order by version desc), ''[]''::jsonb)
             from supabase_migrations.schema_migrations' into v_mig;
  end if;
  if g and to_regclass('cron.job') is not null then
    execute 'select coalesce(jsonb_agg(jsonb_build_object(''nome'', jobname, ''agenda'', schedule, ''ativo'', active) order by jobname), ''[]''::jsonb)
             from cron.job' into v_cron;
  end if;
  return jsonb_build_object(
    'integracoes', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'status', status,
                      'escrita_habilitada', escrita_habilitada, 'ultimo_ok_em', ultimo_ok_em, 'observacoes', observacoes)
                      order by nome), '[]'::jsonb) from core.integracoes),
    'chaves', jsonb_build_object(
      'plataforma_pausada', core.cfg('plataforma_pausada', 'false') = 'true',
      'fin_whatsapp_ativo', core.cfg('fin.whatsapp.ativo', 'false') = 'true',
      'fin_whatsapp_responder', core.cfg('fin.whatsapp.responder', 'false') = 'true'),
    'versoes', jsonb_build_object(
      'componentes', (select coalesce(jsonb_object_agg(chave, valor), '{}'::jsonb) from core.config where chave like 'versao_%'),
      'agentes', (select coalesce(jsonb_object_agg(id, versao), '{}'::jsonb) from core.agentes),
      'migracoes', v_mig),
    'agendamentos', jsonb_build_object(
      'cron', v_cron,
      'tarefas_futuras', (select count(*) from core.tarefas t where t.status = 'pronta' and t.proximo_em > now()
                          and (g or t.unidade_id = any(painel._unidades(v_eu)))),
      'proxima_tarefa_em', (select min(proximo_em) from core.tarefas t where t.status = 'pronta' and t.proximo_em > now()
                          and (g or t.unidade_id = any(painel._unidades(v_eu))))));
end $$;

create or replace function public.painel_usuarios() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('usuarios');
  perform painel._exigir(v_eu, 'administrar');
  return jsonb_build_object(
    'principais', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'tipo', pr.tipo, 'nome', pr.nome, 'ativo', pr.ativo,
        'vinculado', pr.auth_uid is not null, 'eu', pr.id = v_eu, 'agente_id', pr.agente_id,
        'telefone', case when pr.telefone is not null then '••••' || right(pr.telefone, 4) end,
        'papeis', (select coalesce(jsonb_agg(jsonb_build_object('papel', pp.papel_id, 'unidade', pp.unidade_id,
                     'valido_ate', pp.valido_ate) order by pp.papel_id, pp.unidade_id), '[]'::jsonb)
                   from core.principal_papeis pp where pp.principal_id = pr.id)) order by pr.tipo desc, pr.nome), '[]'::jsonb)
      from core.principais pr),
    'papeis', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by id), '[]'::jsonb) from core.papeis),
    'unidades', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'ativo', ativo) order by nome), '[]'::jsonb) from core.unidades),
    'politicas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'versao', versao, 'papel', papel_id, 'recurso', recurso,
        'operacao', operacao, 'unidade', unidade_id, 'risco', risco, 'categoria', categoria, 'limite_valor', limite_valor,
        'aprovadores_minimos', aprovadores_minimos, 'papel_aprovador', papel_aprovador, 'valido_de', valido_de)
        order by recurso, operacao, papel_id), '[]'::jsonb)
      from core.politicas where ativo));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Ações (todas auditadas com o ator real)
-- ---------------------------------------------------------------------------
create or replace function public.painel_aprovar(p_tarefa uuid, p_decisao text, p_hash text, p_comentario text default null)
returns text
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; t record;
begin
  v_eu := painel._entrar('aprovar', p_tarefa::text);
  select * into t from core.tarefas where id = p_tarefa;
  if t.id is null or not painel._alcanca(v_eu, 'consultar', t.unidade_id) then
    raise exception 'tarefa inexistente ou fora do seu alcance' using errcode = '42501';
  end if;
  if p_decisao not in ('aprovar', 'rejeitar') then raise exception 'decisão inválida' using errcode = '22023'; end if;
  if p_decisao = 'rejeitar' then perform painel._texto(5, p_comentario, 'motivo da rejeição'); end if;
  return core.aprovar(p_tarefa, v_eu, p_decisao, p_hash, 'painel', nullif(btrim(coalesce(p_comentario, '')), ''));
end $$;

create or replace function public.painel_reconciliar(p_tarefa uuid, p_efetivada boolean, p_evidencia text, p_motivo text)
returns text
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; t record;
begin
  v_eu := painel._entrar('reconciliar', p_tarefa::text);
  select * into t from core.tarefas where id = p_tarefa;
  if t.id is null then raise exception 'tarefa inexistente' using errcode = '42501'; end if;
  perform painel._exigir(v_eu, 'reconciliar', t.unidade_id);
  return core.reconciliar(p_tarefa, v_eu, coalesce(p_efetivada, false),
    jsonb_build_object('canal', 'painel', 'evidencia', painel._texto(5, p_evidencia, 'evidência')),
    painel._texto(5, p_motivo, 'motivo'));
end $$;

create or replace function public.painel_cancelar_tarefa(p_tarefa uuid, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; t record; v_motivo text;
begin
  v_eu := painel._entrar('cancelar_tarefa', p_tarefa::text);
  select * into t from core.tarefas where id = p_tarefa;
  if t.id is null then raise exception 'tarefa inexistente' using errcode = '42501'; end if;
  perform painel._exigir(v_eu, 'cancelar_tarefa', t.unidade_id);
  v_motivo := painel._texto(5, p_motivo, 'motivo');
  if t.status in ('cancelada','rejeitada','falhou') then raise exception 'tarefa já encerrada (status=%)', t.status; end if;
  perform core.cancelar_tarefa(p_tarefa, v_eu, v_motivo);
  perform core.auditar(v_eu, null, 'tarefa_cancelada', 'tarefa', p_tarefa::text,
    jsonb_build_object('status', t.status), jsonb_build_object('status', 'cancelada', 'canal', 'painel'), v_motivo);
end $$;

create or replace function public.painel_incidente_tratar(p_incidente bigint, p_status text, p_nota text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; i record; v_un text; v_nota text;
begin
  v_eu := painel._entrar('incidente_tratar', p_incidente::text);
  select * into i from core.incidentes where id = p_incidente for update;
  if i.id is null then raise exception 'incidente inexistente' using errcode = '42501'; end if;
  select unidade_id into v_un from core.tarefas where id = i.tarefa_id;
  perform painel._exigir(v_eu, 'tratar_incidente', v_un);
  if p_status not in ('em_tratamento', 'resolvido') then raise exception 'status inválido' using errcode = '22023'; end if;
  if i.status = 'resolvido' then raise exception 'incidente já resolvido'; end if;
  v_nota := painel._texto(case when p_status = 'resolvido' then 10 else 3 end, p_nota, 'nota');
  update core.incidentes set status = p_status,
    resolvido_em = case when p_status = 'resolvido' then now() end,
    detalhes = coalesce(detalhes, '{}'::jsonb) || jsonb_build_object('tratamento',
      coalesce(detalhes->'tratamento', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'em', now(), 'por', (select nome from core.principais where id = v_eu), 'status', p_status, 'nota', v_nota)))
   where id = p_incidente;
  perform core.auditar(v_eu, null, 'incidente_' || p_status, 'incidente', p_incidente::text,
    jsonb_build_object('status', i.status), jsonb_build_object('status', p_status), v_nota);
end $$;

create or replace function public.painel_pendencia_tratar(p_pendencia bigint, p_acao text, p_texto text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; p record; v_txt text;
begin
  v_eu := painel._entrar('pendencia_tratar', p_pendencia::text);
  select * into p from fin.pendencias where id = p_pendencia for update;
  if p.id is null then raise exception 'pendência inexistente' using errcode = '42501'; end if;
  if p.status <> 'aberta' then raise exception 'pendência não está aberta (status=%)', p.status; end if;
  if p_acao not in ('resolver', 'aceitar') then raise exception 'ação inválida' using errcode = '22023'; end if;
  perform painel._exigir(v_eu, 'tratar_pendencia', p.unidade_id);
  if p_acao = 'aceitar' and p.material then perform painel._exigir(v_eu, 'aceitar_pendencia_material', p.unidade_id); end if;
  v_txt := painel._texto(10, p_texto, case when p_acao = 'aceitar' then 'justificativa' else 'descrição da resolução' end);
  update fin.pendencias set status = case when p_acao = 'aceitar' then 'aceita' else 'resolvida' end,
    resolvido_por = v_eu, resolucao = v_txt, resolvido_em = now() where id = p_pendencia;
  perform core.auditar(v_eu, null, 'pendencia_' || case when p_acao = 'aceitar' then 'aceita' else 'resolvida' end,
    'fin.pendencia', p_pendencia::text, jsonb_build_object('status', 'aberta', 'tipo', p.tipo, 'material', p.material),
    jsonb_build_object('status', case when p_acao = 'aceitar' then 'aceita' else 'resolvida' end, 'canal', 'painel'), v_txt);
end $$;

create or replace function public.painel_fechamento_decidir(p_fechamento uuid, p_aprovar boolean, p_hash text, p_motivo text default null)
returns text
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; f record;
begin
  v_eu := painel._entrar('fechamento_decidir', p_fechamento::text);
  select * into f from fin.fechamentos where id = p_fechamento;
  if f.id is null or not painel._alcanca(v_eu, 'consultar', f.unidade_id) then
    raise exception 'fechamento inexistente ou fora do seu alcance' using errcode = '42501';
  end if;
  return fin.decidir_fechamento(p_fechamento, v_eu, coalesce(p_aprovar, false), p_hash, nullif(btrim(coalesce(p_motivo, '')), ''));
end $$;

create or replace function public.painel_agente_status(p_agente text, p_status text, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; a record; v_motivo text;
begin
  v_eu := painel._entrar('agente_status', p_agente);
  perform painel._exigir(v_eu, 'administrar');
  if p_status not in ('ativo', 'pausado') then raise exception 'status inválido (use ativo ou pausado)' using errcode = '22023'; end if;
  v_motivo := painel._texto(5, p_motivo, 'motivo');
  select * into a from core.agentes where id = p_agente for update;
  if a.id is null then raise exception 'agente inexistente'; end if;
  if a.status = 'desativado' then raise exception 'agente desativado não é religado pelo painel'; end if;
  update core.agentes set status = p_status, atualizado_em = now() where id = p_agente;
  perform core.auditar(v_eu, null, 'agente_status', 'agente', p_agente,
    jsonb_build_object('status', a.status), jsonb_build_object('status', p_status, 'canal', 'painel'), v_motivo);
end $$;

create or replace function public.painel_plataforma_pausar(p_pausar boolean, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_motivo text; v_antes text := core.cfg('plataforma_pausada', 'false');
begin
  v_eu := painel._entrar('plataforma_pausar', p_pausar::text);
  if p_pausar is null then raise exception 'informe pausar ou retomar' using errcode = '22023'; end if;
  -- pausar (modo seguro) é mais fácil que despausar: diretoria pausa, só admin retoma
  perform painel._exigir(v_eu, case when p_pausar then 'pausar_plataforma' else 'administrar' end);
  v_motivo := painel._texto(5, p_motivo, 'motivo');
  insert into core.config (chave, valor) values ('plataforma_pausada', p_pausar::text)
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  perform core.auditar(v_eu, null, case when p_pausar then 'plataforma_pausada' else 'plataforma_retomada' end,
    'config', 'plataforma_pausada', jsonb_build_object('valor', v_antes), jsonb_build_object('valor', p_pausar::text, 'canal', 'painel'), v_motivo);
end $$;

create or replace function painel._alvo_humano(p_eu uuid, p_principal uuid) returns void
language plpgsql stable security definer set search_path = core, pg_catalog as $$
begin
  if p_principal = p_eu then raise exception 'você não altera o próprio acesso pelo painel' using errcode = '42501'; end if;
  if not exists (select 1 from core.principais where id = p_principal and tipo = 'usuario') then
    raise exception 'só pessoas são gerenciadas pelo painel (agentes não)' using errcode = '42501';
  end if;
end $$;

create or replace function public.painel_papel_conceder(p_principal uuid, p_papel text, p_unidade text,
  p_valido_ate timestamptz, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_motivo text;
begin
  v_eu := painel._entrar('papel_conceder', p_principal::text);
  perform painel._exigir(v_eu, 'administrar');
  perform painel._alvo_humano(v_eu, p_principal);
  v_motivo := painel._texto(5, p_motivo, 'motivo');
  if not exists (select 1 from core.papeis where id = p_papel) or p_papel like 'agente\_%' then
    raise exception 'papel inválido para pessoa' using errcode = '22023';
  end if;
  if p_unidade is not null and not exists (select 1 from core.unidades where id = p_unidade and ativo) then
    raise exception 'unidade inválida' using errcode = '22023';
  end if;
  if p_papel = 'admin' and p_unidade is not null then raise exception 'admin é sempre global' using errcode = '22023'; end if;
  if p_valido_ate is not null and p_valido_ate <= now() then raise exception 'validade no passado' using errcode = '22023'; end if;
  if exists (select 1 from core.principal_papeis where principal_id = p_principal and papel_id = p_papel
             and unidade_id is not distinct from p_unidade) then
    raise exception 'papel já concedido nesse escopo';
  end if;
  insert into core.principal_papeis (principal_id, papel_id, unidade_id, valido_ate) values (p_principal, p_papel, p_unidade, p_valido_ate);
  perform core.auditar(v_eu, null, 'papel_concedido', 'principal', p_principal::text, null,
    jsonb_build_object('papel', p_papel, 'unidade', p_unidade, 'valido_ate', p_valido_ate, 'canal', 'painel'), v_motivo);
end $$;

create or replace function public.painel_papel_revogar(p_principal uuid, p_papel text, p_unidade text, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_motivo text; v_n int;
begin
  v_eu := painel._entrar('papel_revogar', p_principal::text);
  perform painel._exigir(v_eu, 'administrar');
  perform painel._alvo_humano(v_eu, p_principal);
  v_motivo := painel._texto(5, p_motivo, 'motivo');
  delete from core.principal_papeis where principal_id = p_principal and papel_id = p_papel and unidade_id is not distinct from p_unidade;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'papel não encontrado nesse escopo'; end if;
  perform core.auditar(v_eu, null, 'papel_revogado', 'principal', p_principal::text,
    jsonb_build_object('papel', p_papel, 'unidade', p_unidade), jsonb_build_object('canal', 'painel'), v_motivo);
end $$;

create or replace function public.painel_usuario_vincular(p_principal uuid, p_email text, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_uid uuid; v_motivo text;
begin
  v_eu := painel._entrar('usuario_vincular', p_principal::text);
  perform painel._exigir(v_eu, 'administrar');
  perform painel._alvo_humano(v_eu, p_principal);
  v_motivo := painel._texto(5, p_motivo, 'motivo');
  select id into v_uid from auth.users where lower(email) = lower(btrim(coalesce(p_email, '')));
  if v_uid is null then raise exception 'nenhum login com esse e-mail; crie o usuário no Supabase Auth primeiro' using errcode = '22023'; end if;
  if exists (select 1 from core.principais where auth_uid = v_uid and id <> p_principal) then
    raise exception 'esse login já está vinculado a outra pessoa' using errcode = '42501';
  end if;
  update core.principais set auth_uid = v_uid where id = p_principal;
  perform core.auditar(v_eu, null, 'usuario_vinculado', 'principal', p_principal::text, null,
    jsonb_build_object('canal', 'painel'), v_motivo);
end $$;

create or replace function public.painel_usuario_ativo(p_principal uuid, p_ativo boolean, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_motivo text; v_antes boolean;
begin
  v_eu := painel._entrar('usuario_ativo', p_principal::text);
  perform painel._exigir(v_eu, 'administrar');
  perform painel._alvo_humano(v_eu, p_principal);
  v_motivo := painel._texto(5, p_motivo, 'motivo');
  select ativo into v_antes from core.principais where id = p_principal for update;
  update core.principais set ativo = coalesce(p_ativo, false) where id = p_principal;
  perform core.auditar(v_eu, null, case when p_ativo then 'usuario_ativado' else 'usuario_desativado' end, 'principal',
    p_principal::text, jsonb_build_object('ativo', v_antes), jsonb_build_object('ativo', coalesce(p_ativo, false), 'canal', 'painel'), v_motivo);
end $$;

create or replace function public.painel_politica_definir(p_papel text, p_recurso text, p_operacao text, p_categoria text,
  p_risco text, p_unidade text, p_limite numeric, p_aprovadores int, p_papel_aprovador text, p_motivo text) returns bigint
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_motivo text; v_id bigint;
begin
  v_eu := painel._entrar('politica_definir', p_papel || ':' || p_recurso || '.' || p_operacao);
  perform painel._exigir(v_eu, 'administrar');
  v_motivo := painel._texto(5, p_motivo, 'motivo');
  -- trava de segurança: o acesso administrativo ao painel não é alterado pelo próprio painel
  if p_papel = 'admin' and p_recurso = 'painel' then
    raise exception 'políticas do admin no painel só mudam por migração revisada' using errcode = '42501';
  end if;
  v_id := core.politica_definir(v_eu, p_papel, p_recurso, p_operacao, p_categoria, p_risco, p_unidade, p_limite,
                                coalesce(p_aprovadores, 1), p_papel_aprovador);
  perform core.auditar(v_eu, null, 'politica_definida', 'politica', v_id::text, null,
    jsonb_build_object('papel', p_papel, 'recurso', p_recurso, 'operacao', p_operacao, 'categoria', p_categoria, 'canal', 'painel'), v_motivo);
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Grants: só authenticated executa painel_*; anon nunca; helpers fechados
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'painel' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', r.sig);
    end if;
  end loop;
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'painel\_%' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon', r.sig);
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
end $$;

update core.config set valor = '0.5.0' where chave = 'versao_painel';
