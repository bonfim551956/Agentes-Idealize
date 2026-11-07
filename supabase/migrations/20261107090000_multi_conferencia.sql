-- =============================================================================
-- Idealize AI — Conferência do Multicrediário × ADM (São Vicente)  · Migração 20261107090000
-- Pedido do Diego (07/11, PODE FAZER). O robô lê o Multicrediário às 7h; às 7h40 a função multi-sync copia do ADM
-- (só leitura, visão sem dados pessoais: o CPF chega só como código) os carnês Multicrédito e as parcelas, e
-- multi.conferir() cruza:
--   • venda aprovada no Multicrediário × crediário no ADM (mesmo cliente, valor financiado, data, OS);
--   • crediário Multicrédito no ADM sem venda no Multicrediário;
--   • parcela recebida no Multicrediário × baixa no ADM;
--   • documentos obrigatórios da venda (Foto/Documentos, cliente por cliente).
-- O que não bate vira aviso em multi.achados (fecha sozinho quando deixa de existir; o Diego marca como resolvido).
-- Só São Vicente por decisão do Diego (07/11): as outras lojas ficam de fora até ele pedir.
-- =============================================================================
alter table multi.capturas drop constraint if exists capturas_relatorio_check;
alter table multi.capturas add constraint capturas_relatorio_check
  check (relatorio in ('operacao','operacao_detalhe','recebimentos','recebimentos_detalhe','garantia','documentos'));

insert into core.config (chave, valor) values
  ('multi.unidades_adm', 'saovicente'),       -- unidades do ADM conferidas (São Vicente por enquanto)
  ('multi.tolerancia', '0.01')                -- diferença de valor tolerada (R$); até R$ 1 vira "centavos"
on conflict (chave) do nothing;

-- cópia do ADM (só o necessário, sem nome nem CPF)
create table multi.adm_vendas (
  crediario_id    text primary key,
  unidade         text,
  os              text,
  os_fake         boolean not null default false,
  dt_compra       date,
  valor_compra    numeric(12,2),
  valor_crediario numeric(12,2),
  valor_entrada   numeric(12,2),
  num_parcelas    int,
  status          text,
  cpf_hash        text,
  atualizado_em   timestamptz not null default now()
);
create index multi_adm_vendas_cpf on multi.adm_vendas (cpf_hash, dt_compra);
create table multi.adm_parcelas (
  id             text primary key,
  crediario_id   text not null,
  numero         int,
  valor          numeric(12,2),
  dt_vencimento  date,
  dt_pagamento   date,
  status         text
);
create index multi_adm_parcelas_cred on multi.adm_parcelas (crediario_id, numero);

create table multi.achados (
  id           bigserial primary key,
  tipo         text not null check (tipo in ('valor_diferente','valor_com_entrada','centavos','venda_sem_adm','adm_sem_venda',
                                             'sem_os','data_diferente','parcela_sem_baixa','parcela_sem_carne','documento_pendente')),
  chave        text not null,
  dia          date,
  descricao    text not null,
  detalhe      jsonb not null default '{}',
  status       text not null default 'aberto' check (status in ('aberto','resolvido')),
  aberto_em    timestamptz not null default now(),
  resolvido_em timestamptz,
  resolvido_por text,
  nota         text
);
create unique index multi_achados_aberto on multi.achados (tipo, chave) where status = 'aberto';
create index multi_achados_dia on multi.achados (dia desc);

alter table multi.adm_vendas enable row level security; alter table multi.adm_vendas force row level security;
alter table multi.adm_parcelas enable row level security; alter table multi.adm_parcelas force row level security;
alter table multi.achados enable row level security; alter table multi.achados force row level security;
do $$ begin
  revoke all on all tables in schema multi from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on all tables in schema multi from anon, authenticated'; end if;
end $$;

-- ---------------------------------------------------------------------------
-- Leitura das telas capturadas (pelo nome da coluna, não pela posição)
-- ---------------------------------------------------------------------------
create or replace function multi._col(p_cab jsonb, p_nome text) returns int
language sql immutable set search_path = pg_catalog as $$
  select (i - 1)::int from jsonb_array_elements_text(p_cab) with ordinality e(h, i) where h = p_nome order by i limit 1
