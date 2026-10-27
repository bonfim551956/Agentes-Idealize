-- =============================================================================
-- Idealize AI — Agente de Cobranças (v0.1.0)  · Migração 20261027130000
--
-- Primeira versão = ACOMPANHAMENTO, só leitura. Lê o crediário do Sistema ADM (parcelas Asaas e Multicrédito, sem
-- nome/CPF/telefone; só o número da OS) e as cobranças do Asaas de cada loja. Mostra a carteira a receber e o atraso
-- por loja, e cruza ADM × Asaas: pago no Asaas e não baixado no ADM, baixado no ADM sem pagamento no Asaas, cobrança
-- ativa no Asaas sem parcela em aberto no ADM (cliente cobrado indevidamente), parcela sem boleto emitido e entrada
-- não paga. NÃO envia cobrança nem mensagem, não baixa, não cancela, não renegocia (políticas proibidas).
-- Nasce PAUSADO e com a sincronização DESLIGADA (cob.sync.ativo = false).
-- =============================================================================

create schema if not exists cob;
revoke all on schema cob from public;

create or replace function cob._hoje() returns date
language sql stable set search_path = pg_catalog as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create table cob.unidades_origem (
  origem     text primary key,
  unidade_id text not null references core.unidades(id)
);
create index cob_unidades_origem_unidade on cob.unidades_origem (unidade_id);
insert into cob.unidades_origem (origem, unidade_id)
select v.o, v.u from (values ('campinas','campinas'), ('piracicaba','piracicaba'), ('saovicente','sao_vicente'), ('sorocaba','sorocaba')) v(o, u)
where exists (select 1 from core.unidades where id = v.u);

-- ---------------------------------------------------------------------------
-- 1. Espelho
-- ---------------------------------------------------------------------------
create table cob.carnes (
  id              text primary key,
  unidade_id      text not null references core.unidades(id),
  financeira      text not null check (financeira in ('asaas','multicredito','outra')),
  os              text,
  os_provisoria   boolean not null default false,
  status_adm      text,
  renegociado     boolean not null default false,
  dt_compra       date,
  valor_crediario numeric(14,2),
  valor_entrada   numeric(14,2),
  entrada_paga    boolean not null default false,
  dt_entrada      date,
  sincronizacao_id uuid
);
create index cob_carnes_unidade on cob.carnes (unidade_id);
create index cob_carnes_sinc on cob.carnes (sincronizacao_id);

create table cob.parcelas (
  id              text primary key,
  carne_id        text not null references cob.carnes(id) on delete cascade,
  unidade_id      text not null references core.unidades(id),
  financeira      text not null,
  numero          int,
  total           int,
  valor           numeric(14,2) not null check (valor >= 0),
  vencimento      date not null,
  pagamento       date,
  status_adm      text not null,
  sincronizacao_id uuid
);
create index cob_parcelas_carne on cob.parcelas (carne_id);
create index cob_parcelas_unidade_venc on cob.parcelas (unidade_id, vencimento);
create index cob_parcelas_sinc on cob.parcelas (sincronizacao_id);

create table cob.asaas (                      -- cobranças do Asaas (carnê/boleto/Pix; cartão fica no agente de Caixa)
  id              text primary key,
  unidade_id      text not null references core.unidades(id),
  valor           numeric(14,2) not null check (valor > 0),
  vencimento      date not null,
  status          text not null,
  pagamento       date,
  parcelamento    text,
  sincronizacao_id uuid
);
create index cob_asaas_unidade_venc on cob.asaas (unidade_id, vencimento);
create index cob_asaas_sinc on cob.asaas (sincronizacao_id);

create table cob.cobertura_asaas (
  unidade_id text primary key references core.unidades(id),
  em         timestamptz not null default now()
);

create table cob.vinculos (                   -- parcela do ADM ↔ cobrança do Asaas (recalculado)
  parcela_id text primary key references cob.parcelas(id) on delete cascade,
  asaas_id   text not null unique references cob.asaas(id) on delete cascade
);

