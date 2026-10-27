-- =============================================================================
-- Idealize AI — Agente de Caixa (v0.1.0)  · Migração 20261027120000
--
-- Primeira versão = CONFERÊNCIA, só leitura. Para cada loja e dia, pega cada valor registrado no fechamento de caixa
-- do Sistema ADM (por forma de pagamento) e procura o dinheiro no extrato:
--   Pix  → extrato do banco da loja (fin.movimentos, importado pelo agente financeiro);
--   Asaas / Link Asaas → API do Asaas (uma conta por loja);
--   Crédito / Débito → arquivo da Stone (importação; formato a confirmar com arquivo real).
-- Casa valor a valor (com folga de dias para o lançamento cair) e também dois valores do caixa contra um só crédito
-- (cliente que pagou dois itens num Pix só). O que sobra vira alerta. Também alerta: caixa não fechado, total do
-- caixa diferente da soma das formas, dinheiro sem depósito e extrato atrasado.
-- Não baixa parcela, não estorna, não transfere e não altera o fechamento (políticas proibidas).
-- Nasce PAUSADO e com a sincronização DESLIGADA (cx.sync.ativo = false).
-- =============================================================================

create schema if not exists cx;
revoke all on schema cx from public;

create or replace function cx._hoje() returns date
language sql stable set search_path = pg_catalog as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create or replace function cx._simples(s text) returns text
language sql immutable set search_path = pg_catalog as $$
  select lower(btrim(translate(coalesce(s, ''), 'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇç', 'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCc')))
$$;

-- Forma de pagamento do ADM → forma canônica
create or replace function cx._forma(s text) returns text
language sql immutable set search_path = cx, pg_catalog as $$
  select case
    when x in ('pix') then 'pix'
    when x in ('credito', 'cartao de credito') then 'credito'
    when x in ('debito', 'cartao de debito') then 'debito'
    when x in ('dinheiro', 'especie') then 'dinheiro'
    when x in ('asaas', 'link asaas') then 'asaas'
    when x in ('multicrediario', 'crediario') then 'crediario'
    when x in ('brasilcard') then 'brasilcard'
    when x in ('', 'garantia', 'sem saldo', 'sem valor a receber') then 'nao_financeiro'
    else 'outro' end
  from (select cx._simples(s) x) q
$$;

-- ---------------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------------
create table cx.unidades_origem (            -- nome da loja no ADM → unidade
  origem     text primary key,
  unidade_id text not null references core.unidades(id)
);
create index cx_unidades_origem_unidade on cx.unidades_origem (unidade_id);
insert into cx.unidades_origem (origem, unidade_id)
select v.o, v.u from (values ('campinas','campinas'), ('piracicaba','piracicaba'), ('saovicente','sao_vicente'), ('sorocaba','sorocaba')) v(o, u)
where exists (select 1 from core.unidades where id = v.u);

-- De onde vem o extrato de cada forma (configurável)
create table cx.fontes_forma (
  forma  text primary key,
  fonte  text not null check (fonte in ('banco','asaas','stone','deposito','nenhuma')),
  rotulo text not null
);
insert into cx.fontes_forma values
  ('pix','banco','Pix'), ('asaas','asaas','Asaas'), ('credito','stone','Crédito'), ('debito','stone','Débito'),
  ('dinheiro','deposito','Dinheiro'), ('crediario','nenhuma','Multicrediário'), ('brasilcard','nenhuma','Brasilcard'),
  ('outro','nenhuma','Outro');

create table cx.dias (                        -- fechamento de cada loja/dia como está no ADM
  unidade_id      text not null references core.unidades(id),
  dia             date not null,
  status_adm      text,
  caixa           numeric(14,2),
  soma_formas     numeric(14,2) not null default 0,
  dinheiro_gaveta numeric(14,2),
  deposito_valor  numeric(14,2),
  deposito_data   date,
  sincronizacao_id uuid,
  primary key (unidade_id, dia)
);
create index cx_dias_dia on cx.dias (dia);
create index cx_dias_sinc on cx.dias (sincronizacao_id);

create table cx.pagamentos (                  -- cada valor do fechamento (sem cliente/OS)
  id               bigserial primary key,
  unidade_id       text not null references core.unidades(id),
  dia              date not null,
  origem           text not null check (origem in ('venda','entrega')),
  forma            text not null,
  valor            numeric(14,2) not null,
  sincronizacao_id uuid
);
create index cx_pagamentos_ud on cx.pagamentos (unidade_id, dia, forma);
create index cx_pagamentos_sinc on cx.pagamentos (sincronizacao_id);