$$;
create or replace function multi._num(p text) returns numeric
language sql immutable set search_path = pg_catalog as $$
  select case when btrim(coalesce(p, '')) ~ '^-?[\d.]+(,\d+)?$' then replace(replace(btrim(p), '.', ''), ',', '.')::numeric end
$$;
create or replace function multi._data(p text) returns date
language sql immutable set search_path = pg_catalog as $$
  select case when p ~ '^\d{2}/\d{2}/\d{4}' then to_date(left(p, 10), 'DD/MM/YYYY') end
$$;
create or replace function multi._brl(p numeric) returns text
language sql immutable set search_path = pg_catalog as $$ select translate(to_char(coalesce(p, 0), 'FM999,999,990.00'), ',.', '.,') $$;
create or replace function multi._hash(p text) returns text
language sql immutable set search_path = extensions, pg_catalog as $$
  select encode(extensions.digest('idealize-multi:' || regexp_replace(coalesce(p, ''), '\D', '', 'g'), 'sha256'), 'hex')
$$;

-- vendas do relatório Operação (detalhe do dia): tipo 1 = aprovada (garantida), 2 = negada, 3 = ressarcimento, 4 = cancelada
create or replace view multi.v_operacoes as
select c.loja, c.dia, split_part(split_part(c.referencia, '&', 1), '=', 2)::int tipo,
       l->>k.venda venda, multi._hash(l->>k.cpf) cpf_hash, right(regexp_replace(l->>k.cpf, '\D', '', 'g'), 3) cpf_fim,
       l->>k.plano plano, multi._num(l->>k.vv) valor_venda, multi._num(l->>k.ent) entrada, multi._num(l->>k.tot) total,
       multi._num(l->>k.gar) garantido, l->>k.resp resposta
  from multi.capturas c
  cross join lateral (select multi._col(c.cabecalho, 'Nº Venda') venda, multi._col(c.cabecalho, 'CPF') cpf,
       multi._col(c.cabecalho, 'Plano') plano, multi._col(c.cabecalho, 'Valor Venda') vv, multi._col(c.cabecalho, 'Valor Entrada') ent,
       multi._col(c.cabecalho, 'Valor Total Venda') tot, multi._col(c.cabecalho, 'Consultado Garantido') gar,
       coalesce(multi._col(c.cabecalho, 'Resposta'), multi._col(c.cabecalho, 'Autorização / Resposta')) resp) k
  cross join lateral jsonb_array_elements(c.linhas) l
 where c.relatorio = 'operacao_detalhe' and c.referencia like 'Tipo=%' and k.cpf is not null;

-- parcelas recebidas (detalhe de Recebimentos que tem "Valor Recebido")
create or replace view multi.v_recebidas as
select c.loja, multi._data(l->>k.dt) dia, l->>k.venda venda, multi._hash(l->>k.cpf) cpf_hash,
       right(regexp_replace(l->>k.cpf, '\D', '', 'g'), 3) cpf_fim, nullif(regexp_replace(l->>k.parc, '\D', '', 'g'), '')::int parcela,
       multi._num(l->>k.rec) valor
  from multi.capturas c
  cross join lateral (select multi._col(c.cabecalho, 'Data Recebimento') dt, multi._col(c.cabecalho, 'Nº Venda') venda,
       multi._col(c.cabecalho, 'CPF') cpf, multi._col(c.cabecalho, 'Parcela') parc, multi._col(c.cabecalho, 'Valor Recebido') rec) k
  cross join lateral jsonb_array_elements(c.linhas) l
 where c.relatorio = 'recebimentos_detalhe' and k.rec is not null and k.cpf is not null;