create table cob.sincronizacoes (
  id                 uuid primary key default gen_random_uuid(),
  tarefa_id          uuid references core.tarefas(id),
  carnes             int not null,
  parcelas           int not null,
  cobrancas_asaas    int not null,
  vinculos           int not null,
  carteira_aberta    numeric(14,2) not null,
  ignoradas          int not null,
  alertas_abertos    int not null,
  alertas_resolvidos int not null,
  hash_lote          text not null,
  em                 timestamptz not null default now()
);
create index cob_sincronizacoes_tarefa on cob.sincronizacoes (tarefa_id);
create index cob_sincronizacoes_em on cob.sincronizacoes (em desc);

create table cob.alertas (
  id            bigserial primary key,
  tipo          text not null check (tipo in ('parcela_vencida','pago_sem_baixa','baixa_sem_pagamento','cobranca_sem_parcela',
                                              'parcela_sem_cobranca','entrada_pendente')),
  referencia    text not null,                -- 'carne:abc', 'parcela:xyz', 'asaas:pay_1'
  unidade_id    text references core.unidades(id),
  detalhe       jsonb,
  status        text not null default 'aberto' check (status in ('aberto','resolvido')),
  aberto_em     timestamptz not null default now(),
  resolvido_em  timestamptz,
  resolvido_por text
);
create unique index cob_alertas_abertos_uk on cob.alertas (tipo, referencia) where status = 'aberto';
create index cob_alertas_unidade on cob.alertas (unidade_id) where status = 'aberto';

insert into core.config (chave, valor) values
  ('cob.sync.ativo', 'false'),
  ('cob.carencia_dias', '1'),              -- parcela conta como vencida depois de N dias do vencimento
  ('cob.tolerancia_valor', '0.10'),
  ('cob.folga_vencimento_dias', '5'),      -- vencimento no ADM × no Asaas pode diferir até N dias
  ('cob.boleto_antecedencia_dias', '15'),  -- parcela do Asaas que vence em até N dias precisa ter cobrança emitida
  ('versao_cob', '0.1.0')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Agente, papel, políticas
-- ---------------------------------------------------------------------------
insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('cobrancas', 'Agente de Cobranças', 'financeiro', 'pausado', '0.1.0',
   'Acompanha o crediário das lojas (Asaas e Multicrédito): carteira a receber, atraso e divergências entre o sistema da loja e o Asaas. Só leitura: não envia cobrança nem mensagem, não baixa, não cancela nem renegocia.')
on conflict (id) do nothing;
insert into core.papeis (id, nome) values ('agente_cobrancas', 'Agente de cobranças (máquina)') on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', 'Agente de Cobranças', 'cobrancas' where not exists (select 1 from core.principais where agente_id = 'cobrancas');
insert into core.principal_papeis (principal_id, papel_id)
select id, 'agente_cobrancas' from core.principais where agente_id = 'cobrancas' on conflict do nothing;
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_cobrancas', 'cob.crediario', 'sincronizar', 'baixo', 'automatica'
where not exists (select 1 from core.politicas where papel_id = 'agente_cobrancas' and recurso = 'cob.crediario' and operacao = 'sincronizar' and ativo);
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_cobrancas', 'cob.crediario', v.op, 'alto', 'proibida'
from (values ('enviar_cobranca'), ('enviar_mensagem'), ('baixar_parcela'), ('cancelar_cobranca'), ('renegociar'), ('emitir_boleto'), ('excluir')) v(op)
where not exists (select 1 from core.politicas where papel_id = 'agente_cobrancas' and recurso = 'cob.crediario' and operacao = v.op and ativo);
insert into core.integracoes (id, nome, status, credencial_leitura, observacoes) values
  ('adm_crediario', 'Sistema ADM — crediário', 'nao_verificada', 'ADM_LEITURA_DB_URL',
   'Visão idealize_ai.crediario_parcelas (sem nome/CPF/telefone; só OS), usuário só leitura.')
on conflict (id) do nothing;

create or replace function cob._cfg_num(p_chave text, p_padrao numeric) returns numeric
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(nullif(core.cfg(p_chave, p_padrao::text), '')::numeric, p_padrao)
$$;