create table cx.recebimentos (                -- extratos que não estão no financeiro: Asaas (API) e Stone (arquivo)
  id               text primary key,          -- 'asaas:pay_x' / 'stone:<id da transação>'
  fonte            text not null check (fonte in ('asaas','stone')),
  unidade_id       text not null references core.unidades(id),
  dia              date not null,
  forma            text not null,
  valor            numeric(14,2) not null check (valor > 0),
  parcela_crediario boolean not null default false,   -- parcela de crediário: fica para o agente de Cobranças
  sincronizacao_id uuid
);
create index cx_recebimentos_ud on cx.recebimentos (unidade_id, dia, forma);
create index cx_recebimentos_sinc on cx.recebimentos (sincronizacao_id);

create table cx.cobertura (                   -- até que dia cada extrato já foi lido, por loja
  fonte      text not null check (fonte in ('asaas','stone')),
  unidade_id text not null references core.unidades(id),
  ate        date not null,
  em         timestamptz not null default now(),
  primary key (fonte, unidade_id)
);
create index cx_cobertura_unidade on cx.cobertura (unidade_id);

create table cx.casamentos (                  -- resultado da conferência (recalculado)
  pagamento_id    bigint not null references cx.pagamentos(id) on delete cascade,
  recebimento     text not null,              -- 'banco:<uuid>' / 'asaas:...' / 'stone:...'
  modo            text not null check (modo in ('um_a_um','dois_em_um')),
  primary key (pagamento_id)
);
create index cx_casamentos_receb on cx.casamentos (recebimento);

create table cx.sincronizacoes (
  id                 uuid primary key default gen_random_uuid(),
  tarefa_id          uuid references core.tarefas(id),
  desde              date not null,
  ate                date not null check (ate >= desde),
  dias               int not null,
  pagamentos         int not null,
  recebimentos       int not null,
  total_caixa        numeric(14,2) not null,
  ignoradas          int not null,
  casados            int not null,
  alertas_abertos    int not null,
  alertas_resolvidos int not null,
  hash_lote          text not null,
  em                 timestamptz not null default now()
);
create index cx_sincronizacoes_tarefa on cx.sincronizacoes (tarefa_id);
create index cx_sincronizacoes_em on cx.sincronizacoes (em desc);

create table cx.alertas (
  id            bigserial primary key,
  tipo          text not null check (tipo in ('nao_encontrado','sem_registro_no_caixa','caixa_nao_fechado','caixa_inconsistente',
                                              'dinheiro_sem_deposito','extrato_atrasado')),
  referencia    text not null,                -- 'sao_vicente:2026-10-24:pix', 'sao_vicente:2026-10-24', 'sao_vicente:banco'
  unidade_id    text references core.unidades(id),
  dia           date,
  detalhe       jsonb,
  status        text not null default 'aberto' check (status in ('aberto','resolvido')),
  aberto_em     timestamptz not null default now(),
  resolvido_em  timestamptz,
  resolvido_por text
);
create unique index cx_alertas_abertos_uk on cx.alertas (tipo, referencia) where status = 'aberto';
create index cx_alertas_unidade on cx.alertas (unidade_id) where status = 'aberto';

insert into core.config (chave, valor) values
  ('cx.sync.ativo', 'false'),
  ('cx.tolerancia_valor', '0.10'),         -- diferença aceita ao casar um valor (centavos de arredondamento)
  ('cx.tolerancia_dia', '1.00'),           -- diferença aceita no total do dia (caixa × soma das formas)
  ('cx.folga_dias', '3'),                  -- o crédito pode cair até N dias depois (fim de semana) ou 1 dia antes
  ('cx.releitura_dias', '10'),             -- relê sempre os últimos N dias do ADM e do Asaas
  ('cx.sync.primeira_janela_dias', '35'),
  ('cx.deposito_prazo_dias', '3'),         -- dinheiro do caixa sem depósito registrado depois de N dias
  ('cx.extrato_atraso_dias', '2'),         -- extrato da loja sem leitura nova há mais de N dias
  ('cx.dias_sem_expediente', '0'),         -- dias da semana sem caixa (0 = domingo), separados por vírgula
  ('cx.pix_excluir', 'idealize|rf silva|r f e silva|rm comercio|r m comercio'),  -- Pix entre empresas do grupo não é venda
  ('versao_cx', '0.1.0')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Agente, papel, políticas e integrações
-- ---------------------------------------------------------------------------
insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('caixa', 'Agente de Caixa', 'financeiro', 'pausado', '0.1.0',
   'Confere o fechamento de caixa de cada loja contra o banco, o Asaas e a Stone, valor por valor, e aponta o que não bate. Só leitura: não baixa parcela, não estorna nem altera o fechamento.')