-- documentos obrigatórios por venda (captura 'documentos', referência '<cpf>|<venda>')
create or replace view multi.v_documentos as
select c.loja, c.dia, split_part(c.referencia, '|', 2) venda, multi._hash(split_part(c.referencia, '|', 1)) cpf_hash,
       l->>k.tipo documento, upper(l->>k.obr) = 'SIM' obrigatorio, nullif(regexp_replace(l->>k.qtd, '\D', '', 'g'), '')::int quantidade,
       upper(l->>k.sit) situacao, c.capturado_em
  from multi.capturas c
  cross join lateral (select multi._col(c.cabecalho, 'Tipo de Documento') tipo, multi._col(c.cabecalho, 'Obrigatório') obr,
       multi._col(c.cabecalho, 'Quantidade') qtd, multi._col(c.cabecalho, 'Situação') sit) k
  cross join lateral jsonb_array_elements(c.linhas) l
 where c.relatorio = 'documentos' and k.tipo is not null;

-- cada venda aprovada × ADM
create or replace view multi.v_conferencia as
with tol as (select coalesce(nullif(core.cfg('multi.tolerancia', '0.01'), '')::numeric, 0.01) t)
select o.dia, o.venda, o.cpf_fim, o.plano, o.valor_venda, o.entrada, o.total, o.garantido,
       a.ids, a.os, a.valor_adm, a.dt_adm, a.sem_os,
       case when a.ids is null then 'venda_sem_adm'
            when abs(a.valor_adm - o.garantido) <= (select t from tol) then 'ok'
            when o.entrada > 0 and abs(a.valor_adm - o.total) <= (select t from tol) then 'valor_com_entrada'
            when abs(a.valor_adm - o.garantido) <= 1 then 'centavos'
            else 'valor_diferente' end situacao
  from multi.v_operacoes o
  left join lateral (
    select array_agg(v.crediario_id order by v.dt_compra) ids, string_agg(coalesce(v.os, '(sem OS)'), ' + ' order by v.dt_compra) os,
           sum(v.valor_crediario) valor_adm, min(v.dt_compra) dt_adm, bool_or(v.os is null or btrim(v.os) = '' or v.os_fake) sem_os
      from multi.adm_vendas v
     where v.cpf_hash = o.cpf_hash and v.unidade = any(string_to_array(regexp_replace(core.cfg('multi.unidades_adm', 'saovicente'), '\s', '', 'g'), ',')) and coalesce(v.status, '') <> 'cancelado'
       and v.dt_compra between o.dia - 3 and o.dia + 7) a on true
 where o.tipo = 1;

-- ---------------------------------------------------------------------------
-- Conferência (gera e fecha os avisos)
-- ---------------------------------------------------------------------------
create or replace function multi.conferir() returns jsonb
language plpgsql security definer set search_path = multi, core, pg_catalog as $$
declare n_ab int; n_res int; v_un text[] := string_to_array(regexp_replace(core.cfg('multi.unidades_adm', 'saovicente'), '\s', '', 'g'), ',');
  v_ini date; v_fim date;
