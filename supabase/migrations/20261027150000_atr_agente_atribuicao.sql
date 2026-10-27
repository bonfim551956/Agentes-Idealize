-- =============================================================================
-- Idealize AI — Agente de Atribuição (v0.1.0)  · Migração 20261027150000
--
-- Responde "quanto faturou cada campanha", de forma APROXIMADA e CONSERVADORA, só leitura:
--   lead da Kommo (loja pelo funil, data do 1º contato) → venda no ADM com o MESMO TELEFONE, na mesma loja,
--   em até N dias (60) → faturamento. Venda de cliente que já tinha comprado antes do lead conta separado (recorrente).
-- O telefone NUNCA é gravado: a função de leitura transforma em código irreversível (HMAC com segredo da plataforma)
-- dos dois lados; aqui só existe o código. Campanha: exata quando a Kommo traz a origem (id ou nome da campanha);
-- senão, estimada pela loja e pelo dia, dividindo pelo gasto de cada campanha naquele dia (agente de Marketing).
-- Nasce PAUSADO e com a sincronização DESLIGADA (atr.sync.ativo = false).
-- =============================================================================

create schema if not exists atr;
revoke all on schema atr from public;

create or replace function atr._hoje() returns date
language sql stable set search_path = pg_catalog as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create table atr.unidades_origem (            -- loja no ADM → unidade
  origem     text primary key,
  unidade_id text not null references core.unidades(id)
);
create index atr_unidades_origem_unidade on atr.unidades_origem (unidade_id);
insert into atr.unidades_origem (origem, unidade_id)
select v.o, v.u from (values ('campinas','campinas'), ('piracicaba','piracicaba'), ('saovicente','sao_vicente'), ('sorocaba','sorocaba')) v(o, u)
where exists (select 1 from core.unidades where id = v.u);

create table atr.leads (
  id               bigint primary key,           -- id do lead na Kommo
  funil_id         bigint,
  unidade_id       text references core.unidades(id),
  responsavel_id   bigint,                       -- atendente responsável na Kommo
  criado_em        timestamptz not null,
  tel_hash         text check (tel_hash ~ '^[0-9a-f]{64}$'),
  origem           text,                         -- etiquetas/UTM/origem da Kommo (sem dados pessoais)
  campanha_id      text,                         -- preenchido quando a origem identifica a campanha da Meta
  sincronizacao_id uuid
);
create index atr_leads_unidade_criado on atr.leads (unidade_id, criado_em);
create index atr_leads_hash on atr.leads (tel_hash);
create index atr_leads_responsavel on atr.leads (responsavel_id);

create table atr.vendas (
  id               text primary key,             -- id da OS no ADM
  unidade_id       text not null references core.unidades(id),
  dia              date not null,
  tipo             text,
  valor            numeric(14,2) not null default 0,
  tel_hash         text check (tel_hash ~ '^[0-9a-f]{64}$'),
  sincronizacao_id uuid
);
create index atr_vendas_hash_dia on atr.vendas (tel_hash, dia);
create index atr_vendas_unidade_dia on atr.vendas (unidade_id, dia);

create table atr.conversoes (                   -- recalculado: lead → primeira venda que casou
  lead_id    bigint primary key references atr.leads(id) on delete cascade,
  venda_id   text not null unique references atr.vendas(id) on delete cascade,
  unidade_id text not null,
  dia_lead   date not null,
  dia_venda  date not null,
  valor      numeric(14,2) not null,
  nova       boolean not null                   -- cliente sem compra anterior ao lead
);
create index atr_conversoes_unidade on atr.conversoes (unidade_id, dia_lead);

create table atr.sincronizacoes (
  id                 uuid primary key default gen_random_uuid(),
  tarefa_id          uuid references core.tarefas(id),
  leads              int not null,
  leads_com_telefone int not null,
  vendas             int not null,
  conversoes         int not null,
  ignoradas          int not null,
  hash_lote          text not null,
  em                 timestamptz not null default now()
);
create index atr_sincronizacoes_tarefa on atr.sincronizacoes (tarefa_id);
create index atr_sincronizacoes_em on atr.sincronizacoes (em desc);