on conflict (id) do nothing;
insert into core.papeis (id, nome) values ('agente_caixa', 'Agente de caixa (máquina)') on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', 'Agente de Caixa', 'caixa' where not exists (select 1 from core.principais where agente_id = 'caixa');
insert into core.principal_papeis (principal_id, papel_id)
select id, 'agente_caixa' from core.principais where agente_id = 'caixa' on conflict do nothing;
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_caixa', 'cx.conferencia', 'sincronizar', 'baixo', 'automatica'
where not exists (select 1 from core.politicas where papel_id = 'agente_caixa' and recurso = 'cx.conferencia' and operacao = 'sincronizar' and ativo);
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_caixa', 'cx.conferencia', v.op, 'alto', 'proibida'
from (values ('baixar_parcela'), ('estornar'), ('transferir'), ('alterar_fechamento'), ('cobrar'), ('excluir')) v(op)
where not exists (select 1 from core.politicas where papel_id = 'agente_caixa' and recurso = 'cx.conferencia' and operacao = v.op and ativo);

update core.integracoes set credencial_leitura = 'ASAAS_TOKENS',
  observacoes = 'API v3, uma chave por loja (ASAAS_TOKENS = "unidade=chave" por linha). Só GET em /payments. Escrita proibida pela matriz.'
 where id = 'asaas';
update core.integracoes set observacoes = 'Extrato por arquivo (relatório de vendas do portal); formato a confirmar com arquivo real.'
 where id = 'stone';
insert into core.integracoes (id, nome, status, credencial_leitura, observacoes) values
  ('adm_caixa', 'Sistema ADM — fechamento de caixa', 'nao_verificada', 'ADM_LEITURA_DB_URL',
   'Visões idealize_ai.caixa_pagamentos e caixa_dias (sem cliente/OS), usuário só leitura.')
on conflict (id) do nothing;

create or replace function cx._cfg_num(p_chave text, p_padrao numeric) returns numeric
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(nullif(core.cfg(p_chave, p_padrao::text), '')::numeric, p_padrao)
$$;

-- Créditos de Pix no banco da loja que contam como venda (exclui transferências entre empresas do grupo)
create or replace view cx.v_pix_banco with (security_invoker = true) as
select 'banco:' || m.id as recebimento, c.unidade_id, m.data as dia, m.valor
from fin.movimentos m join fin.contas c on c.id = m.conta_id
where c.tipo = 'corrente' and c.ativo and m.sentido = 'credito' and m.status <> 'ignorado'
  and cx._simples(m.descricao) like '%pix%'
  and cx._simples(m.descricao) !~ coalesce(nullif(core.cfg('cx.pix_excluir', ''), ''), '^$');

-- Todos os recebimentos que entram na conferência, numa forma só
create or replace view cx.v_recebimentos with (security_invoker = true) as
select recebimento, unidade_id, dia, 'pix'::text as forma, valor, 'banco'::text as fonte from cx.v_pix_banco
union all
select id, unidade_id, dia, forma, valor, fonte from cx.recebimentos where not parcela_crediario;

-- ---------------------------------------------------------------------------
-- 3. Conferência: casa cada valor do caixa com o extrato e recalcula os alertas
-- ---------------------------------------------------------------------------
create or replace function cx.recalcular() returns jsonb
language plpgsql security definer set search_path = cx, core, pg_catalog as $$
declare d date := cx._hoje(); v_tv numeric := cx._cfg_num('cx.tolerancia_valor', 0.10);
  v_td numeric := cx._cfg_num('cx.tolerancia_dia', 1); v_folga int := cx._cfg_num('cx.folga_dias', 3)::int;
  v_dep int := cx._cfg_num('cx.deposito_prazo_dias', 3)::int; v_atr int := cx._cfg_num('cx.extrato_atraso_dias', 2)::int;
  v_ini date; p record; v_r text; v_r2 record; n_cas int; n_ab int; n_res int; v_fechados int[];