begin
  -- período já lido pelo robô: do 1º dia com venda até a véspera da última leitura do relatório Operação
  select min(dia) into v_ini from multi.capturas where relatorio = 'operacao_detalhe';
  select max(capturado_em)::date - 1 into v_fim from multi.capturas where relatorio = 'operacao';
  drop table if exists _dev;
  create temp table _dev (tipo text, chave text, dia date, descricao text, detalhe jsonb) on commit drop;

  insert into _dev
  select case when situacao = 'ok' then null else situacao end, 'venda:' || venda, dia,
    case situacao
      when 'venda_sem_adm' then format('Venda %s aprovada no Multicrediário (R$ %s financiado) sem crediário Multicrédito no ADM', venda, multi._brl(garantido))
      when 'valor_com_entrada' then format('OS %s: o ADM tem R$ %s, mas o financiado é R$ %s (o ADM somou a entrada de R$ %s)', os, multi._brl(valor_adm), multi._brl(garantido), multi._brl(entrada))
      when 'centavos' then format('OS %s: diferença de centavos (ADM R$ %s × Multicrediário R$ %s)', os, multi._brl(valor_adm), multi._brl(garantido))
      else format('OS %s: valor diferente (ADM R$ %s × Multicrediário R$ %s)', os, multi._brl(valor_adm), multi._brl(garantido)) end,
    jsonb_build_object('venda', venda, 'os', os, 'adm', valor_adm, 'multi', garantido, 'total', total, 'entrada', entrada, 'cpf_fim', cpf_fim)
  from multi.v_conferencia where situacao <> 'ok';
  delete from _dev where tipo is null;

  insert into _dev
  select 'sem_os', 'venda:' || venda, dia, format('Venda %s (R$ %s) está no ADM sem número de OS', venda, multi._brl(garantido)),
    jsonb_build_object('venda', venda, 'multi', garantido)
  from multi.v_conferencia where ids is not null and sem_os;

  insert into _dev
  select 'data_diferente', 'venda:' || venda, dia, format('OS %s: venda em %s no Multicrediário, lançada no ADM em %s', os, to_char(dia, 'DD/MM'), to_char(dt_adm, 'DD/MM')),
    jsonb_build_object('venda', venda, 'os', os, 'dia_multi', dia, 'dia_adm', dt_adm)
  from multi.v_conferencia where ids is not null and dt_adm <> dia;

  -- crediário Multicrédito no ADM sem venda aprovada no Multicrediário (só no período já lido pelo robô)
  if v_ini is not null then
    insert into _dev
    select 'adm_sem_venda', 'adm:' || a.crediario_id, a.dt_compra,
      format('OS %s: crediário Multicrédito de R$ %s no ADM sem venda aprovada no Multicrediário', coalesce(a.os, '(sem OS)'), multi._brl(a.valor_crediario)),
      jsonb_build_object('os', a.os, 'adm', a.valor_crediario)
    from multi.adm_vendas a
    where a.unidade = any(v_un) and coalesce(a.status, '') <> 'cancelado' and a.dt_compra between v_ini and v_fim
      and not exists (select 1 from multi.v_operacoes o where o.tipo = 1 and o.cpf_hash = a.cpf_hash and o.dia between a.dt_compra - 7 and a.dt_compra + 3);
  end if;

  -- parcela recebida no Multicrediário × baixa no ADM
  insert into _dev
  select case when c.ids is null then 'parcela_sem_carne' else 'parcela_sem_baixa' end, 'parcela:' || r.venda || ':' || r.parcela, r.dia,
    case when c.ids is null then format('Parcela %s da venda %s (R$ %s) recebida no Multicrediário em %s, mas o carnê não está no ADM', r.parcela, r.venda, multi._brl(r.valor), to_char(r.dia, 'DD/MM'))
         else format('Parcela %s da OS %s (R$ %s) recebida no Multicrediário em %s e sem baixa no ADM', r.parcela, c.os, multi._brl(r.valor), to_char(r.dia, 'DD/MM')) end,
    jsonb_build_object('venda', r.venda, 'parcela', r.parcela, 'valor', r.valor, 'os', c.os)
  from multi.v_recebidas r
  left join lateral (select array_agg(v.crediario_id) ids, string_agg(coalesce(v.os, '(sem OS)'), ' + ') os from multi.adm_vendas v
                      where v.cpf_hash = r.cpf_hash and v.unidade = any(v_un)) c on true
  where r.dia is not null and r.dia <= current_date
    and not exists (select 1 from multi.adm_parcelas p where p.crediario_id = any(coalesce(c.ids, '{}')) and p.numero = r.parcela and p.dt_pagamento is not null);

  -- documento obrigatório faltando ou não aprovado (a partir do dia seguinte à venda)
  insert into _dev
  select 'documento_pendente', 'doc:' || d.venda || ':' || d.documento, d.dia,
    format('Venda %s: documento obrigatório "%s" %s', d.venda, d.documento, case when coalesce(d.quantidade, 0) = 0 then 'não foi enviado' else 'ainda não foi aprovado (' || lower(d.situacao) || ')' end),
    jsonb_build_object('venda', d.venda, 'documento', d.documento, 'quantidade', d.quantidade, 'situacao', d.situacao)
  from multi.v_documentos d
  where d.obrigatorio and (coalesce(d.quantidade, 0) = 0 or d.situacao <> 'POSITIVADO') and d.dia < current_date;

  insert into multi.achados (tipo, chave, dia, descricao, detalhe)
  select distinct on (tipo, chave) tipo, chave, dia, descricao, detalhe from _dev
  on conflict (tipo, chave) where status = 'aberto' do update set descricao = excluded.descricao, detalhe = excluded.detalhe, dia = excluded.dia;
  get diagnostics n_ab = row_count;
  update multi.achados a set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente: situação deixou de existir'
   where a.status = 'aberto' and not exists (select 1 from _dev d where d.tipo = a.tipo and d.chave = a.chave);
  get diagnostics n_res = row_count;
  return jsonb_build_object('avisos', n_ab, 'fechados', n_res,
    'vendas', (select count(*) from multi.v_conferencia), 'vendas_ok', (select count(*) from multi.v_conferencia where situacao = 'ok'));
