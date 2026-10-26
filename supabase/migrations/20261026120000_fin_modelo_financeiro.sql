-- =============================================================================
-- Idealize AI — Agente Financeiro: modelo de dados e regras (schema fin)
-- Migração 20261026120000 — v0.2.0  (Etapas D1, D2, D3)
--
-- Princípios (prompt §9):
--  * Extrato bancário (fin.movimentos) é a evidência de que o dinheiro se moveu.
--    Comprovante não prova pagamento; documento fiscal não é saída de caixa.
--  * Cada lançamento tem NATUREZA explícita; nada é "entrada/saída" genérica.
--  * Caixa (regime de caixa) ≠ DRE (competência):
--      - cartão: a despesa entra na DRE na compra; o caixa só vê o pagamento da fatura
--      - reembolso: a DRE vê a despesa original; o caixa vê o reembolso pago
--      - transferência entre contas próprias: não é receita nem despesa
--      - transferência entre unidades: aparece por unidade, some no consolidado
--      - rateio: redistribui a DRE entre unidades; não cria movimento bancário
--  * Conciliação automática só com critérios testados; nunca altera valores;
--    divergência/ambiguidade vira pendência humana.
--  * O agente prepara o fechamento; só pessoa da diretoria aprova; o validador
--    recalcula pelo extrato, independentemente dos lançamentos.
-- =============================================================================

create schema if not exists fin;
revoke all on schema fin from public;

-- ---------------------------------------------------------------------------
-- 1. Cadastros
-- ---------------------------------------------------------------------------
create table fin.empresas (
  id            text primary key check (id ~ '^[a-z0-9_]{2,40}$'),
  razao_social  text not null,
  cnpj          text unique check (cnpj ~ '^[0-9]{14}$'),
  ativo         boolean not null default true
);

-- unidade gerencial (core.unidades) ↔ pessoa jurídica
create table fin.unidade_empresa (
  unidade_id  text primary key references core.unidades(id),
  empresa_id  text not null references fin.empresas(id)
);

create table fin.contas (
  id            text primary key check (id ~ '^[a-z0-9_]{2,40}$'),
  apelido       text not null,
  tipo          text not null check (tipo in ('corrente','poupanca','cartao_credito','caixa','carteira_digital','adquirente')),
  unidade_id    text not null references core.unidades(id),
  empresa_id    text references fin.empresas(id),
  instituicao   text,
  final_numero  text check (final_numero ~ '^[0-9]{2,6}$'),   -- só os dígitos finais; nunca o número completo
  ativo         boolean not null default true
);

create table fin.categorias (
  id        text primary key check (id ~ '^[a-z0-9_]{2,40}$'),
  nome      text not null,
  grupo     text not null,            -- linha do plano de contas
  natureza  text not null check (natureza in ('receita','despesa')),
  ativo     boolean not null default true
);

create table fin.contrapartes (
  id               uuid primary key default gen_random_uuid(),
  nome             text not null,
  documento        text unique check (documento ~ '^[0-9]{11}$|^[0-9]{14}$'),
  categoria_padrao text references fin.categorias(id),
  natureza_padrao  text,
  criado_em        timestamptz not null default now()
);