begin
  select coalesce(min(dia), d) into v_ini from cx.dias;
  v_ini := greatest(v_ini, d - 60);
  select coalesce(array_agg(x::int), '{}') into v_fechados
  from unnest(string_to_array(core.cfg('cx.dias_sem_expediente', '0'), ',')) x where btrim(x) ~ '^[0-6]$';

  -- recebimentos elegíveis na janela (fixos durante o cálculo)
  drop table if exists _rec;
  create temp table _rec on commit drop as
    select r.recebimento, r.unidade_id, r.dia, r.forma, r.valor, false as usado
    from cx.v_recebimentos r where r.dia >= v_ini - 1;
  create index on _rec (unidade_id, forma, valor);

  delete from cx.casamentos;

  -- 1º passo: um valor do caixa = um crédito (mesmo valor, de 1 dia antes até N dias depois)
  for p in select pg.* from cx.pagamentos pg join cx.fontes_forma ff on ff.forma = pg.forma and ff.fonte in ('banco','asaas','stone')
           where pg.dia >= v_ini and pg.valor > 0 order by pg.dia, pg.valor desc, pg.id loop
    select r.recebimento into v_r from _rec r
     where not r.usado and r.unidade_id = p.unidade_id and r.forma = p.forma and abs(r.valor - p.valor) <= v_tv
       and r.dia between p.dia - 1 and p.dia + v_folga
     order by abs(r.dia - p.dia), r.recebimento limit 1;
    if found then
      update _rec set usado = true where recebimento = v_r;
      insert into cx.casamentos values (p.id, v_r, 'um_a_um');
    end if;
  end loop;

  -- 2º passo: dois valores do caixa (mesma loja, forma e dia) = um crédito só
  for v_r2 in
    select r.recebimento, r.unidade_id, r.forma, r.dia, r.valor from _rec r where not r.usado order by r.dia, r.recebimento loop
    select a.id ia, b.id ib into p
      from cx.pagamentos a join cx.pagamentos b on b.unidade_id = a.unidade_id and b.forma = a.forma and b.dia = a.dia and b.id > a.id
     where a.unidade_id = v_r2.unidade_id and a.forma = v_r2.forma and a.dia between v_r2.dia - v_folga and v_r2.dia + 1
       and a.dia >= v_ini and abs(a.valor + b.valor - v_r2.valor) <= v_tv
       and not exists (select 1 from cx.casamentos c where c.pagamento_id in (a.id, b.id))
     order by abs(a.dia - v_r2.dia), a.id limit 1;
    if found then
      update _rec set usado = true where recebimento = v_r2.recebimento;
      insert into cx.casamentos values (p.ia, v_r2.recebimento, 'dois_em_um'), (p.ib, v_r2.recebimento, 'dois_em_um');
    end if;
  end loop;
  select count(*) into n_cas from cx.casamentos;

  -- Alertas devidos
  drop table if exists _devidos;
  create temp table _devidos (tipo text, referencia text, unidade_id text, dia date, detalhe jsonb) on commit drop;

  -- valores do caixa não achados no extrato, só quando o extrato já cobre o dia + folga
  insert into _devidos
  select 'nao_encontrado', pg.unidade_id || ':' || pg.dia || ':' || pg.forma, pg.unidade_id, pg.dia,
         jsonb_build_object('forma', pg.forma, 'rotulo', ff.rotulo, 'fonte', ff.fonte, 'quantidade', count(*), 'valor', sum(pg.valor),
                            'valores', jsonb_agg(pg.valor order by pg.valor desc))
  from cx.pagamentos pg join cx.fontes_forma ff on ff.forma = pg.forma
  where pg.dia >= v_ini and pg.valor > 0 and ff.fonte in ('banco','asaas','stone')
    and not exists (select 1 from cx.casamentos c where c.pagamento_id = pg.id)
    and pg.dia + v_folga <= case ff.fonte
          when 'banco' then (select max(m.data) from fin.movimentos m join fin.contas c on c.id = m.conta_id
                             where c.unidade_id = pg.unidade_id and c.tipo = 'corrente')
          else (select co.ate from cx.cobertura co where co.fonte = ff.fonte and co.unidade_id = pg.unidade_id) end
  group by pg.unidade_id, pg.dia, pg.forma, ff.rotulo, ff.fonte;

  -- dinheiro que entrou no extrato e não está em nenhum fechamento (agrupado por loja/dia/forma)
  insert into _devidos
  select 'sem_registro_no_caixa', r.unidade_id || ':' || r.dia || ':' || r.forma || ':extrato', r.unidade_id, r.dia,
         jsonb_build_object('forma', r.forma, 'rotulo', (select rotulo from cx.fontes_forma where forma = r.forma),
                            'quantidade', count(*), 'valor', sum(r.valor), 'valores', jsonb_agg(r.valor order by r.valor desc))
  from _rec r
  where not r.usado and r.dia >= v_ini and r.dia <= d - v_folga - 1
    and exists (select 1 from cx.dias x where x.unidade_id = r.unidade_id)
  group by r.unidade_id, r.dia, r.forma;

  -- dia útil sem fechamento no ADM (a partir do primeiro fechamento lido da loja; não conta hoje)
  insert into _devidos
  select 'caixa_nao_fechado', u.unidade_id || ':' || g.dia::date, u.unidade_id, g.dia::date, jsonb_build_object('dia', g.dia::date)
  from (select unidade_id, min(dia) ini from cx.dias group by unidade_id) u
  cross join lateral generate_series(greatest(u.ini, d - 14), d - 1, interval '1 day') g(dia)
  where not (extract(dow from g.dia)::int = any(v_fechados))
    and not exists (select 1 from cx.dias x where x.unidade_id = u.unidade_id and x.dia = g.dia::date);

  -- total do caixa diferente da soma das formas
  insert into _devidos
  select 'caixa_inconsistente', x.unidade_id || ':' || x.dia, x.unidade_id, x.dia,
         jsonb_build_object('caixa', x.caixa, 'soma_formas', x.soma_formas, 'diferenca', x.caixa - x.soma_formas)
  from cx.dias x where x.dia >= v_ini and x.caixa is not null and abs(x.caixa - x.soma_formas) > v_td;

  -- dinheiro recebido sem depósito registrado no prazo
  insert into _devidos
  select 'dinheiro_sem_deposito', x.unidade_id || ':' || x.dia, x.unidade_id, x.dia,
         jsonb_build_object('dinheiro', s.valor, 'prazo_dias', v_dep)
  from cx.dias x join lateral (select sum(valor) valor from cx.pagamentos pg where pg.unidade_id = x.unidade_id and pg.dia = x.dia and pg.forma = 'dinheiro') s on true
  where x.dia >= v_ini and x.dia <= d - v_dep and coalesce(s.valor, 0) > 0 and x.deposito_valor is null;

  -- extrato atrasado: a loja tem fechamento recente e a fonte não foi lida há mais de N dias
  insert into _devidos
  select 'extrato_atrasado', u.unidade_id || ':' || f.fonte, u.unidade_id, null,
         jsonb_build_object('fonte', f.fonte, 'ultimo_dia', f.ate, 'limite_dias', v_atr)
  from (select distinct unidade_id from cx.dias where dia >= d - 7) u
  cross join lateral (
    select 'banco'::text fonte, (select max(m.data) from fin.movimentos m join fin.contas c on c.id = m.conta_id
                                 where c.unidade_id = u.unidade_id and c.tipo = 'corrente') ate
    where exists (select 1 from fin.contas c where c.unidade_id = u.unidade_id and c.tipo = 'corrente' and c.ativo)
    union all
    select co.fonte, co.ate from cx.cobertura co where co.unidade_id = u.unidade_id) f
  where coalesce(f.ate, '1900-01-01') < d - v_atr;

  insert into cx.alertas (tipo, referencia, unidade_id, dia, detalhe)
  select tipo, referencia, unidade_id, dia, detalhe from _devidos
  on conflict (tipo, referencia) where status = 'aberto'
  do update set detalhe = excluded.detalhe;
  get diagnostics n_ab = row_count;

  update cx.alertas a set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente_caixa: situação deixou de existir'
   where a.status = 'aberto' and not exists (select 1 from _devidos x where x.tipo = a.tipo and x.referencia = a.referencia);
  get diagnostics n_res = row_count;
  return jsonb_build_object('casados', n_cas, 'ativos', n_ab, 'resolvidos', n_res);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Aplicação de um lote — idempotente; o ADM é a verdade do caixa (a janela é substituída).