end $$;

-- recebe a cópia do ADM (chamado pela função multi-sync) e já confere
create or replace function multi.receber_adm(p_vendas jsonb, p_parcelas jsonb) returns jsonb
language plpgsql security definer set search_path = multi, pg_catalog as $$
declare v jsonb;
begin
  insert into multi.adm_vendas (crediario_id, unidade, os, os_fake, dt_compra, valor_compra, valor_crediario, valor_entrada, num_parcelas, status, cpf_hash)
  select x->>'crediario_id', x->>'unidade', x->>'os', coalesce((x->>'os_fake')::boolean, false), (x->>'dt_compra')::date,
         (x->>'valor_compra')::numeric, (x->>'valor_crediario')::numeric, (x->>'valor_entrada')::numeric, (x->>'num_parcelas')::int, x->>'status', x->>'cpf_hash'
    from jsonb_array_elements(coalesce(p_vendas, '[]')) x
  on conflict (crediario_id) do update set unidade = excluded.unidade, os = excluded.os, os_fake = excluded.os_fake, dt_compra = excluded.dt_compra,
    valor_compra = excluded.valor_compra, valor_crediario = excluded.valor_crediario, valor_entrada = excluded.valor_entrada,
    num_parcelas = excluded.num_parcelas, status = excluded.status, cpf_hash = excluded.cpf_hash, atualizado_em = now();
  insert into multi.adm_parcelas (id, crediario_id, numero, valor, dt_vencimento, dt_pagamento, status)
  select x->>'id', x->>'crediario_id', (x->>'numero')::int, (x->>'valor')::numeric, (x->>'dt_vencimento')::date, (x->>'dt_pagamento')::date, x->>'status'
    from jsonb_array_elements(coalesce(p_parcelas, '[]')) x
  on conflict (id) do update set numero = excluded.numero, valor = excluded.valor, dt_vencimento = excluded.dt_vencimento,
    dt_pagamento = excluded.dt_pagamento, status = excluded.status;
  v := multi.conferir() || jsonb_build_object('adm_vendas', jsonb_array_length(coalesce(p_vendas, '[]')), 'adm_parcelas', jsonb_array_length(coalesce(p_parcelas, '[]')));
  insert into intel.sincronizacoes (agente_id, resumo) values ('multicrediario', v);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Painel