-- Regras de classificação de linhas do extrato (texto → natureza/categoria).
-- Origem e responsável registrados; agente só PROPÕE regra (status proposta).
create table fin.regras_classificacao (
  id           bigserial primary key,
  padrao       text not null,                       -- trecho (ILIKE) da descrição do banco
  sentido      text check (sentido in ('credito','debito')),
  natureza     text not null,
  categoria_id text references fin.categorias(id),
  unidade_destino text references core.unidades(id),  -- p/ transferência entre unidades
  prioridade   int not null default 100,
  status       text not null default 'ativa' check (status in ('ativa','proposta','inativa')),
  origem       text not null default 'manual',
  responsavel  text,
  versao       int not null default 1,
  criado_em    timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2. Documentos (comprovante ≠ documento fiscal ≠ extrato)
-- ---------------------------------------------------------------------------
create table fin.documentos (
  id            uuid primary key default gen_random_uuid(),
  tipo          text not null check (tipo in ('comprovante_pagamento','documento_fiscal','extrato','relatorio_pagamentos','boleto','outro')),
  sha256        text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  storage_path  text,
  mime          text,
  origem        text not null check (origem in ('whatsapp','painel','importacao','integracao','manual')),
  unidade_id    text references core.unidades(id),
  enviado_por   uuid references core.principais(id),
  recebido_em   timestamptz not null default now(),
  extraido      jsonb,          -- campos extraídos (IA/OCR)
  confianca     jsonb,          -- {campo: 0..1}, campos ausentes listados em extraido._ausentes
  status        text not null default 'recebido' check (status in ('recebido','extraido','revisao','vinculado','rejeitado')),
  retencao_ate  date,
  unique (sha256, unidade_id)  -- o MESMO arquivo; conteúdo igual ≠ operação igual (ver duplicidade)
);

-- ---------------------------------------------------------------------------
-- 3. Extratos e movimentos bancários (evidência do realizado)
-- ---------------------------------------------------------------------------
create table fin.importacoes (
  id            uuid primary key default gen_random_uuid(),
  conta_id      text not null references fin.contas(id),
  arquivo_sha256 text not null,
  formato       text not null check (formato in ('ofx','csv','json','manual')),
  periodo_inicio date, periodo_fim date,
  saldo_inicial numeric(14,2), saldo_final numeric(14,2),
  linhas        int not null default 0,
  novas         int not null default 0,
  duplicadas    int not null default 0,
  importado_por text not null,
  documento_id  uuid references fin.documentos(id),
  em            timestamptz not null default now(),
  unique (conta_id, arquivo_sha256)
);

create table fin.movimentos (
  id              uuid primary key default gen_random_uuid(),
  conta_id        text not null references fin.contas(id),
  data            date not null,
  sentido         text not null check (sentido in ('credito','debito')),
  valor           numeric(14,2) not null check (valor > 0),
  descricao       text not null,               -- texto ORIGINAL do banco, nunca reescrito
  documento_banco text,                        -- FITID / E2E / autenticação
  saldo_apos      numeric(14,2),
  chave_dedup     text not null,
  importacao_id   uuid references fin.importacoes(id),
  status          text not null default 'pendente' check (status in ('pendente','conciliado','divergente','ignorado')),
  criado_em       timestamptz not null default now(),
  unique (conta_id, chave_dedup)
);
create index movimentos_conta_data on fin.movimentos (conta_id, data);
create index movimentos_pendentes on fin.movimentos (conta_id, data) where status = 'pendente';

-- ---------------------------------------------------------------------------
-- 4. Lançamentos gerenciais
-- ---------------------------------------------------------------------------
create table fin.lancamentos (
  id              uuid primary key default gen_random_uuid(),
  numero          bigserial unique,
  natureza        text not null check (natureza in (
                    'receita','despesa','transferencia_interna','transferencia_unidades',
                    'reembolso','pagamento_fatura','ajuste')),
  sentido         text not null check (sentido in ('entrada','saida')),
  valor           numeric(14,2) not null check (valor > 0),
  unidade_id      text not null references core.unidades(id),
  conta_id        text references fin.contas(id),
  categoria_id    text references fin.categorias(id),
  contraparte_id  uuid references fin.contrapartes(id),
  contraparte_nome text,
  descricao       text,
  data_competencia date not null,
  data_caixa      date,                       -- quando o dinheiro se move (ou previsão)
  status          text not null default 'pendente' check (status in (
                    'previsto','pendente','confirmado','conciliado','contestado','cancelado')),
  estimado        boolean not null default false,
  origem          text not null check (origem in ('whatsapp','extrato','painel','integracao','manual','sistema')),
  par_id          uuid references fin.lancamentos(id),          -- outra perna da transferência
  original_id     uuid references fin.lancamentos(id),          -- reembolso → despesa original
  fatura_id       uuid,                                         -- compra no cartão → fatura
  documento_banco text,                                         -- E2E/ID do comprovante, p/ conciliação
  motivo          text,
  aprovado_por    uuid references core.principais(id),
  tarefa_id       uuid references core.tarefas(id),
  criado_por      text not null,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now(),
  check (natureza not in ('transferencia_interna','transferencia_unidades') or par_id is not null or status = 'cancelado'),
  check (natureza <> 'reembolso' or original_id is not null),
  check (natureza <> 'ajuste' or (coalesce(motivo,'') <> '' and aprovado_por is not null)),
  check (natureza not in ('receita','despesa') or status <> 'confirmado' or categoria_id is not null),  -- confirmar exige categoria
  check (status <> 'previsto' or estimado or data_caixa is not null)
);
create index lancamentos_unidade_comp on fin.lancamentos (unidade_id, data_competencia);
create index lancamentos_conta_caixa on fin.lancamentos (conta_id, data_caixa);

create table fin.lancamento_documentos (
  lancamento_id uuid not null references fin.lancamentos(id),
  documento_id  uuid not null references fin.documentos(id),
  papel         text not null check (papel in ('comprovante','nota_fiscal','boleto','outro')),
  primary key (lancamento_id, documento_id)
);

create table fin.faturas_cartao (
  id           uuid primary key default gen_random_uuid(),
  conta_id     text not null references fin.contas(id),
  competencia  date not null,       -- 1º dia do mês da fatura
  vencimento   date not null,
  valor_total  numeric(14,2) not null check (valor_total >= 0),
  status       text not null default 'aberta' check (status in ('aberta','fechada','paga','divergente')),
  pagamento_id uuid references fin.lancamentos(id),
  unique (conta_id, competencia)
);
alter table fin.lancamentos add constraint lancamentos_fatura_fk foreign key (fatura_id) references fin.faturas_cartao(id);

create table fin.rateios (
  id            uuid primary key default gen_random_uuid(),
  lancamento_id uuid not null unique references fin.lancamentos(id),
  criterio      text not null,
  criado_por    text not null,
  criado_em     timestamptz not null default now()
);
create table fin.rateio_itens (
  rateio_id   uuid not null references fin.rateios(id),
  unidade_id  text not null references core.unidades(id),
  valor       numeric(14,2) not null check (valor > 0),
  primary key (rateio_id, unidade_id)
);

-- Conciliação: movimento do banco ↔ lançamento (1 movimento pode cobrir N lançamentos, ex.: lote)
create table fin.conciliacoes (
  id             bigserial primary key,
  movimento_id   uuid not null references fin.movimentos(id),
  lancamento_id  uuid not null unique references fin.lancamentos(id),
  valor          numeric(14,2) not null check (valor > 0),
  regra          text not null check (regra in ('id_bancario','valor_data_unico','manual','extrato')),
  confirmado_por text not null,
  em             timestamptz not null default now()
);

create table fin.pendencias (
  id           bigserial primary key,
  tipo         text not null check (tipo in ('divergencia','ambiguidade','sem_classificacao','sem_comprovante',
                                               'duplicidade_suspeita','rateio_desbalanceado','transferencia_sem_par',
                                               'fatura_divergente','saldo_divergente','comprovante_sem_pagamento')),
  unidade_id   text references core.unidades(id),
  movimento_id uuid references fin.movimentos(id),
  lancamento_id uuid references fin.lancamentos(id),
  detalhe      jsonb,
  referencia   text not null default '',          -- id da importação/fatura quando não há movimento/lançamento
  material     boolean not null default true,     -- bloqueia fechamento
  status       text not null default 'aberta' check (status in ('aberta','resolvida','aceita')),
  resolvido_por uuid references core.principais(id),
  resolucao    text,
  criado_em    timestamptz not null default now(),
  resolvido_em timestamptz
);
create unique index pendencias_abertas_uk on fin.pendencias
  (tipo, coalesce(unidade_id,''), coalesce(movimento_id::text,''), coalesce(lancamento_id::text,''), referencia) where status = 'aberta';

create table fin.fechamentos (
  id             uuid primary key default gen_random_uuid(),
  unidade_id     text references core.unidades(id),     -- null = consolidado
  competencia    date not null check (extract(day from competencia) = 1),
  status         text not null default 'preparado' check (status in ('preparado','bloqueado','validado','aprovado','rejeitado','reaberto')),
  pacote         jsonb not null,
  pacote_hash    text not null,
  pendencias_materiais int not null,
  validacao      jsonb,
  preparado_por  text not null,
  validado_por   text,
  aprovado_por   uuid references core.principais(id),
  decisao_motivo text,
  versao         int not null default 1,
  criado_em      timestamptz not null default now(),
  decidido_em    timestamptz
);
create unique index fechamentos_vigente on fin.fechamentos (coalesce(unidade_id,'*'), competencia)
  where status in ('preparado','bloqueado','validado','aprovado');

-- ---------------------------------------------------------------------------
-- 5. Proteções de integridade
-- ---------------------------------------------------------------------------
-- valor de lançamento conciliado/cancelado não muda; cancelado nunca é apagado
create or replace function fin._proteger_lancamento() returns trigger
language plpgsql set search_path = fin, core, pg_catalog as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'lançamentos não são apagados; cancele com motivo' using errcode = '42501';
  end if;
  if old.status in ('conciliado','cancelado') and (new.valor <> old.valor or new.sentido <> old.sentido
     or new.conta_id is distinct from old.conta_id) then
    raise exception 'lançamento % está %: valor/sentido/conta não podem mudar', old.numero, old.status using errcode = '42501';
  end if;
  if old.status = 'cancelado' and new.status <> 'cancelado' then
    raise exception 'lançamento cancelado não volta; crie outro' using errcode = '42501';
  end if;
  if new.status = 'cancelado' and old.status <> 'cancelado' and coalesce(new.motivo,'') = '' then
    raise exception 'cancelamento exige motivo';
  end if;
  new.atualizado_em := now();
  perform core.auditar(null, 'fin', 'lancamento_' || lower(tg_op), 'fin.lancamento', old.id::text,
    to_jsonb(old) - 'atualizado_em', to_jsonb(new) - 'atualizado_em', new.motivo);
  return new;
end $$;
create trigger lancamentos_protecao before update or delete on fin.lancamentos
  for each row execute function fin._proteger_lancamento();

create or replace function fin._aud_lancamento_ins() returns trigger
language plpgsql set search_path = fin, core, pg_catalog as $$
begin
  perform core.auditar(null, new.criado_por, 'lancamento_insert', 'fin.lancamento', new.id::text, null, to_jsonb(new));
  return new;
end $$;
create trigger lancamentos_aud_ins after insert on fin.lancamentos
  for each row execute function fin._aud_lancamento_ins();

-- movimentos do banco são imutáveis (só o status de conciliação muda)
create or replace function fin._proteger_movimento() returns trigger
language plpgsql set search_path = fin, pg_catalog as $$
begin
  if tg_op = 'DELETE' then raise exception 'movimentos bancários não são apagados' using errcode = '42501'; end if;
  if (new.valor, new.sentido, new.data, new.descricao, new.conta_id, coalesce(new.documento_banco,''))
     is distinct from (old.valor, old.sentido, old.data, old.descricao, old.conta_id, coalesce(old.documento_banco,'')) then
    raise exception 'dados do extrato são imutáveis' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger movimentos_protecao before update or delete on fin.movimentos
  for each row execute function fin._proteger_movimento();

-- soma das conciliações de um movimento não pode passar do valor do movimento
create or replace function fin._checar_conciliacao() returns trigger
language plpgsql set search_path = fin, pg_catalog as $$
declare v_mov numeric; v_soma numeric; v_lanc record;
begin
  select valor into v_mov from fin.movimentos where id = new.movimento_id for update;
  select coalesce(sum(valor),0) into v_soma from fin.conciliacoes where movimento_id = new.movimento_id;
  if v_soma + new.valor > v_mov then
    raise exception 'conciliação excede o valor do movimento (% + % > %)', v_soma, new.valor, v_mov;
  end if;
  select * into v_lanc from fin.lancamentos where id = new.lancamento_id;
  if new.valor <> v_lanc.valor then
    raise exception 'valor conciliado (%) difere do lançamento (%): não se força conciliação', new.valor, v_lanc.valor;
  end if;
  return new;
end $$;
create trigger conciliacoes_check before insert on fin.conciliacoes
  for each row execute function fin._checar_conciliacao();

-- ---------------------------------------------------------------------------
-- 6. Helpers
-- ---------------------------------------------------------------------------
create or replace function fin.so_digitos(t text) returns text
language sql immutable set search_path = pg_catalog as $$ select nullif(regexp_replace(coalesce(t,''), '\D', '', 'g'), '') $$;

create or replace function fin.cfg(p_chave text, p_padrao text) returns text
language sql stable security definer set search_path = core, pg_catalog as $$ select core.cfg(p_chave, p_padrao) $$;

create or replace function fin.abrir_pendencia(p_tipo text, p_unidade text, p_mov uuid, p_lanc uuid,
  p_detalhe jsonb, p_material boolean default true) returns bigint
language plpgsql security definer set search_path = fin, pg_catalog as $$
declare v_id bigint; v_ref text := coalesce(p_detalhe->>'importacao', p_detalhe->>'fatura', '');
begin
  select id into v_id from fin.pendencias
   where tipo = p_tipo and status = 'aberta' and coalesce(unidade_id,'') = coalesce(p_unidade,'')
     and coalesce(movimento_id::text,'') = coalesce(p_mov::text,'') and coalesce(lancamento_id::text,'') = coalesce(p_lanc::text,'')
     and referencia = v_ref;
  if v_id is null then
    insert into fin.pendencias (tipo, unidade_id, movimento_id, lancamento_id, detalhe, referencia, material)
    values (p_tipo, p_unidade, p_mov, p_lanc, p_detalhe, v_ref, p_material) returning id into v_id;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Registro de lançamentos (porta de entrada única)
-- ---------------------------------------------------------------------------
create or replace function fin.registrar_lancamento(
  p_natureza text, p_sentido text, p_valor numeric, p_unidade text, p_competencia date,
  p_criado_por text, p_origem text,
  p_conta text default null, p_categoria text default null, p_contraparte_nome text default null,
  p_contraparte_doc text default null, p_descricao text default null, p_data_caixa date default null,
  p_status text default 'pendente', p_documento_banco text default null, p_documento_id uuid default null,
  p_original uuid default null, p_estimado boolean default false) returns uuid
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare v_id uuid; v_cp uuid; v_doc text; v_tipo_conta text; v_dup uuid; v_fat uuid;
begin
  if p_natureza in ('transferencia_interna','transferencia_unidades') then
    raise exception 'use fin.registrar_transferência para transferências';
  end if;
  if p_natureza in ('receita') and p_sentido <> 'entrada' or p_natureza = 'despesa' and p_sentido <> 'saida' then
    raise exception 'natureza % incompatível com sentido %', p_natureza, p_sentido;
  end if;
  if p_categoria is not null and (select natureza from fin.categorias where id = p_categoria) is distinct from p_natureza
     and p_natureza in ('receita','despesa') then
    raise exception 'categoria % não é de %', p_categoria, p_natureza;
  end if;
  if p_status not in ('previsto','pendente','confirmado') then
    raise exception 'status inicial inválido (%): conciliação só acontece pelo extrato', p_status;
  end if;

  v_doc := fin.so_digitos(p_contraparte_doc);
  if v_doc is not null then
    insert into fin.contrapartes (nome, documento) values (coalesce(p_contraparte_nome, v_doc), v_doc)
    on conflict (documento) do update set nome = fin.contrapartes.nome returning id into v_cp;
  end if;

  -- compra no cartão: pendura na fatura da competência (cria a fatura aberta se preciso)
  select tipo into v_tipo_conta from fin.contas where id = p_conta;
  if v_tipo_conta = 'cartao_credito' and p_natureza = 'despesa' then
    insert into fin.faturas_cartao (conta_id, competencia, vencimento, valor_total)
    values (p_conta, date_trunc('month', coalesce(p_data_caixa, p_competencia))::date,
            (date_trunc('month', coalesce(p_data_caixa, p_competencia)) + interval '1 month 9 days')::date, 0)
    on conflict (conta_id, competencia) do nothing;
    select id into v_fat from fin.faturas_cartao
     where conta_id = p_conta and competencia = date_trunc('month', coalesce(p_data_caixa, p_competencia))::date;
  end if;

  -- duplicidade suspeita: mesmo ID bancário, ou mesmo valor+data+contraparte já registrado
  select id into v_dup from fin.lancamentos
   where status <> 'cancelado' and (
     (p_documento_banco is not null and documento_banco = p_documento_banco)
     or (valor = p_valor and unidade_id = p_unidade and coalesce(data_caixa, data_competencia) = coalesce(p_data_caixa, p_competencia)
         and ((v_cp is not null and contraparte_id = v_cp) or (v_cp is null and lower(coalesce(contraparte_nome,'')) = lower(coalesce(p_contraparte_nome,'-'))))))
   limit 1;

  insert into fin.lancamentos (natureza, sentido, valor, unidade_id, conta_id, categoria_id, contraparte_id, contraparte_nome,
    descricao, data_competencia, data_caixa, status, estimado, origem, original_id, fatura_id, documento_banco, criado_por)
  values (p_natureza, p_sentido, p_valor, p_unidade, p_conta,
    coalesce(p_categoria, (select categoria_padrao from fin.contrapartes where id = v_cp)),
    v_cp, p_contraparte_nome, p_descricao, p_competencia, p_data_caixa,
    case when v_dup is not null then 'pendente' else p_status end,
    p_estimado, p_origem, p_original, v_fat, p_documento_banco, p_criado_por)
  returning id into v_id;

  if p_documento_id is not null then
    insert into fin.lancamento_documentos (lancamento_id, documento_id, papel)
    values (v_id, p_documento_id, case (select tipo from fin.documentos where id = p_documento_id)
       when 'documento_fiscal' then 'nota_fiscal' when 'boleto' then 'boleto'
       when 'comprovante_pagamento' then 'comprovante' else 'outro' end);
  end if;
  if v_dup is not null then
    perform fin.abrir_pendencia('duplicidade_suspeita', p_unidade, null, v_id, jsonb_build_object('possivel_original', v_dup));
  end if;
  if v_fat is not null then
    update fin.faturas_cartao set valor_total = valor_total + p_valor where id = v_fat;
  end if;
  return v_id;
end $$;

-- Transferência: sempre duas pernas ligadas. Entre contas da mesma unidade = interna;
-- entre unidades = transferencia_unidades (aparece por unidade, some no consolidado).
create or replace function fin.registrar_transferencia(p_conta_origem text, p_conta_destino text, p_valor numeric,
  p_data date, p_criado_por text, p_origem text default 'manual', p_descricao text default null,
  p_status text default 'pendente') returns uuid
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare o record; d record; v_nat text; v_saida uuid; v_entrada uuid;
begin
  select * into o from fin.contas where id = p_conta_origem;
  select * into d from fin.contas where id = p_conta_destino;
  if o is null or d is null or o.id = d.id then raise exception 'contas de origem/destino inválidas'; end if;
  v_nat := case when o.unidade_id = d.unidade_id then 'transferencia_interna' else 'transferencia_unidades' end;
  -- a perna de saída nasce com par provisório (ela mesma) e é religada em seguida
  v_saida := gen_random_uuid(); v_entrada := gen_random_uuid();
  insert into fin.lancamentos (id, natureza, sentido, valor, unidade_id, conta_id, descricao, data_competencia, data_caixa,
    status, origem, par_id, criado_por)
  values (v_saida, v_nat, 'saida', p_valor, o.unidade_id, o.id, p_descricao, p_data, p_data, p_status, p_origem, v_saida, p_criado_por),
         (v_entrada, v_nat, 'entrada', p_valor, d.unidade_id, d.id, p_descricao, p_data, p_data, p_status, p_origem, v_saida, p_criado_por);
  update fin.lancamentos set par_id = v_entrada where id = v_saida;
  return v_saida;
end $$;

-- Rateio gerencial: soma dos itens tem de fechar com o lançamento
create or replace function fin.ratear(p_lancamento uuid, p_itens jsonb, p_criterio text, p_criado_por text) returns uuid
language plpgsql security definer set search_path = fin, pg_catalog as $$
declare l record; v_id uuid; v_soma numeric;
begin
  select * into l from fin.lancamentos where id = p_lancamento;
  if l.natureza <> 'despesa' or l.status = 'cancelado' then raise exception 'só despesas ativas podem ser rateadas'; end if;
  select sum((i->>'valor')::numeric) into v_soma from jsonb_array_elements(p_itens) i;
  if v_soma is distinct from l.valor then
    raise exception 'rateio desbalanceado: itens somam %, lançamento vale %', v_soma, l.valor;
  end if;
  insert into fin.rateios (lancamento_id, criterio, criado_por) values (p_lancamento, p_criterio, p_criado_por) returning id into v_id;
  insert into fin.rateio_itens (rateio_id, unidade_id, valor)
  select v_id, i->>'unidade', (i->>'valor')::numeric from jsonb_array_elements(p_itens) i;
  perform core.auditar(null, p_criado_por, 'rateio', 'fin.lancamento', p_lancamento::text, null, jsonb_build_object('itens', p_itens), p_criterio);
  return v_id;
end $$;

create or replace function fin.cancelar_lancamento(p_lancamento uuid, p_motivo text, p_ator text) returns void
language plpgsql security definer set search_path = fin, pg_catalog as $$
declare l record;
begin
  select * into l from fin.lancamentos where id = p_lancamento for update;
  if l.status = 'conciliado' then
    raise exception 'lançamento conciliado com o extrato não pode ser cancelado; registre estorno/ajuste aprovado';
  end if;
  update fin.lancamentos set status = 'cancelado', motivo = p_motivo where id = p_lancamento;
  if l.par_id is not null and l.par_id <> l.id then
    update fin.lancamentos set status = 'cancelado', motivo = p_motivo where id = l.par_id and status <> 'cancelado';
  end if;
  if l.fatura_id is not null then
    update fin.faturas_cartao set valor_total = valor_total - l.valor where id = l.fatura_id;
  end if;
end $$;

-- Ajuste contábil: só com motivo e aprovação de pessoa da diretoria
create or replace function fin.registrar_ajuste(p_unidade text, p_sentido text, p_valor numeric, p_competencia date,
  p_motivo text, p_aprovador uuid, p_criado_por text, p_conta text default null) returns uuid
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare v_id uuid;
begin
  if not exists (select 1 from core.principais pr join core.principal_papeis pp on pp.principal_id = pr.id
                  where pr.id = p_aprovador and pr.tipo = 'usuario' and pr.ativo and pp.papel_id = 'diretoria'
                    and (pp.valido_ate is null or pp.valido_ate > now())) then
    raise exception 'ajuste exige aprovação de pessoa da diretoria' using errcode = '42501';
  end if;
  insert into fin.lancamentos (natureza, sentido, valor, unidade_id, conta_id, data_competencia, data_caixa,
    status, origem, motivo, aprovado_por, criado_por)
  values ('ajuste', p_sentido, p_valor, p_unidade, p_conta, p_competencia, p_competencia, 'confirmado', 'manual',
    p_motivo, p_aprovador, p_criado_por) returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Importação de extrato (idempotente por arquivo e por linha)
-- linhas: [{data, valor (com sinal: + crédito, − débito), descricao, documento?, saldo?}]
-- ---------------------------------------------------------------------------
create or replace function fin.importar_extrato(p_conta text, p_arquivo_sha256 text, p_formato text,
  p_linhas jsonb, p_importado_por text, p_saldo_inicial numeric default null, p_saldo_final numeric default null)
returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare v_imp uuid; v_novas int := 0; v_dup int := 0; l jsonb; v_chave text; v_ord int; v_val numeric;
  v_ini date; v_fim date; v_conta record;
begin
  select * into v_conta from fin.contas where id = p_conta and ativo;
  if v_conta is null then raise exception 'conta % inexistente ou inativa', p_conta; end if;
  select id into v_imp from fin.importacoes where conta_id = p_conta and arquivo_sha256 = p_arquivo_sha256;
  if v_imp is not null then
    return jsonb_build_object('importacao', v_imp, 'ja_importado', true);
  end if;

  select min((x->>'data')::date), max((x->>'data')::date) into v_ini, v_fim from jsonb_array_elements(p_linhas) x;
  insert into fin.importacoes (conta_id, arquivo_sha256, formato, periodo_inicio, periodo_fim, saldo_inicial, saldo_final,
    linhas, importado_por)
  values (p_conta, p_arquivo_sha256, p_formato, v_ini, v_fim, p_saldo_inicial, p_saldo_final, jsonb_array_length(p_linhas), p_importado_por)
  returning id into v_imp;

  for l, v_ord in
    select x, row_number() over (partition by x->>'data', x->>'valor', x->>'descricao' order by ord)::int
    from jsonb_array_elements(p_linhas) with ordinality as t(x, ord) order by ord
  loop
    v_val := (l->>'valor')::numeric;
    if v_val = 0 then continue; end if;
    -- chave: ID do banco quando existe; senão data|valor|descrição|ordinal entre linhas idênticas no mesmo dia
    v_chave := coalesce(nullif(l->>'documento',''),
      md5((l->>'data') || '|' || v_val::text || '|' || (l->>'descricao') || '|' || v_ord));
    insert into fin.movimentos (conta_id, data, sentido, valor, descricao, documento_banco, saldo_apos, chave_dedup, importacao_id)
    values (p_conta, (l->>'data')::date, case when v_val > 0 then 'credito' else 'debito' end, abs(v_val),
            l->>'descricao', nullif(l->>'documento',''), (l->>'saldo')::numeric, v_chave, v_imp)
    on conflict (conta_id, chave_dedup) do nothing;
    if found then v_novas := v_novas + 1; else v_dup := v_dup + 1; end if;
  end loop;

  update fin.importacoes set novas = v_novas, duplicadas = v_dup where id = v_imp;
  perform core.auditar(null, p_importado_por, 'extrato_importado', 'fin.conta', p_conta, null,
    jsonb_build_object('importacao', v_imp, 'linhas', jsonb_array_length(p_linhas), 'novas', v_novas, 'duplicadas', v_dup));

  -- saldo informado pelo banco tem de fechar com as linhas do arquivo
  if p_saldo_inicial is not null and p_saldo_final is not null and
     p_saldo_inicial + (select coalesce(sum((x->>'valor')::numeric),0) from jsonb_array_elements(p_linhas) x) <> p_saldo_final then
    perform fin.abrir_pendencia('saldo_divergente', v_conta.unidade_id, null, null,
      jsonb_build_object('importacao', v_imp, 'saldo_inicial', p_saldo_inicial, 'saldo_final', p_saldo_final));
  end if;
  return jsonb_build_object('importacao', v_imp, 'novas', v_novas, 'duplicadas', v_dup, 'ja_importado', false);
end $$;

-- ---------------------------------------------------------------------------
-- 9. Conciliação automática (critérios fixos e testados)
--   R1 id_bancario: lançamento.documento_banco = movimento.documento_banco, mesmo valor e sentido
--   R2 valor_data_unico: mesmo valor e sentido, mesma conta (ou lançamento sem conta da mesma unidade),
--      |data| ≤ janela, e o par é ÚNICO nos dois sentidos. Senão → pendência de ambiguidade.
--   Valor diferente nunca concilia. Nada é alterado no valor.
-- ---------------------------------------------------------------------------
create or replace function fin.conciliar(p_conta text, p_ator text) returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare m record; c record; v_conta record; v_jan int; n_id int := 0; n_val int := 0; n_amb int := 0; v_qtd int; v_lanc uuid;
begin
  select * into v_conta from fin.contas where id = p_conta;
  v_jan := fin.cfg('fin.janela_conciliacao_dias', '3')::int;

  for m in select * from fin.movimentos where conta_id = p_conta and status = 'pendente' order by data, criado_em for update skip locked loop
    -- R1
    v_lanc := null;
    if m.documento_banco is not null then
      select id into v_lanc from fin.lancamentos l
       where l.documento_banco = m.documento_banco and l.valor = m.valor
         and l.sentido = case m.sentido when 'credito' then 'entrada' else 'saida' end
         and l.status in ('pendente','confirmado') and not exists (select 1 from fin.conciliacoes x where x.lancamento_id = l.id)
       limit 1;
      if v_lanc is not null then
        insert into fin.conciliacoes (movimento_id, lancamento_id, valor, regra, confirmado_por) values (m.id, v_lanc, m.valor, 'id_bancario', p_ator);
        update fin.lancamentos set status = 'conciliado', conta_id = coalesce(conta_id, p_conta), data_caixa = m.data where id = v_lanc;
        update fin.movimentos set status = 'conciliado' where id = m.id;
        n_id := n_id + 1; continue;
      end if;
    end if;

    -- R2: candidatos
    select count(*), min(l.id::text)::uuid into v_qtd, v_lanc from fin.lancamentos l
     where l.valor = m.valor and l.sentido = case m.sentido when 'credito' then 'entrada' else 'saida' end
       and l.status in ('pendente','confirmado') and not exists (select 1 from fin.conciliacoes x where x.lancamento_id = l.id)
       and (l.conta_id = p_conta or (l.conta_id is null and l.unidade_id = v_conta.unidade_id))
       and not exists (select 1 from fin.lancamentos rb where rb.original_id = l.id and rb.status <> 'cancelado')
       and abs(coalesce(l.data_caixa, l.data_competencia) - m.data) <= v_jan
       and (l.documento_banco is null or m.documento_banco is null);   -- IDs diferentes ≠ mesma operação
    if v_qtd = 1 then
      -- unicidade no sentido inverso: o lançamento não pode servir a outro movimento pendente igual
      if (select count(*) from fin.movimentos m2 where m2.conta_id = p_conta and m2.status = 'pendente'
            and m2.valor = m.valor and m2.sentido = m.sentido
            and abs(m2.data - (select coalesce(data_caixa, data_competencia) from fin.lancamentos where id = v_lanc)) <= v_jan) = 1 then
        insert into fin.conciliacoes (movimento_id, lancamento_id, valor, regra, confirmado_por) values (m.id, v_lanc, m.valor, 'valor_data_unico', p_ator);
        update fin.lancamentos set status = 'conciliado', conta_id = coalesce(conta_id, p_conta), data_caixa = m.data where id = v_lanc;
        update fin.movimentos set status = 'conciliado' where id = m.id;
        n_val := n_val + 1; continue;
      end if;
    end if;
    if v_qtd >= 1 then
      perform fin.abrir_pendencia('ambiguidade', v_conta.unidade_id, m.id, null,
        jsonb_build_object('candidatos', v_qtd, 'valor', m.valor, 'data', m.data));
      n_amb := n_amb + 1;
    end if;
  end loop;

  -- valores próximos mas diferentes (mesma contraparte/ID) viram divergência explícita
  for c in
    select mv.id mov, l.id lanc, mv.valor vm, l.valor vl from fin.movimentos mv join fin.lancamentos l
      on l.documento_banco = mv.documento_banco and l.valor <> mv.valor
     where mv.conta_id = p_conta and mv.status = 'pendente' and l.status in ('pendente','confirmado')
  loop
    update fin.movimentos set status = 'divergente' where id = c.mov;
    update fin.lancamentos set status = 'contestado', motivo = 'valor do comprovante difere do extrato' where id = c.lanc;
    perform fin.abrir_pendencia('divergencia', v_conta.unidade_id, c.mov, c.lanc,
      jsonb_build_object('valor_extrato', c.vm, 'valor_lancamento', c.vl));
  end loop;

  return jsonb_build_object('por_id', n_id, 'por_valor_data', n_val, 'ambiguos', n_amb);
end $$;

-- Conciliação manual (humana): mesmo valor obrigatório
create or replace function fin.conciliar_manual(p_movimento uuid, p_lancamentos uuid[], p_ator uuid, p_motivo text) returns void
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare m record; v_soma numeric; l uuid;
begin
  if not exists (select 1 from core.principais where id = p_ator and tipo = 'usuario' and ativo) then
    raise exception 'conciliação manual é humana' using errcode = '42501';
  end if;
  select * into m from fin.movimentos where id = p_movimento for update;
  select sum(valor) into v_soma from fin.lancamentos where id = any(p_lancamentos);
  if v_soma is distinct from m.valor then
    raise exception 'lançamentos somam % e o movimento vale %: não se força conciliação', v_soma, m.valor;
  end if;
  foreach l in array p_lancamentos loop
    insert into fin.conciliacoes (movimento_id, lancamento_id, valor, regra, confirmado_por)
    select m.id, id, valor, 'manual', p_ator::text from fin.lancamentos where id = l;
    update fin.lancamentos set status = 'conciliado', conta_id = coalesce(conta_id, m.conta_id), data_caixa = m.data where id = l;
  end loop;
  update fin.movimentos set status = 'conciliado' where id = p_movimento;
  update fin.pendencias set status = 'resolvida', resolvido_por = p_ator, resolucao = p_motivo, resolvido_em = now()
   where movimento_id = p_movimento and status = 'aberta';
  perform core.auditar(p_ator, null, 'conciliacao_manual', 'fin.movimento', p_movimento::text, null,
    jsonb_build_object('lancamentos', p_lancamentos), p_motivo);
end $$;

-- Movimentos do extrato que sobraram viram lançamentos pelas regras de classificação.
-- Sem regra → lançamento sem categoria + pendência de classificação (nunca chuta).
create or replace function fin.lancar_do_extrato(p_conta text, p_ator text) returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare m record; r record; v_conta record; v_l uuid; n_cls int := 0; n_sem int := 0; v_dest record; v_par uuid;
begin
  select * into v_conta from fin.contas where id = p_conta;
  for m in select * from fin.movimentos where conta_id = p_conta and status = 'pendente'
            and not exists (select 1 from fin.pendencias p where p.movimento_id = fin.movimentos.id and p.status = 'aberta')
           order by data for update skip locked loop
    -- há lançamento de mesmo valor/sentido ainda sem conciliação perto da data? não cria outro: pede revisão
    if exists (select 1 from fin.lancamentos l
                where l.valor = m.valor and l.sentido = case m.sentido when 'credito' then 'entrada' else 'saida' end
                  and l.status in ('pendente','confirmado') and l.unidade_id = v_conta.unidade_id
                  and not exists (select 1 from fin.conciliacoes x where x.lancamento_id = l.id)
                  and not exists (select 1 from fin.lancamentos rb where rb.original_id = l.id and rb.status <> 'cancelado')
                  and abs(coalesce(l.data_caixa, l.data_competencia) - m.data) <= 31) then
      perform fin.abrir_pendencia('ambiguidade', v_conta.unidade_id, m.id, null,
        jsonb_build_object('motivo','existe lançamento de mesmo valor fora da janela de conciliação','valor', m.valor,'data', m.data));
      continue;
    end if;
    r := null;
    select * into r from fin.regras_classificacao
     where status = 'ativa' and m.descricao ilike '%' || padrao || '%' and (sentido is null or sentido = m.sentido)
     order by prioridade, id limit 1;

    if r.natureza = 'transferencia_unidades' and r.unidade_destino is not null then
      -- só a perna desta conta é conhecida; a outra perna fica como pendência até o extrato da outra unidade
      v_l := gen_random_uuid();
      insert into fin.lancamentos (id, natureza, sentido, valor, unidade_id, conta_id, descricao, data_competencia, data_caixa,
        status, origem, par_id, criado_por)
      values (v_l, 'transferencia_unidades', case m.sentido when 'credito' then 'entrada' else 'saida' end, m.valor,
        v_conta.unidade_id, p_conta, m.descricao, m.data, m.data, 'conciliado', 'extrato', v_l, p_ator);
      perform fin.abrir_pendencia('transferencia_sem_par', v_conta.unidade_id, m.id, v_l,
        jsonb_build_object('unidade_contraparte', r.unidade_destino), false);
    elsif r.id is not null then
      insert into fin.lancamentos (natureza, sentido, valor, unidade_id, conta_id, categoria_id, descricao,
        data_competencia, data_caixa, status, origem, criado_por)
      values (r.natureza, case m.sentido when 'credito' then 'entrada' else 'saida' end, m.valor, v_conta.unidade_id,
        p_conta, r.categoria_id, m.descricao, m.data, m.data, 'conciliado', 'extrato', p_ator) returning id into v_l;
      n_cls := n_cls + 1;
    else
      insert into fin.lancamentos (natureza, sentido, valor, unidade_id, conta_id, descricao,
        data_competencia, data_caixa, status, origem, criado_por)
      values (case m.sentido when 'credito' then 'receita' else 'despesa' end,
        case m.sentido when 'credito' then 'entrada' else 'saida' end, m.valor, v_conta.unidade_id, p_conta,
        m.descricao, m.data, m.data, 'pendente', 'extrato', p_ator) returning id into v_l;
      perform fin.abrir_pendencia('sem_classificacao', v_conta.unidade_id, m.id, v_l, jsonb_build_object('descricao', m.descricao));
      n_sem := n_sem + 1;
    end if;
    insert into fin.conciliacoes (movimento_id, lancamento_id, valor, regra, confirmado_por) values (m.id, v_l, m.valor, 'extrato', p_ator);
    update fin.lancamentos set status = 'conciliado' where id = v_l and status <> 'conciliado';
    update fin.movimentos set status = 'conciliado' where id = m.id;
  end loop;
  return jsonb_build_object('classificados', n_cls, 'sem_classificacao', n_sem);
end $$;

-- Pagamento da fatura do cartão: lançamento de caixa, não despesa (evita contar duas vezes)
create or replace function fin.pagar_fatura(p_fatura uuid, p_conta_pagadora text, p_valor numeric, p_data date, p_ator text)
returns uuid
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare f record; v_id uuid; v_un text;
begin
  select * into f from fin.faturas_cartao where id = p_fatura for update;
  select unidade_id into v_un from fin.contas where id = p_conta_pagadora;
  insert into fin.lancamentos (natureza, sentido, valor, unidade_id, conta_id, descricao, data_competencia, data_caixa,
    status, origem, criado_por)
  values ('pagamento_fatura', 'saida', p_valor, v_un, p_conta_pagadora, 'Pagamento fatura ' || f.conta_id || ' ' || to_char(f.competencia,'MM/YYYY'),
    f.competencia, p_data, 'pendente', 'manual', p_ator) returning id into v_id;
  update fin.faturas_cartao set pagamento_id = v_id,
    status = case when p_valor = f.valor_total then 'paga' else 'divergente' end where id = p_fatura;
  if p_valor <> f.valor_total then
    perform fin.abrir_pendencia('fatura_divergente', v_un, null, v_id,
      jsonb_build_object('fatura', p_fatura, 'soma_compras', f.valor_total, 'pago', p_valor));
  end if;
  return v_id;
end $$;

-- Reembolso: liga ao original; DRE fica com o original, caixa com o reembolso
create or replace function fin.registrar_reembolso(p_original uuid, p_sentido text, p_valor numeric, p_data date,
  p_conta text, p_ator text) returns uuid
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare o record; v_id uuid; v_ja numeric;
begin
  select * into o from fin.lancamentos where id = p_original;
  if o is null or o.natureza <> 'despesa' or o.status = 'cancelado' then raise exception 'reembolso precisa de despesa original ativa'; end if;
  select coalesce(sum(valor),0) into v_ja from fin.lancamentos where original_id = p_original and status <> 'cancelado';
  if v_ja + p_valor > o.valor then raise exception 'reembolsos (%) excedem a despesa original (%)', v_ja + p_valor, o.valor; end if;
  insert into fin.lancamentos (natureza, sentido, valor, unidade_id, conta_id, descricao, data_competencia, data_caixa,
    status, origem, original_id, criado_por)
  values ('reembolso', p_sentido, p_valor, o.unidade_id, p_conta, 'Reembolso #' || o.numero, o.data_competencia, p_data,
    'pendente', 'manual', p_original, p_ator) returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Visões: DRE (competência), caixa (realizado), previsto, pendências
-- ---------------------------------------------------------------------------
-- DRE gerencial por unidade: só receita/despesa confirmadas/conciliadas, não estimadas; rateio redistribui
create or replace view fin.v_dre as
with base as (
  select l.id, l.unidade_id, date_trunc('month', l.data_competencia)::date competencia, l.natureza, l.categoria_id, l.valor
  from fin.lancamentos l
  where l.natureza in ('receita','despesa') and l.status in ('confirmado','conciliado') and not l.estimado
)
select coalesce(ri.unidade_id, b.unidade_id) unidade_id, b.competencia, b.natureza, b.categoria_id,
       sum(coalesce(ri.valor, b.valor)) valor, bool_or(ri.rateio_id is not null) tem_rateio
from base b
left join fin.rateios r on r.lancamento_id = b.id
left join fin.rateio_itens ri on ri.rateio_id = r.id
group by 1,2,3,4;

-- Caixa realizado por conta: só o que está CONCILIADO com o extrato (ou confirmado em conta caixa físico).
-- Cartão de crédito não é caixa: quem sai do caixa é o pagamento da fatura.
create or replace view fin.v_caixa_conta as
select l.conta_id, c.unidade_id, l.data_caixa data, l.natureza,
       sum(case when l.sentido = 'entrada' then l.valor else 0 end) entradas,
       sum(case when l.sentido = 'saida' then l.valor else 0 end) saidas
from fin.lancamentos l join fin.contas c on c.id = l.conta_id
where c.tipo <> 'cartao_credito'
  and (l.status = 'conciliado' or (l.status = 'confirmado' and c.tipo = 'caixa'))
group by 1,2,3,4;

-- Caixa por unidade: transferência interna não conta; entre unidades conta (é dinheiro entrando/saindo da unidade)
create or replace view fin.v_caixa_unidade as
select unidade_id, data, sum(entradas) entradas, sum(saidas) saidas
from fin.v_caixa_conta where natureza <> 'transferencia_interna'
group by 1,2;

-- Consolidado do grupo: nenhuma transferência conta (dinheiro não sai do grupo)
create or replace view fin.v_caixa_consolidado as
select data, sum(entradas) entradas, sum(saidas) saidas
from fin.v_caixa_conta where natureza not in ('transferencia_interna','transferencia_unidades')
group by 1;

create or replace view fin.v_previsto as
select unidade_id, conta_id, data_caixa data, natureza, sentido, valor, estimado, descricao
from fin.lancamentos where status = 'previsto';

create or replace view fin.v_pendencias as
select p.*, l.numero lancamento_numero, l.valor lancamento_valor, m.valor movimento_valor, m.data movimento_data
from fin.pendencias p
left join fin.lancamentos l on l.id = p.lancamento_id
left join fin.movimentos m on m.id = p.movimento_id
where p.status = 'aberta';