-- Formato: {desde, ate (AAAA-MM-DD),
--   adm: {dias:[{unidade,data,status,caixa,dinheiro_gaveta,deposito_valor,deposito_data}],
--         pagamentos:[{unidade,data,origem,forma,valor}]},
--   asaas: [{unidade_id, ate, pagamentos:[{id,dia,forma,valor,parcela}]}],
--   stone: [{unidade_id, ate, transacoes:[{id,dia,forma,valor}]}]}
-- ---------------------------------------------------------------------------
create or replace function cx.aplicar_lote(p_tarefa uuid, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = cx, core, pg_catalog as $$
declare v_s uuid := gen_random_uuid(); v_desde date; v_ate date; b jsonb;
  n_dias int; n_pag int; n_rec int := 0; n_ign int := 0; v_tot numeric; v_al jsonb; n int;
begin
  if jsonb_typeof(p_lote) is distinct from 'object' then raise exception 'lote inválido'; end if;
  if coalesce(p_lote->>'desde', '') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(p_lote->>'ate', '') !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'lote sem janela (desde/ate)';
  end if;
  v_desde := (p_lote->>'desde')::date; v_ate := (p_lote->>'ate')::date;
  if v_ate < v_desde or v_ate - v_desde > 92 then raise exception 'janela inválida'; end if;
  if jsonb_typeof(p_lote->'adm') is distinct from 'object' then raise exception 'lote sem dados do ADM'; end if;

  -- ADM: substitui a janela inteira (o que foi apagado no ADM some daqui também)
  delete from cx.pagamentos where dia between v_desde and v_ate;
  delete from cx.dias where dia between v_desde and v_ate;

  with r as (
    select x.*, o.unidade_id from jsonb_to_recordset(coalesce(p_lote->'adm'->'pagamentos', '[]')) x(unidade text, data date, origem text, forma text, valor numeric)
    left join cx.unidades_origem o on o.origem = x.unidade
  ), ok as (
    select * from r where unidade_id is not null and data between v_desde and v_ate and origem in ('venda','entrega')
      and valor is not null and valor <> 0 and abs(valor) < 10000000 and cx._forma(forma) <> 'nao_financeiro'
  ), ins as (
    insert into cx.pagamentos (unidade_id, dia, origem, forma, valor, sincronizacao_id)
    select unidade_id, data, origem, cx._forma(forma), round(valor, 2), v_s from ok returning 1)
  select (select count(*) from ins), (select count(*) from r) - (select count(*) from ok) into n_pag, n_ign;

  with r as (
    select x.*, o.unidade_id from jsonb_to_recordset(coalesce(p_lote->'adm'->'dias', '[]')) x(unidade text, data date, status text,
      caixa numeric, dinheiro_gaveta numeric, deposito_valor numeric, deposito_data date)
    left join cx.unidades_origem o on o.origem = x.unidade
  ), ins as (
    insert into cx.dias (unidade_id, dia, status_adm, caixa, soma_formas, dinheiro_gaveta, deposito_valor, deposito_data, sincronizacao_id)
    select r.unidade_id, r.data, left(r.status, 20), round(r.caixa, 2),
           coalesce((select sum(valor) from cx.pagamentos pg where pg.unidade_id = r.unidade_id and pg.dia = r.data), 0),
           round(r.dinheiro_gaveta, 2), round(r.deposito_valor, 2), r.deposito_data, v_s
    from r where r.unidade_id is not null and r.data between v_desde and v_ate
    on conflict (unidade_id, dia) do nothing
    returning 1)
  select count(*) into n_dias from ins;
  n_ign := n_ign + (select count(*) from jsonb_array_elements(coalesce(p_lote->'adm'->'dias', '[]'))) - n_dias;

  -- Asaas e Stone: por loja, substitui o período lido e avança a cobertura
  for b in select * from jsonb_array_elements(coalesce(p_lote->'asaas', '[]') || coalesce(p_lote->'stone', '[]')) loop
    if not exists (select 1 from core.unidades where id = b->>'unidade_id') or coalesce(b->>'ate', '') !~ '^\d{4}-\d{2}-\d{2}$' then
      n_ign := n_ign + 1; continue;
    end if;
    delete from cx.recebimentos
     where fonte = case when b ? 'transacoes' then 'stone' else 'asaas' end and unidade_id = b->>'unidade_id' and dia between v_desde and (b->>'ate')::date;
    with r as (
      select x.* from jsonb_to_recordset(coalesce(b->'pagamentos', b->'transacoes', '[]')) x(id text, dia date, forma text, valor numeric, parcela boolean)
    ), ins as (
      insert into cx.recebimentos (id, fonte, unidade_id, dia, forma, valor, parcela_crediario, sincronizacao_id)
      select (case when b ? 'transacoes' then 'stone:' else 'asaas:' end) || left(r.id, 80), case when b ? 'transacoes' then 'stone' else 'asaas' end,
             b->>'unidade_id', r.dia, r.forma, round(r.valor, 2), coalesce(r.parcela, false), v_s
      from r where coalesce(r.id, '') ~ '^[A-Za-z0-9_-]{3,80}$' and r.dia between v_desde and (b->>'ate')::date
        and r.forma in ('pix','credito','debito','asaas') and r.valor > 0
      on conflict (id) do update set dia = excluded.dia, forma = excluded.forma, valor = excluded.valor,
        parcela_crediario = excluded.parcela_crediario, sincronizacao_id = excluded.sincronizacao_id, unidade_id = excluded.unidade_id
      returning 1)
    select count(*) into n from ins;
    n_rec := n_rec + n;
    insert into cx.cobertura (fonte, unidade_id, ate) values (case when b ? 'transacoes' then 'stone' else 'asaas' end, b->>'unidade_id', (b->>'ate')::date)
    on conflict (fonte, unidade_id) do update set ate = greatest(cx.cobertura.ate, excluded.ate), em = now();
  end loop;

  select coalesce(sum(caixa), 0) into v_tot from cx.dias where sincronizacao_id = v_s;
  v_al := cx.recalcular();

  insert into cx.sincronizacoes (id, tarefa_id, desde, ate, dias, pagamentos, recebimentos, total_caixa, ignoradas, casados,
    alertas_abertos, alertas_resolvidos, hash_lote)
  values (v_s, p_tarefa, v_desde, v_ate, n_dias, n_pag, n_rec, v_tot, n_ign, (v_al->>'casados')::int,
    (v_al->>'ativos')::int, (v_al->>'resolvidos')::int, md5(p_lote::text));
  return jsonb_build_object('sincronizacao', v_s, 'desde', v_desde, 'ate', v_ate, 'dias', n_dias, 'pagamentos', n_pag,
    'recebimentos', n_rec, 'total_caixa', v_tot, 'ignoradas', n_ign, 'alertas', v_al, 'hash_lote', md5(p_lote::text));
end $$;

create or replace function cx.concluir_sincronizacao(p_tarefa uuid, p_executor text, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = cx, core, pg_catalog as $$
declare t record; v jsonb;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'caixa' or t.tipo is distinct from 'cx_sincronizacao' then
    raise exception 'tarefa não é sincronização do caixa';
  end if;
  v := cx.aplicar_lote(p_tarefa, p_lote);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', v->>'hash_lote', v);
  return v;
end $$;

create or replace function cx.proxima_janela() returns jsonb
language sql stable security definer set search_path = cx, core, pg_catalog as $$
  select jsonb_build_object(
    'desde', case when exists (select 1 from cx.sincronizacoes)
                  then cx._hoje() - (cx._cfg_num('cx.releitura_dias', 10)::int - 1)
                  else cx._hoje() - (cx._cfg_num('cx.sync.primeira_janela_dias', 35)::int - 1) end,
    'ate', cx._hoje(),
    'unidades_origem', (select jsonb_object_agg(origem, unidade_id) from cx.unidades_origem))
$$;

-- ---------------------------------------------------------------------------
-- 5. Validador independente
-- ---------------------------------------------------------------------------
create or replace function cx.validar_sincronizacao(p_tarefa uuid, p_validador text) returns text
language plpgsql security definer set search_path = cx, core, pg_catalog as $$
declare t record; s record; v_erros text[] := '{}'; n int; g numeric;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  select * into s from cx.sincronizacoes where tarefa_id = p_tarefa order by em desc limit 1;
  if s.id is null then
    v_erros := v_erros || 'sincronização sem registro';
  else
    select count(*) into n from cx.pagamentos where sincronizacao_id = s.id;
    if n <> s.pagamentos then v_erros := v_erros || format('espelho tem %s valores do caixa, registro diz %s', n, s.pagamentos); end if;
    select count(*), coalesce(sum(caixa), 0) into n, g from cx.dias where sincronizacao_id = s.id;
    if n <> s.dias then v_erros := v_erros || format('espelho tem %s dias, registro diz %s', n, s.dias); end if;
    if g <> s.total_caixa then v_erros := v_erros || format('total do caixa %s, registro diz %s', g, s.total_caixa); end if;
    -- soma das formas de cada dia confere com os valores gravados
    select count(*) into n from cx.dias x
     where x.sincronizacao_id = s.id
       and x.soma_formas <> coalesce((select sum(valor) from cx.pagamentos pg where pg.unidade_id = x.unidade_id and pg.dia = x.dia), 0);
    if n > 0 then v_erros := v_erros || format('%s dias com soma das formas errada', n); end if;
    -- casamento coerente: nenhum crédito usado por valores de loja ou forma diferentes, nem valor do caixa casado duas vezes
    select count(*) into n from cx.casamentos c join cx.pagamentos pg on pg.id = c.pagamento_id
     where not exists (select 1 from cx.v_recebimentos r where r.recebimento = c.recebimento and r.unidade_id = pg.unidade_id and r.forma = pg.forma);
    if n > 0 then v_erros := v_erros || format('%s casamentos entre loja/forma diferentes', n); end if;
    select count(*) into n from (select recebimento from cx.casamentos where modo = 'um_a_um' group by recebimento having count(*) > 1) q;
    if n > 0 then v_erros := v_erros || format('%s créditos usados mais de uma vez', n); end if;
    -- completude: valor do caixa sem casamento em dia já coberto pelo extrato tem alerta
    select count(*) into n from cx.pagamentos pg join cx.fontes_forma ff on ff.forma = pg.forma and ff.fonte = 'asaas'
     join cx.cobertura co on co.fonte = 'asaas' and co.unidade_id = pg.unidade_id
     where pg.valor > 0 and pg.dia >= cx._hoje() - 60 and pg.dia + cx._cfg_num('cx.folga_dias', 3)::int <= co.ate
       and not exists (select 1 from cx.casamentos c where c.pagamento_id = pg.id)
       and not exists (select 1 from cx.alertas a where a.tipo = 'nao_encontrado' and a.status = 'aberto'
                       and a.referencia = pg.unidade_id || ':' || pg.dia || ':' || pg.forma);
    if n > 0 then v_erros := v_erros || format('%s valores do Asaas não achados e sem alerta', n); end if;
  end if;
  if array_length(v_erros, 1) is null then
    return core.registrar_validacao(p_tarefa, p_validador, true, null, jsonb_build_object('sincronizacao', s.id));
  end if;
  return core.registrar_validacao(p_tarefa, p_validador, false, array_to_string(v_erros, '; '),
    jsonb_build_object('sincronizacao', s.id, 'erros', to_jsonb(v_erros)));
end $$;

-- Três leituras por dia (o caixa fecha no fim do expediente; o Asaas e o banco têm atraso)
create or replace function cx.agendar_sincronizacao() returns uuid
language plpgsql security definer set search_path = cx, core, pg_catalog as $$
declare v_p uuid; h int := extract(hour from now() at time zone 'America/Sao_Paulo')::int;
begin
  if core.cfg('cx.sync.ativo', 'false') <> 'true' then return null; end if;
  select id into v_p from core.principais where agente_id = 'caixa';
  return core.criar_tarefa(v_p, 'caixa', 'cx_sincronizacao', 'cx.conferencia', 'sincronizar', null,
    jsonb_build_object('origem', 'adm+asaas'),
    'cx:sync:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDD') || ':' || (h / 8), null, 6);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Painel
-- ---------------------------------------------------------------------------
create or replace function public.painel_caixa(p_unidade text default null, p_dias int default 7) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[]; g boolean; d int := least(greatest(coalesce(p_dias, 7), 1), 60); v_hoje date := cx._hoje(); v_ini date;
begin
  v_eu := painel._entrar('caixa', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; g := false; end if;
  v_ini := v_hoje - (d - 1);
  return jsonb_build_object(
    'periodo_dias', d, 'desde', v_ini, 'ate', v_hoje,
    'sincronizacao', jsonb_build_object('ativa', core.cfg('cx.sync.ativo', 'false') = 'true',
       'agente', (select status from core.agentes where id = 'caixa'),
       'ultima', (select jsonb_build_object('em', em, 'desde', desde, 'ate', ate, 'dias', dias, 'casados', casados)
                  from cx.sincronizacoes order by em desc limit 1)),
    'fontes', (select jsonb_agg(jsonb_build_object('forma', forma, 'fonte', fonte, 'rotulo', rotulo) order by forma) from cx.fontes_forma),
    'cobertura', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
       select jsonb_build_object('unidade_id', c.unidade_id, 'fonte', 'banco',
         'ate', (select max(m.data) from fin.movimentos m where m.conta_id in (select id from fin.contas where unidade_id = c.unidade_id and tipo = 'corrente'))) x
       from (select distinct unidade_id from fin.contas where tipo = 'corrente' and ativo and unidade_id = any(un)) c
       union all
       select jsonb_build_object('unidade_id', co.unidade_id, 'fonte', co.fonte, 'ate', co.ate) from cx.cobertura co where co.unidade_id = any(un)) q),
    -- por loja, dia e forma: total do caixa, quanto foi achado no extrato e quanto falta
    'conferencia', (select coalesce(jsonb_agg(x order by x->>'dia' desc, x->>'unidade_id', x->>'forma'), '[]'::jsonb) from (
      select jsonb_build_object('unidade_id', pg.unidade_id, 'dia', pg.dia, 'forma', pg.forma,
        'sistema', sum(pg.valor), 'quantidade', count(*),
        'achado', coalesce(sum(pg.valor) filter (where exists (select 1 from cx.casamentos c where c.pagamento_id = pg.id)), 0),
        'faltando', coalesce(sum(pg.valor) filter (where not exists (select 1 from cx.casamentos c where c.pagamento_id = pg.id)), 0)) x
      from cx.pagamentos pg
      where pg.dia >= v_ini and pg.unidade_id = any(un)
      group by pg.unidade_id, pg.dia, pg.forma) q),
    'dias', (select coalesce(jsonb_agg(jsonb_build_object('unidade_id', x.unidade_id, 'dia', x.dia, 'status_adm', x.status_adm,
        'caixa', x.caixa, 'soma_formas', x.soma_formas, 'deposito_valor', x.deposito_valor) order by x.dia desc, x.unidade_id), '[]'::jsonb)
      from cx.dias x where x.dia >= v_ini and x.unidade_id = any(un)),
    'alertas', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'referencia', a.referencia, 'unidade_id', a.unidade_id, 'dia', a.dia,
        'aberto_em', a.aberto_em, 'detalhe', a.detalhe) x
      from cx.alertas a
      where a.status = 'aberto' and (a.unidade_id = any(un) or (g and a.unidade_id is null))
      order by case a.tipo when 'nao_encontrado' then 0 when 'caixa_nao_fechado' then 1 when 'dinheiro_sem_deposito' then 2
                           when 'caixa_inconsistente' then 3 when 'extrato_atrasado' then 4 else 5 end, a.dia desc nulls last
      limit 300) q));
end $$;

-- ---------------------------------------------------------------------------
-- 7. Endurecimento
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'cx' loop
    execute format('alter table cx.%I enable row level security', r.tablename);
    execute format('alter table cx.%I force row level security', r.tablename);
    execute format('revoke all on cx.%I from public', r.tablename);
  end loop;
  execute 'revoke all on cx.v_pix_banco, cx.v_recebimentos from public';
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cx' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', r.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema cx from anon, authenticated';
    execute 'revoke all on function public.painel_caixa(text, int) from public, anon';
    execute 'grant execute on function public.painel_caixa(text, int) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema cx to service_role';
    execute 'grant select on all tables in schema cx to service_role';
    execute 'grant execute on function public.painel_caixa(text, int) to service_role';
  end if;
end $$;