-- ---------------------------------------------------------------------------
-- 3. Cruzamento ADM × Asaas e alertas (recalculados para o estado inteiro; resolvem sozinhos)
-- ---------------------------------------------------------------------------
create or replace function cob.recalcular() returns jsonb
language plpgsql security definer set search_path = cob, core, pg_catalog as $$
declare d date := cob._hoje(); v_car int := cob._cfg_num('cob.carencia_dias', 1)::int;
  v_tv numeric := cob._cfg_num('cob.tolerancia_valor', 0.10); v_fv int := cob._cfg_num('cob.folga_vencimento_dias', 5)::int;
  v_ant int := cob._cfg_num('cob.boleto_antecedencia_dias', 15)::int;
  p record; v_a text; n_v int; n_ab int; n_res int;
begin
  -- vínculo parcela ↔ cobrança: mesma loja, mesmo valor, vencimento próximo; um para um, o vencimento mais perto primeiro
  delete from cob.vinculos;
  for p in select pa.* from cob.parcelas pa where pa.financeira = 'asaas' and pa.status_adm in ('aberto','pago')
           order by pa.vencimento, pa.id loop
    select a.id into v_a from cob.asaas a
     where a.unidade_id = p.unidade_id and abs(a.valor - p.valor) <= v_tv and abs(a.vencimento - p.vencimento) <= v_fv
       and not exists (select 1 from cob.vinculos v where v.asaas_id = a.id)
     order by abs(a.vencimento - p.vencimento), (a.status in ('RECEIVED','CONFIRMED','RECEIVED_IN_CASH')) = (p.status_adm = 'pago') desc, a.id
     limit 1;
    if found then insert into cob.vinculos values (p.id, v_a); end if;
  end loop;
  select count(*) into n_v from cob.vinculos;

  drop table if exists _devidos;
  create temp table _devidos (tipo text, referencia text, unidade_id text, detalhe jsonb) on commit drop;

  -- carnê com parcela vencida em aberto (e que o Asaas não mostra como paga)
  insert into _devidos
  select 'parcela_vencida', 'carne:' || c.id, c.unidade_id,
         jsonb_build_object('os', c.os, 'os_provisoria', c.os_provisoria, 'financeira', c.financeira, 'parcelas', count(*),
                            'valor', sum(pa.valor), 'dias', max(d - pa.vencimento), 'vencimento_mais_antigo', min(pa.vencimento))
  from cob.parcelas pa join cob.carnes c on c.id = pa.carne_id
  where pa.status_adm = 'aberto' and pa.vencimento < d - v_car and coalesce(c.status_adm, '') <> 'cancelado'
    and not exists (select 1 from cob.vinculos v join cob.asaas a on a.id = v.asaas_id
                    where v.parcela_id = pa.id and a.status in ('RECEIVED','CONFIRMED','RECEIVED_IN_CASH'))
  group by c.id, c.unidade_id, c.os, c.os_provisoria, c.financeira;

  -- pago no Asaas e ainda em aberto no ADM
  insert into _devidos
  select 'pago_sem_baixa', 'parcela:' || pa.id, pa.unidade_id,
         jsonb_build_object('os', c.os, 'numero', pa.numero, 'total', pa.total, 'valor', pa.valor, 'vencimento', pa.vencimento,
                            'pago_em', a.pagamento)
  from cob.parcelas pa join cob.carnes c on c.id = pa.carne_id join cob.vinculos v on v.parcela_id = pa.id join cob.asaas a on a.id = v.asaas_id
  where pa.status_adm = 'aberto' and a.status in ('RECEIVED','CONFIRMED','RECEIVED_IN_CASH');

  -- baixado no ADM, mas a cobrança do Asaas continua em aberto
  insert into _devidos
  select 'baixa_sem_pagamento', 'parcela:' || pa.id, pa.unidade_id,
         jsonb_build_object('os', c.os, 'numero', pa.numero, 'total', pa.total, 'valor', pa.valor, 'baixado_em', pa.pagamento,
                            'status_asaas', a.status)
  from cob.parcelas pa join cob.carnes c on c.id = pa.carne_id join cob.vinculos v on v.parcela_id = pa.id join cob.asaas a on a.id = v.asaas_id
  where pa.status_adm = 'pago' and a.status in ('PENDING','OVERDUE');

  -- cobrança ativa no Asaas sem parcela em aberto no ADM (cancelada, renegociada ou nunca lançada): cliente pode pagar à toa
  insert into _devidos
  select 'cobranca_sem_parcela', 'asaas:' || a.id, a.unidade_id,
         jsonb_build_object('valor', a.valor, 'vencimento', a.vencimento, 'status_asaas', a.status)
  from cob.asaas a
  where a.status in ('PENDING','OVERDUE') and not exists (select 1 from cob.vinculos v where v.asaas_id = a.id)
    and exists (select 1 from cob.cobertura_asaas co where co.unidade_id = a.unidade_id);

  -- parcela do Asaas vencendo logo e sem cobrança emitida
  insert into _devidos
  select 'parcela_sem_cobranca', 'parcela:' || pa.id, pa.unidade_id,
         jsonb_build_object('os', c.os, 'numero', pa.numero, 'total', pa.total, 'valor', pa.valor, 'vencimento', pa.vencimento)
  from cob.parcelas pa join cob.carnes c on c.id = pa.carne_id
  where pa.financeira = 'asaas' and pa.status_adm = 'aberto' and pa.vencimento <= d + v_ant
    and coalesce(c.status_adm, '') <> 'cancelado'
    and not exists (select 1 from cob.vinculos v where v.parcela_id = pa.id)
    and exists (select 1 from cob.cobertura_asaas co where co.unidade_id = pa.unidade_id);

  -- entrada combinada e não paga
  insert into _devidos
  select 'entrada_pendente', 'carne:' || c.id, c.unidade_id,
         jsonb_build_object('os', c.os, 'financeira', c.financeira, 'valor', c.valor_entrada, 'combinada_para', c.dt_entrada)
  from cob.carnes c
  where not c.entrada_paga and coalesce(c.valor_entrada, 0) > 0 and c.dt_entrada < d - v_car and coalesce(c.status_adm, '') <> 'cancelado';

  insert into cob.alertas (tipo, referencia, unidade_id, detalhe)
  select tipo, referencia, unidade_id, detalhe from _devidos
  on conflict (tipo, referencia) where status = 'aberto'
  do update set detalhe = excluded.detalhe, unidade_id = excluded.unidade_id;
  get diagnostics n_ab = row_count;

  update cob.alertas a set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente_cobrancas: situação deixou de existir'
   where a.status = 'aberto' and not exists (select 1 from _devidos x where x.tipo = a.tipo and x.referencia = a.referencia);
  get diagnostics n_res = row_count;
  return jsonb_build_object('vinculos', n_v, 'ativos', n_ab, 'resolvidos', n_res);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Aplicação de um lote — retrato completo do crediário (ADM é a verdade) + cobranças do Asaas por loja.