insert into core.config (chave, valor) values
  ('atr.sync.ativo', 'false'),
  ('atr.janela_conversao_dias', '60'),      -- venda até N dias depois do 1º contato conta para o lead
  ('atr.leads_janela_dias', '120'),         -- quantos dias de leads a leitura traz da Kommo
  ('atr.tipos_venda', 'venda,hora,avulsa'), -- tipos de OS do ADM que contam como venda (garantia/cortesia/passagem não)
  ('versao_atr', '0.1.0')
on conflict (chave) do nothing;

insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('atribuicao', 'Agente de Atribuição', 'comercial', 'pausado', '0.1.0',
   'Cruza campanhas da Meta, leads da Kommo e vendas do sistema da loja pelo telefone (em código irreversível) e estima quanto cada loja e campanha faturou. Só leitura.')
on conflict (id) do nothing;
insert into core.papeis (id, nome) values ('agente_atribuicao', 'Agente de atribuição (máquina)') on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', 'Agente de Atribuição', 'atribuicao' where not exists (select 1 from core.principais where agente_id = 'atribuicao');
insert into core.principal_papeis (principal_id, papel_id)
select id, 'agente_atribuicao' from core.principais where agente_id = 'atribuicao' on conflict do nothing;
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_atribuicao', 'atr.cruzamento', 'sincronizar', 'baixo', 'automatica'
where not exists (select 1 from core.politicas where papel_id = 'agente_atribuicao' and recurso = 'atr.cruzamento' and operacao = 'sincronizar' and ativo);
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_atribuicao', 'atr.cruzamento', v.op, 'alto', 'proibida'
from (values ('guardar_telefone'), ('enviar_mensagem'), ('alterar_lead'), ('alterar_venda'), ('alterar_campanha'), ('excluir')) v(op)
where not exists (select 1 from core.politicas where papel_id = 'agente_atribuicao' and recurso = 'atr.cruzamento' and operacao = v.op and ativo);
insert into core.integracoes (id, nome, status, credencial_leitura, observacoes) values
  ('adm_vendas', 'Sistema ADM — vendas (OS)', 'nao_verificada', 'ADM_LEITURA_DB_URL',
   'Visão idealize_ai.vendas_atribuicao; telefone vira código HMAC (ATR_CHAVE_TELEFONE) na leitura e nunca é gravado.')
on conflict (id) do nothing;

create or replace function atr._cfg_int(p_chave text, p_padrao int) returns int
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(nullif(core.cfg(p_chave, p_padrao::text), '')::int, p_padrao)
$$;

-- ---------------------------------------------------------------------------
-- Casamento lead → venda (recalculado inteiro; conservador: uma venda só para um lead, o mais antigo)
-- ---------------------------------------------------------------------------
create or replace function atr.recalcular() returns int
language plpgsql security definer set search_path = atr, mkt, core, pg_catalog as $$
declare v_jan int := atr._cfg_int('atr.janela_conversao_dias', 60); n int;
begin
  -- campanha exata: a origem do lead cita o id ou o nome da campanha da Meta
  update atr.leads l set campanha_id = (
    select c.id from mkt.campanhas c join mkt.contas ct on ct.id = c.conta_id
    where l.origem is not null and (l.origem like '%' || c.id || '%' or (length(c.nome) >= 6 and lower(l.origem) like '%' || lower(c.nome) || '%'))
      and (ct.unidade_id is null or ct.unidade_id = l.unidade_id)
    order by length(c.nome) desc limit 1);

  delete from atr.conversoes;
  insert into atr.conversoes (lead_id, venda_id, unidade_id, dia_lead, dia_venda, valor, nova)
  select distinct on (x.venda_id) x.lead_id, x.venda_id, x.unidade_id, x.dia_lead, x.dia_venda, x.valor, x.nova
  from (
    select distinct on (l.id) l.id lead_id, v.id venda_id, l.unidade_id, (l.criado_em at time zone 'America/Sao_Paulo')::date dia_lead,
           v.dia dia_venda, v.valor,
           not exists (select 1 from atr.vendas a where a.tel_hash = l.tel_hash and a.dia < (l.criado_em at time zone 'America/Sao_Paulo')::date) nova
    from atr.leads l
    join atr.vendas v on v.tel_hash = l.tel_hash and v.unidade_id = l.unidade_id and v.valor > 0
     and v.dia between (l.criado_em at time zone 'America/Sao_Paulo')::date and (l.criado_em at time zone 'America/Sao_Paulo')::date + v_jan
    where l.tel_hash is not null and l.unidade_id is not null
    order by l.id, v.dia, v.id) x
  order by x.venda_id, x.dia_lead, x.lead_id;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Lote: {leads:[{id,funil_id,responsavel_id,criado_em(epoch s),tel_hash,origem}], vendas:[{id,unidade,dia,tipo,valor,tel_hash}]}