-- ---------------------------------------------------------------------------
create or replace function public.painel_multi(p_dia date default null) returns jsonb
language plpgsql security definer set search_path = multi, core, pg_catalog as $$
declare v_eu uuid; d date;
begin
  v_eu := painel._entrar('multicrediario', coalesce(p_dia::text, ''));
  if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão' using errcode = '42501'; end if;
  d := coalesce(p_dia, (select max(dia) from multi.capturas where relatorio = 'operacao_detalhe' and dia <= current_date), current_date - 1);
  return jsonb_build_object(
    'dia', d, 'pode_editar', painel._pode(v_eu, 'administrar'),
    'ultima_leitura', (select max(capturado_em) from multi.capturas),
    'ultima_conferencia', (select max(em) from intel.sincronizacoes where agente_id = 'multicrediario' and resumo ? 'avisos'),
    'dias', (select coalesce(jsonb_agg(x order by x desc), '[]'::jsonb) from (select distinct dia x from multi.capturas where relatorio = 'operacao_detalhe' and dia is not null order by 1 desc limit 60) q),
    'resumo', jsonb_build_object(
      'aprovadas', (select count(*) from multi.v_operacoes where tipo = 1 and dia = d),
      'aprovado_valor', (select coalesce(sum(garantido), 0) from multi.v_operacoes where tipo = 1 and dia = d),
      'negadas', (select count(*) from multi.v_operacoes where tipo = 2 and dia = d),
      'canceladas', (select count(*) from multi.v_operacoes where tipo = 4 and dia = d),
      'parcelas', (select count(*) from multi.v_recebidas where dia = d),
      'parcelas_valor', (select coalesce(sum(valor), 0) from multi.v_recebidas where dia = d),
      'abertos', (select count(*) from multi.achados where status = 'aberto')),
    'abertos', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'dia', dia, 'descricao', descricao, 'aberto_em', aberto_em) order by dia desc nulls last, id), '[]'::jsonb)
      from multi.achados where status = 'aberto'),
    'vendas', (select coalesce(jsonb_agg(jsonb_build_object('venda', venda, 'os', os, 'plano', plano, 'garantido', garantido, 'adm', valor_adm, 'situacao', situacao) order by venda), '[]'::jsonb)
      from multi.v_conferencia where dia = d),
    'negadas', (select coalesce(jsonb_agg(jsonb_build_object('venda', venda, 'tipo', tipo, 'valor', coalesce(total, valor_venda), 'resposta', resposta) order by tipo, venda), '[]'::jsonb)
      from multi.v_operacoes where dia = d and tipo in (2, 4)),
    'recebidas', (select coalesce(jsonb_agg(jsonb_build_object('venda', venda, 'parcela', parcela, 'valor', valor) order by venda), '[]'::jsonb)
      from multi.v_recebidas where dia = d),
    'resolvidos', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'dia', dia, 'descricao', descricao, 'resolvido_em', resolvido_em, 'resolvido_por', resolvido_por, 'nota', nota) order by resolvido_em desc), '[]'::jsonb)
      from (select * from multi.achados where status = 'resolvido' order by resolvido_em desc limit 30) q));
end $$;

create or replace function public.painel_multi_resolver(p_id bigint, p_nota text) returns void
language plpgsql security definer set search_path = multi, core, pg_catalog as $$
declare v_eu uuid; a record;
begin
  v_eu := painel._entrar('multi_resolver', p_id::text);
  perform painel._exigir(v_eu, 'administrar');
  if length(btrim(coalesce(p_nota, ''))) < 5 then raise exception 'escreva o que foi feito (pelo menos 5 letras)' using errcode = '22023'; end if;
  select * into a from multi.achados where id = p_id and status = 'aberto' for update;
  if a.id is null then raise exception 'aviso inexistente ou já resolvido' using errcode = '22023'; end if;
  update multi.achados set status = 'resolvido', resolvido_em = now(), resolvido_por = 'painel', nota = btrim(p_nota) where id = p_id;
  perform core.auditar(v_eu, null, 'multi_aviso_resolvido', 'multi.achado', p_id::text, jsonb_build_object('status', 'aberto'),
    jsonb_build_object('status', 'resolvido'), btrim(p_nota));
end $$;

do $$ declare f text; begin
  foreach f in array array['multi._col(jsonb,text)', 'multi._num(text)', 'multi._data(text)', 'multi._hash(text)', 'multi._brl(numeric)', 'multi.conferir()',
    'multi.receber_adm(jsonb,jsonb)', 'public.painel_multi(date)', 'public.painel_multi_resolver(bigint,text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', f); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.painel_multi(date) to authenticated';
    execute 'grant execute on function public.painel_multi_resolver(bigint,text) to authenticated';
  end if;
end $$;

-- conferência às 7h40 (Brasília), depois do robô das 7h; usa o segredo do worker de cobranças (mesmo domínio: crediário)
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'multi-sync';
    perform cron.schedule('multi-sync', '40 10 * * *', $c$select core.chamar_agente('multi-sync','cob_worker_secret',300000)$c$);
  end if;
end $$;