-- Formato: {parcelas:[{id,crediario_id,unidade,financeira,numero,num_parcelas,valor,dt_vencimento,dt_pagamento,status,
--             os,os_fake,carne_status,renegociado,dt_compra,valor_crediario,valor_entrada,entrada_paga,dt_entrada}],
--           asaas:[{unidade_id, cobrancas:[{id,valor,vencimento,status,pagamento,parcelamento}]}]}
-- ---------------------------------------------------------------------------
create or replace function cob.aplicar_lote(p_tarefa uuid, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = cob, core, pg_catalog as $$
declare v_s uuid := gen_random_uuid(); b jsonb; n_ca int; n_pa int; n_as int := 0; n_ign int; n int; v_cart numeric; v_al jsonb;
begin
  if jsonb_typeof(p_lote) is distinct from 'object' or jsonb_typeof(p_lote->'parcelas') is distinct from 'array' then
    raise exception 'lote sem parcelas do ADM';
  end if;
  if jsonb_array_length(p_lote->'parcelas') = 0 and exists (select 1 from cob.parcelas) then
    raise exception 'lote veio vazio e o espelho tem parcelas: leitura suspeita, nada foi apagado';
  end if;

  drop table if exists _p;
  create temp table _p on commit drop as
  select x.*, o.unidade_id
  from jsonb_to_recordset(p_lote->'parcelas') x(id text, crediario_id text, unidade text, financeira text, numero int, num_parcelas int,
    valor numeric, dt_vencimento date, dt_pagamento date, status text, os text, os_fake boolean, carne_status text, renegociado boolean,
    dt_compra date, valor_crediario numeric, valor_entrada numeric, entrada_paga boolean, dt_entrada date)
  left join cob.unidades_origem o on o.origem = x.unidade
  where coalesce(x.id, '') ~ '^[A-Za-z0-9_.:-]{1,80}$' and coalesce(x.crediario_id, '') ~ '^[A-Za-z0-9_.:-]{1,80}$';
  n_ign := jsonb_array_length(p_lote->'parcelas') - (select count(*) from _p where unidade_id is not null and valor >= 0 and dt_vencimento is not null);

  -- retrato completo: o que sumiu do ADM sai daqui também
  delete from cob.vinculos;
  delete from cob.parcelas;
  delete from cob.carnes;
  insert into cob.carnes (id, unidade_id, financeira, os, os_provisoria, status_adm, renegociado, dt_compra, valor_crediario,
    valor_entrada, entrada_paga, dt_entrada, sincronizacao_id)
  select distinct on (crediario_id) crediario_id, unidade_id,
         case when lower(financeira) in ('asaas','multicredito') then lower(financeira) else 'outra' end,
         left(os, 40), coalesce(os_fake, false), left(carne_status, 20), coalesce(renegociado, false), dt_compra,
         round(valor_crediario, 2), round(valor_entrada, 2), coalesce(entrada_paga, false), dt_entrada, v_s
  from _p where unidade_id is not null order by crediario_id, id;
  get diagnostics n_ca = row_count;
  insert into cob.parcelas (id, carne_id, unidade_id, financeira, numero, total, valor, vencimento, pagamento, status_adm, sincronizacao_id)
  select id, crediario_id, unidade_id, case when lower(financeira) in ('asaas','multicredito') then lower(financeira) else 'outra' end,
         numero, num_parcelas, round(valor, 2), dt_vencimento, dt_pagamento, lower(coalesce(status, 'aberto')), v_s
  from _p where unidade_id is not null and valor >= 0 and dt_vencimento is not null
  on conflict (id) do nothing;
  get diagnostics n_pa = row_count;

  -- Asaas: retrato por loja lida
  for b in select * from jsonb_array_elements(coalesce(p_lote->'asaas', '[]')) loop
    if not exists (select 1 from core.unidades where id = b->>'unidade_id') then n_ign := n_ign + 1; continue; end if;
    delete from cob.asaas where unidade_id = b->>'unidade_id';
    insert into cob.asaas (id, unidade_id, valor, vencimento, status, pagamento, parcelamento, sincronizacao_id)
    select r.id, b->>'unidade_id', round(r.valor, 2), r.vencimento, r.status, r.pagamento, left(r.parcelamento, 80), v_s
    from jsonb_to_recordset(coalesce(b->'cobrancas', '[]')) r(id text, valor numeric, vencimento date, status text, pagamento date, parcelamento text)
    where coalesce(r.id, '') ~ '^[A-Za-z0-9_-]{3,80}$' and r.valor > 0 and r.vencimento is not null
      and r.status in ('PENDING','OVERDUE','RECEIVED','CONFIRMED','RECEIVED_IN_CASH')
    on conflict (id) do nothing;
    get diagnostics n = row_count;
    n_as := n_as + n;
    insert into cob.cobertura_asaas (unidade_id) values (b->>'unidade_id') on conflict (unidade_id) do update set em = now();
  end loop;

  select coalesce(sum(valor), 0) into v_cart from cob.parcelas where status_adm = 'aberto';
  v_al := cob.recalcular();
  insert into cob.sincronizacoes (id, tarefa_id, carnes, parcelas, cobrancas_asaas, vinculos, carteira_aberta, ignoradas,
    alertas_abertos, alertas_resolvidos, hash_lote)
  values (v_s, p_tarefa, n_ca, n_pa, n_as, (v_al->>'vinculos')::int, v_cart, n_ign, (v_al->>'ativos')::int, (v_al->>'resolvidos')::int,
    md5(p_lote::text));
  return jsonb_build_object('sincronizacao', v_s, 'carnes', n_ca, 'parcelas', n_pa, 'cobrancas_asaas', n_as, 'carteira_aberta', v_cart,
    'ignoradas', n_ign, 'alertas', v_al, 'hash_lote', md5(p_lote::text));
end $$;

create or replace function cob.concluir_sincronizacao(p_tarefa uuid, p_executor text, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = cob, core, pg_catalog as $$
declare t record; v jsonb;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'cobrancas' or t.tipo is distinct from 'cob_sincronizacao' then
    raise exception 'tarefa não é sincronização de cobranças';
  end if;
  v := cob.aplicar_lote(p_tarefa, p_lote);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', v->>'hash_lote', v);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Validador independente
-- ---------------------------------------------------------------------------
create or replace function cob.validar_sincronizacao(p_tarefa uuid, p_validador text) returns text
language plpgsql security definer set search_path = cob, core, pg_catalog as $$
declare t record; s record; v_erros text[] := '{}'; n int; g numeric; d date := cob._hoje();
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  select * into s from cob.sincronizacoes where tarefa_id = p_tarefa order by em desc limit 1;
  if s.id is null then
    v_erros := v_erros || 'sincronização sem registro';
  else
    select count(*) into n from cob.parcelas where sincronizacao_id = s.id;
    if n <> s.parcelas then v_erros := v_erros || format('espelho tem %s parcelas, registro diz %s', n, s.parcelas); end if;
    select coalesce(sum(valor), 0) into g from cob.parcelas where status_adm = 'aberto';
    if g <> s.carteira_aberta then v_erros := v_erros || format('carteira %s, registro diz %s', g, s.carteira_aberta); end if;
    -- vínculos coerentes: mesma loja e valor dentro da tolerância
    select count(*) into n from cob.vinculos v join cob.parcelas p on p.id = v.parcela_id join cob.asaas a on a.id = v.asaas_id
     where a.unidade_id <> p.unidade_id or abs(a.valor - p.valor) > cob._cfg_num('cob.tolerancia_valor', 0.10);
    if n > 0 then v_erros := v_erros || format('%s vínculos entre loja ou valor diferentes', n); end if;
    -- completude: todo carnê ativo com parcela vencida em aberto (sem pagamento no Asaas) tem alerta
    select count(*) into n from (
      select distinct pa.carne_id from cob.parcelas pa join cob.carnes c on c.id = pa.carne_id
      where pa.status_adm = 'aberto' and pa.vencimento < d - cob._cfg_num('cob.carencia_dias', 1)::int
        and coalesce(c.status_adm, '') <> 'cancelado'
        and not exists (select 1 from cob.vinculos v join cob.asaas a on a.id = v.asaas_id
                        where v.parcela_id = pa.id and a.status in ('RECEIVED','CONFIRMED','RECEIVED_IN_CASH'))) x
    where not exists (select 1 from cob.alertas a where a.tipo = 'parcela_vencida' and a.status = 'aberto' and a.referencia = 'carne:' || x.carne_id);
    if n > 0 then v_erros := v_erros || format('%s carnês com atraso sem alerta', n); end if;
  end if;
  if array_length(v_erros, 1) is null then
    return core.registrar_validacao(p_tarefa, p_validador, true, null, jsonb_build_object('sincronizacao', s.id));
  end if;
  return core.registrar_validacao(p_tarefa, p_validador, false, array_to_string(v_erros, '; '),
    jsonb_build_object('sincronizacao', s.id, 'erros', to_jsonb(v_erros)));
end $$;

-- Duas leituras por dia (manhã e tarde)
create or replace function cob.agendar_sincronizacao() returns uuid
language plpgsql security definer set search_path = cob, core, pg_catalog as $$
declare v_p uuid; h int := extract(hour from now() at time zone 'America/Sao_Paulo')::int;
begin
  if core.cfg('cob.sync.ativo', 'false') <> 'true' then return null; end if;
  select id into v_p from core.principais where agente_id = 'cobrancas';
  return core.criar_tarefa(v_p, 'cobrancas', 'cob_sincronizacao', 'cob.crediario', 'sincronizar', null,
    jsonb_build_object('origem', 'adm+asaas'),
    'cob:sync:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDD') || ':' || (h / 12), null, 6);
end $$;

create or replace function cob.janela_asaas() returns jsonb
language sql stable security definer set search_path = cob, core, pg_catalog as $$
  select jsonb_build_object('pagos_desde', cob._hoje() - 120, 'hoje', cob._hoje())
$$;

-- ---------------------------------------------------------------------------
-- 6. Painel
-- ---------------------------------------------------------------------------
create or replace function public.painel_cobrancas(p_unidade text default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[]; d date := cob._hoje();
begin
  v_eu := painel._entrar('cobrancas', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; end if;
  return jsonb_build_object(
    'hoje', d,
    'sincronizacao', jsonb_build_object('ativa', core.cfg('cob.sync.ativo', 'false') = 'true',
       'agente', (select status from core.agentes where id = 'cobrancas'),
       'ultima', (select jsonb_build_object('em', em, 'parcelas', parcelas, 'cobrancas_asaas', cobrancas_asaas, 'vinculos', vinculos)
                  from cob.sincronizacoes order by em desc limit 1),
       'asaas_lojas', (select coalesce(jsonb_agg(unidade_id), '[]'::jsonb) from cob.cobertura_asaas where unidade_id = any(un))),
    'carteira', (select coalesce(jsonb_agg(x order by x->>'unidade_id', x->>'financeira'), '[]'::jsonb) from (
      select jsonb_build_object('unidade_id', pa.unidade_id, 'financeira', pa.financeira,
        'a_vencer_30', coalesce(sum(pa.valor) filter (where pa.vencimento >= d and pa.vencimento < d + 30), 0),
        'a_vencer_total', coalesce(sum(pa.valor) filter (where pa.vencimento >= d), 0),
        'vencido_1_30', coalesce(sum(pa.valor) filter (where pa.vencimento < d and pa.vencimento >= d - 30), 0),
        'vencido_31_60', coalesce(sum(pa.valor) filter (where pa.vencimento < d - 30 and pa.vencimento >= d - 60), 0),
        'vencido_61_90', coalesce(sum(pa.valor) filter (where pa.vencimento < d - 60 and pa.vencimento >= d - 90), 0),
        'vencido_90_mais', coalesce(sum(pa.valor) filter (where pa.vencimento < d - 90), 0),
        'parcelas_vencidas', count(*) filter (where pa.vencimento < d),
        'clientes_em_atraso', count(distinct pa.carne_id) filter (where pa.vencimento < d)) x
      from cob.parcelas pa join cob.carnes c on c.id = pa.carne_id
      where pa.status_adm = 'aberto' and coalesce(c.status_adm, '') <> 'cancelado' and pa.unidade_id = any(un)
      group by pa.unidade_id, pa.financeira) q),
    'recebido_30d', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('unidade_id', unidade_id, 'financeira', financeira, 'valor', sum(valor), 'parcelas', count(*)) x
      from cob.parcelas where status_adm = 'pago' and pagamento >= d - 30 and unidade_id = any(un) group by unidade_id, financeira) q),
    'alertas', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'referencia', a.referencia, 'unidade_id', a.unidade_id,
        'aberto_em', a.aberto_em, 'detalhe', a.detalhe) x
      from cob.alertas a where a.status = 'aberto' and a.unidade_id = any(un)
      order by case a.tipo when 'cobranca_sem_parcela' then 0 when 'pago_sem_baixa' then 1 when 'baixa_sem_pagamento' then 2
                           when 'parcela_vencida' then 3 when 'entrada_pendente' then 4 else 5 end,
               (a.detalhe->>'dias')::int desc nulls last, a.aberto_em
      limit 400) q));
end $$;

-- ---------------------------------------------------------------------------
-- 7. Endurecimento
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'cob' loop
    execute format('alter table cob.%I enable row level security', r.tablename);
    execute format('alter table cob.%I force row level security', r.tablename);
    execute format('revoke all on cob.%I from public', r.tablename);
  end loop;
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cob' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', r.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema cob from anon, authenticated';
    execute 'revoke all on function public.painel_cobrancas(text) from public, anon';
    execute 'grant execute on function public.painel_cobrancas(text) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema cob to service_role';
    execute 'grant select on all tables in schema cob to service_role';
    execute 'grant execute on function public.painel_cobrancas(text) to service_role';
  end if;
end $$;