-- Leads: substitui os da janela lida; vendas: retrato completo do ADM.
-- ---------------------------------------------------------------------------
create or replace function atr.aplicar_lote(p_tarefa uuid, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = atr, com, core, pg_catalog as $$
declare v_s uuid := gen_random_uuid(); n_l int; n_lt int; n_v int; n_c int; n_ign int; v_min timestamptz;
  v_tipos text[] := string_to_array(core.cfg('atr.tipos_venda', 'venda,hora,avulsa'), ',');
begin
  if jsonb_typeof(p_lote) is distinct from 'object' or jsonb_typeof(p_lote->'leads') is distinct from 'array'
     or jsonb_typeof(p_lote->'vendas') is distinct from 'array' then
    raise exception 'lote sem leads ou vendas';
  end if;
  if jsonb_array_length(p_lote->'vendas') = 0 and exists (select 1 from atr.vendas) then
    raise exception 'lote veio sem vendas e o espelho tem vendas: leitura suspeita, nada foi apagado';
  end if;
  -- nenhum telefone em claro pode entrar: só códigos de 64 hexadecimais
  if exists (select 1 from jsonb_array_elements(p_lote->'leads') x where coalesce(x->>'tel_hash', '') !~ '^([0-9a-f]{64})?$')
     or exists (select 1 from jsonb_array_elements(p_lote->'vendas') x where coalesce(x->>'tel_hash', '') !~ '^([0-9a-f]{64})?$') then
    raise exception 'lote com telefone fora do formato de código: recusado';
  end if;

  select min(to_timestamp((x->>'criado_em')::bigint)) into v_min from jsonb_array_elements(p_lote->'leads') x where (x->>'criado_em') ~ '^[0-9]{9,11}$';
  if v_min is not null then delete from atr.leads where criado_em >= v_min; end if;

  insert into atr.leads (id, funil_id, unidade_id, responsavel_id, criado_em, tel_hash, origem, sincronizacao_id)
  select r.id, r.funil_id, (select f.unidade_id from com.funis f where f.id = r.funil_id), nullif(r.responsavel_id, 0), to_timestamp(r.criado_em),
         nullif(r.tel_hash, ''), left(nullif(btrim(r.origem), ''), 300), v_s
  from jsonb_to_recordset(p_lote->'leads') r(id bigint, funil_id bigint, responsavel_id bigint, criado_em bigint, tel_hash text, origem text)
  where r.id is not null and r.criado_em > 0
  on conflict (id) do update set funil_id = excluded.funil_id, unidade_id = excluded.unidade_id, responsavel_id = excluded.responsavel_id,
    criado_em = excluded.criado_em,
    tel_hash = excluded.tel_hash, origem = excluded.origem, sincronizacao_id = excluded.sincronizacao_id;
  get diagnostics n_l = row_count;
  select count(*) into n_lt from atr.leads where sincronizacao_id = v_s and tel_hash is not null;

  delete from atr.conversoes;
  delete from atr.vendas;
  insert into atr.vendas (id, unidade_id, dia, tipo, valor, tel_hash, sincronizacao_id)
  select r.id, o.unidade_id, r.dia, left(r.tipo, 30), round(coalesce(r.valor, 0), 2), nullif(r.tel_hash, ''), v_s
  from jsonb_to_recordset(p_lote->'vendas') r(id text, unidade text, dia date, tipo text, valor numeric, tel_hash text)
  join atr.unidades_origem o on o.origem = r.unidade
  where coalesce(r.id, '') <> '' and r.dia is not null and lower(coalesce(r.tipo, '')) = any(v_tipos)
  on conflict (id) do nothing;
  get diagnostics n_v = row_count;
  n_ign := jsonb_array_length(p_lote->'leads') - n_l + jsonb_array_length(p_lote->'vendas') - n_v;

  n_c := atr.recalcular();
  insert into atr.sincronizacoes (id, tarefa_id, leads, leads_com_telefone, vendas, conversoes, ignoradas, hash_lote)
  values (v_s, p_tarefa, n_l, n_lt, n_v, n_c, n_ign, md5(p_lote::text));
  return jsonb_build_object('sincronizacao', v_s, 'leads', n_l, 'leads_com_telefone', n_lt, 'vendas', n_v, 'conversoes', n_c,
    'ignoradas', n_ign, 'hash_lote', md5(p_lote::text));
end $$;

create or replace function atr.concluir_sincronizacao(p_tarefa uuid, p_executor text, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = atr, core, pg_catalog as $$
declare t record; v jsonb;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'atribuicao' or t.tipo is distinct from 'atr_sincronizacao' then raise exception 'tarefa não é sincronização da atribuição'; end if;
  v := atr.aplicar_lote(p_tarefa, p_lote);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', v->>'hash_lote', v);
  return v;
end $$;

create or replace function atr.validar_sincronizacao(p_tarefa uuid, p_validador text) returns text
language plpgsql security definer set search_path = atr, core, pg_catalog as $$
declare t record; s record; v_erros text[] := '{}'; n int; v_jan int := atr._cfg_int('atr.janela_conversao_dias', 60);
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  select * into s from atr.sincronizacoes where tarefa_id = p_tarefa order by em desc limit 1;
  if s.id is null then
    v_erros := v_erros || 'sincronização sem registro';
  else
    select count(*) into n from atr.vendas where sincronizacao_id = s.id;
    if n <> s.vendas then v_erros := v_erros || format('espelho tem %s vendas, registro diz %s', n, s.vendas); end if;
    -- toda conversão respeita as regras (mesmo código, mesma loja, dentro da janela, venda com valor)
    select count(*) into n from atr.conversoes c join atr.leads l on l.id = c.lead_id join atr.vendas v on v.id = c.venda_id
     where l.tel_hash is distinct from v.tel_hash or l.unidade_id is distinct from v.unidade_id or v.valor <= 0
        or v.dia < c.dia_lead or v.dia > c.dia_lead + v_jan or c.valor <> v.valor;
    if n > 0 then v_erros := v_erros || format('%s conversões fora das regras', n); end if;
    -- nenhum telefone em claro no espelho
    select count(*) into n from atr.leads where tel_hash !~ '^[0-9a-f]{64}$' or coalesce(origem, '') ~ '(^|[^0-9])[0-9]{10,13}([^0-9]|$)';
    if n > 0 then v_erros := v_erros || format('%s leads com possível telefone em claro', n); end if;
  end if;
  if array_length(v_erros, 1) is null then
    return core.registrar_validacao(p_tarefa, p_validador, true, null, jsonb_build_object('sincronizacao', s.id));
  end if;
  return core.registrar_validacao(p_tarefa, p_validador, false, array_to_string(v_erros, '; '),
    jsonb_build_object('sincronizacao', s.id, 'erros', to_jsonb(v_erros)));
end $$;

create or replace function atr.agendar_sincronizacao() returns uuid
language plpgsql security definer set search_path = atr, core, pg_catalog as $$
declare v_p uuid;
begin
  if core.cfg('atr.sync.ativo', 'false') <> 'true' then return null; end if;
  select id into v_p from core.principais where agente_id = 'atribuicao';
  return core.criar_tarefa(v_p, 'atribuicao', 'atr_sincronizacao', 'atr.cruzamento', 'sincronizar', null,
    jsonb_build_object('origem', 'kommo+adm'), 'atr:sync:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDD'), null, 6);
end $$;

create or replace function atr.janela() returns jsonb
language sql stable security definer set search_path = atr, core, pg_catalog as $$
  select jsonb_build_object('leads_desde', floor(extract(epoch from (atr._hoje() - atr._cfg_int('atr.leads_janela_dias', 120))::timestamptz))::bigint,
                            'ate', floor(extract(epoch from now()))::bigint)
$$;

-- ---------------------------------------------------------------------------
-- Painel: por loja e por campanha (campanha: exata quando a origem identifica; senão rateio pelo gasto do dia)
-- ---------------------------------------------------------------------------
create or replace function public.painel_atribuicao(p_unidade text default null, p_dias int default 30) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[]; d date := atr._hoje(); n int := least(greatest(coalesce(p_dias, 30), 7), 120); v_ini date;
  v_jan int := atr._cfg_int('atr.janela_conversao_dias', 60);
begin
  v_eu := painel._entrar('atribuicao', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; end if;
  v_ini := d - (n - 1);

  drop table if exists _gasto;
  create temp table _gasto on commit drop as
    select ct.unidade_id, m.dia, m.campanha_id, sum(m.gasto) gasto, sum(m.conversas + m.leads) resultados_meta
    from mkt.metricas m join mkt.contas ct on ct.id = m.conta_id join mkt.campanhas c on c.id = m.campanha_id
    where m.dia between v_ini and d and not c.recrutamento and ct.unidade_id = any(un)
    group by ct.unidade_id, m.dia, m.campanha_id;
  drop table if exists _ld;
  create temp table _ld on commit drop as
    select l.id, l.unidade_id, l.responsavel_id, (l.criado_em at time zone 'America/Sao_Paulo')::date dia, l.campanha_id, l.tel_hash is not null com_tel,
           c.valor, c.nova, c.venda_id is not null convertido
    from atr.leads l left join atr.conversoes c on c.lead_id = l.id
    where (l.criado_em at time zone 'America/Sao_Paulo')::date between v_ini and d and l.unidade_id = any(un);

  return jsonb_build_object(
    'desde', v_ini, 'ate', d, 'janela_conversao_dias', v_jan,
    'janela_aberta_desde', greatest(v_ini, d - v_jan),
    'sincronizacao', jsonb_build_object('ativa', core.cfg('atr.sync.ativo', 'false') = 'true',
       'agente', (select status from core.agentes where id = 'atribuicao'),
       'ultima', (select jsonb_build_object('em', em, 'leads', leads, 'leads_com_telefone', leads_com_telefone, 'vendas', vendas, 'conversoes', conversoes)
                  from atr.sincronizacoes order by em desc limit 1)),
    'lojas', (select coalesce(jsonb_agg(x order by x->>'unidade_id'), '[]'::jsonb) from (
      select jsonb_build_object('unidade_id', u.unidade_id,
        'investido', coalesce((select sum(gasto) from _gasto g where g.unidade_id = u.unidade_id), 0),
        'resultados_meta', coalesce((select sum(resultados_meta) from _gasto g where g.unidade_id = u.unidade_id), 0),
        'leads', (select count(*) from _ld l where l.unidade_id = u.unidade_id),
        'leads_com_telefone', (select count(*) from _ld l where l.unidade_id = u.unidade_id and l.com_tel),
        'compraram', (select count(*) from _ld l where l.unidade_id = u.unidade_id and l.convertido),
        'compraram_novos', (select count(*) from _ld l where l.unidade_id = u.unidade_id and l.convertido and l.nova),
        'faturamento', coalesce((select sum(valor) from _ld l where l.unidade_id = u.unidade_id and l.convertido), 0),
        'faturamento_novos', coalesce((select sum(valor) from _ld l where l.unidade_id = u.unidade_id and l.convertido and l.nova), 0)) x
      from (select distinct unidade_id from _gasto union select distinct unidade_id from _ld) u where u.unidade_id is not null) q),
    -- por atendente responsável na Kommo
    'atendentes', (select coalesce(jsonb_agg(x order by (x->>'faturamento')::numeric desc, (x->>'leads')::int desc), '[]'::jsonb) from (
      select jsonb_build_object('responsavel_id', l.responsavel_id,
        'nome', coalesce((select nome from com.usuarios u where u.id = l.responsavel_id), case when l.responsavel_id is null then null else 'Atendente ' || l.responsavel_id end),
        'unidades', (select jsonb_agg(distinct l2.unidade_id) from _ld l2 where l2.responsavel_id is not distinct from l.responsavel_id),
        'leads', count(*), 'compraram', count(*) filter (where l.convertido), 'compraram_novos', count(*) filter (where l.convertido and l.nova),
        'faturamento', coalesce(sum(l.valor) filter (where l.convertido), 0),
        'faturamento_novos', coalesce(sum(l.valor) filter (where l.convertido and l.nova), 0)) x
      from _ld l group by l.responsavel_id) q),
    -- por campanha: leads exatos + rateio dos leads sem origem pelo gasto da campanha no dia/loja
    'campanhas', (select coalesce(jsonb_agg(x order by (x->>'investido')::numeric desc), '[]'::jsonb) from (
      select jsonb_build_object('campanha_id', g.campanha_id, 'nome', (select nome from mkt.campanhas where id = g.campanha_id),
        'unidade_id', min(g.unidade_id), 'investido', sum(g.gasto),
        'leads', round(sum(coalesce(r.leads, 0))::numeric, 1), 'compraram', round(sum(coalesce(r.compraram, 0))::numeric, 1),
        'faturamento', round(sum(coalesce(r.faturamento, 0))::numeric, 2), 'faturamento_novos', round(sum(coalesce(r.faturamento_novos, 0))::numeric, 2),
        'exatos', sum(coalesce(r.exatos, 0))) x
      from _gasto g
      cross join lateral (select sum(g2.gasto) total from _gasto g2 where g2.unidade_id = g.unidade_id and g2.dia = g.dia) t
      left join lateral (
        select
          -- parcela estimada (leads sem campanha identificada, divididos pelo gasto do dia)
          coalesce(sum(case when l.campanha_id is null then 1 else 0 end), 0) * g.gasto / nullif(t.total, 0)
            + count(*) filter (where l.campanha_id = g.campanha_id) as leads,
          coalesce(sum(case when l.campanha_id is null and l.convertido then 1 else 0 end), 0) * g.gasto / nullif(t.total, 0)
            + count(*) filter (where l.campanha_id = g.campanha_id and l.convertido) as compraram,
          coalesce(sum(case when l.campanha_id is null and l.convertido then l.valor else 0 end), 0) * g.gasto / nullif(t.total, 0)
            + coalesce(sum(l.valor) filter (where l.campanha_id = g.campanha_id and l.convertido), 0) as faturamento,
          coalesce(sum(case when l.campanha_id is null and l.convertido and l.nova then l.valor else 0 end), 0) * g.gasto / nullif(t.total, 0)
            + coalesce(sum(l.valor) filter (where l.campanha_id = g.campanha_id and l.convertido and l.nova), 0) as faturamento_novos,
          count(*) filter (where l.campanha_id = g.campanha_id) as exatos
        from _ld l
        where l.unidade_id = g.unidade_id and l.dia = g.dia) r on true
      group by g.campanha_id having sum(g.gasto) > 0) q));
end $$;

do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'atr' loop
    execute format('alter table atr.%I enable row level security', r.tablename);
    execute format('alter table atr.%I force row level security', r.tablename);
    execute format('revoke all on atr.%I from public', r.tablename);
  end loop;
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'atr' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', r.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema atr from anon, authenticated';
    execute 'revoke all on function public.painel_atribuicao(text, int) from public, anon';
    execute 'grant execute on function public.painel_atribuicao(text, int) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema atr to service_role';
    execute 'grant select on all tables in schema atr to service_role';
    execute 'grant execute on function public.painel_atribuicao(text, int) to service_role';
  end if;
end $$;
