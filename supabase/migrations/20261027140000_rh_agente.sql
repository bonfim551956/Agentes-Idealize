-- =============================================================================
-- Idealize AI — Agente de RH (v0.1.0)  · Migração 20261027140000
--
-- Primeira versão = PRAZOS e QUADRO, só leitura (Prompt Master §5.2). Lê o Idealize RH 360 por visões sem dados
-- sensíveis (nome, loja, cargo, datas e situação; nunca CPF, endereço, telefone, salário ou conteúdo de documento) e
-- avisa antes dos prazos: fim do contrato de experiência, limite das férias (pagamento em dobro), exame ocupacional
-- vencendo, prazo de acerto do desligamento, tarefa do RH atrasada, jornada acima de 44h ou sem escala e uniforme
-- abaixo do mínimo. Monta a lista do mês para a contabilidade (admissões, desligamentos, férias, mudanças de cargo e
-- salário — sem valores). NÃO calcula folha/rescisão, NÃO decide sobre pessoas e NÃO altera o RH 360.
-- Regras de prazo são as gerais da CLT; convenção coletiva e exceções são encaminhadas ao responsável.
-- Nasce PAUSADO e com a sincronização DESLIGADA (rh.sync.ativo = false).
-- =============================================================================

create schema if not exists rh;
revoke all on schema rh from public;

create or replace function rh._hoje() returns date
language sql stable set search_path = pg_catalog as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create table rh.lojas_origem (               -- código da loja no RH 360 → unidade
  origem     text primary key,
  unidade_id text not null references core.unidades(id)
);
create index rh_lojas_origem_unidade on rh.lojas_origem (unidade_id);
insert into rh.lojas_origem (origem, unidade_id)
select v.o, v.u from (values ('CAMPINAS','campinas'), ('PIRACICABA','piracicaba'), ('SAOVICENTE','sao_vicente'), ('SOROCABA','sorocaba')) v(o, u)
where exists (select 1 from core.unidades where id = v.u);

-- ---------------------------------------------------------------------------
-- 1. Espelho (retrato completo a cada leitura)
-- ---------------------------------------------------------------------------
create table rh.vinculos (
  id               text primary key,
  nome             text not null,
  unidade_id       text references core.unidades(id),
  cargo            text,
  tipo             text not null,
  status           text not null,
  admissao         date,
  desligamento     date,
  jornada_semanal  numeric(5,2),
  escala           text,
  sincronizacao_id uuid
);
create index rh_vinculos_unidade on rh.vinculos (unidade_id);

create table rh.ferias (
  id               text primary key,
  vinculo_id       text not null references rh.vinculos(id) on delete cascade,
  inicio           date not null,
  fim              date not null,
  aquisitivo_inicio date,
  aquisitivo_fim   date,
  programada       boolean not null default false
);
create index rh_ferias_vinculo on rh.ferias (vinculo_id);

create table rh.desligamentos (
  id               text primary key,
  vinculo_id       text not null references rh.vinculos(id) on delete cascade,
  modalidade       text,
  comunicacao      date,
  desligamento     date,
  status           text,
  concluido        boolean not null default false
);
create index rh_desligamentos_vinculo on rh.desligamentos (vinculo_id);

create table rh.tarefas (
  id         text primary key,
  titulo     text not null,
  categoria  text,
  unidade_id text references core.unidades(id),
  prazo      date,
  prioridade text,
  status     text
);
create index rh_tarefas_unidade on rh.tarefas (unidade_id);

create table rh.documentos_vencimento (
  id          text primary key,
  vinculo_id  text references rh.vinculos(id) on delete cascade,
  categoria   text not null,
  vencimento  date not null,
  status      text
);
create index rh_docs_vinculo on rh.documentos_vencimento (vinculo_id);

create table rh.mudancas (
  id          text primary key,
  vinculo_id  text not null references rh.vinculos(id) on delete cascade,
  tipo        text not null check (tipo in ('cargo','salario')),
  data        date not null
);
create index rh_mudancas_vinculo on rh.mudancas (vinculo_id);

create table rh.uniformes (
  id       text primary key,
  peca     text not null,
  tamanho  text,
  minimo   int not null default 0,
  saldo    int not null
);

create table rh.sincronizacoes (
  id                 uuid primary key default gen_random_uuid(),
  tarefa_id          uuid references core.tarefas(id),
  vinculos           int not null,
  ativos             int not null,
  ferias             int not null,
  outros             int not null,
  ignoradas          int not null,
  alertas_abertos    int not null,
  alertas_resolvidos int not null,
  hash_lote          text not null,
  em                 timestamptz not null default now()
);
create index rh_sincronizacoes_tarefa on rh.sincronizacoes (tarefa_id);
create index rh_sincronizacoes_em on rh.sincronizacoes (em desc);

create table rh.alertas (
  id            bigserial primary key,
  tipo          text not null check (tipo in ('fim_experiencia','experiencia_vencida','ferias_limite','ferias_vencidas',
                                              'exame_vencendo','desligamento_prazo','tarefa_atrasada','jornada_irregular','uniforme_baixo')),
  referencia    text not null,
  unidade_id    text references core.unidades(id),
  prazo         date,
  detalhe       jsonb,
  status        text not null default 'aberto' check (status in ('aberto','resolvido')),
  aberto_em     timestamptz not null default now(),
  resolvido_em  timestamptz,
  resolvido_por text
);
create unique index rh_alertas_abertos_uk on rh.alertas (tipo, referencia) where status = 'aberto';
create index rh_alertas_unidade on rh.alertas (unidade_id) where status = 'aberto';

insert into core.config (chave, valor) values
  ('rh.sync.ativo', 'false'),
  ('rh.experiencia_aviso_dias', '10'),     -- avisa N dias antes do fim de cada período da experiência (45 e 90 dias)
  ('rh.ferias_aviso_dias', '90'),          -- avisa N dias antes do limite para conceder as férias
  ('rh.exame_aviso_dias', '30'),
  ('rh.acerto_prazo_dias', '10'),          -- prazo geral do acerto após o término do contrato (CLT art. 477 §6º)
  ('rh.jornada_max_semanal', '44'),
  ('versao_rh', '0.1.0')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Agente, papel, políticas e integração
-- ---------------------------------------------------------------------------
insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('rh', 'Agente de RH', 'rh', 'pausado', '0.1.0',
   'Avisa os prazos de RH das lojas (experiência, férias, exames, acertos, tarefas), mostra o quadro por loja e monta a lista do mês para a contabilidade. Só leitura: não calcula folha, não decide sobre pessoas e não altera o RH 360.')
on conflict (id) do nothing;
insert into core.papeis (id, nome) values ('agente_rh', 'Agente de RH (máquina)') on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', 'Agente de RH', 'rh' where not exists (select 1 from core.principais where agente_id = 'rh');
insert into core.principal_papeis (principal_id, papel_id)
select id, 'agente_rh' from core.principais where agente_id = 'rh' on conflict do nothing;
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_rh', 'rh.pessoas', 'sincronizar', 'baixo', 'automatica'
where not exists (select 1 from core.politicas where papel_id = 'agente_rh' and recurso = 'rh.pessoas' and operacao = 'sincronizar' and ativo);
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_rh', 'rh.pessoas', v.op, 'alto', 'proibida'
from (values ('desligar'), ('advertir'), ('alterar_salario'), ('alterar_cargo'), ('efetivar'), ('conceder_ferias'),
             ('calcular_rescisao'), ('enviar_mensagem'), ('alterar_cadastro'), ('excluir')) v(op)
where not exists (select 1 from core.politicas where papel_id = 'agente_rh' and recurso = 'rh.pessoas' and operacao = v.op and ativo);
insert into core.integracoes (id, nome, status, credencial_leitura, observacoes) values
  ('rh360', 'Idealize RH 360', 'nao_verificada', 'RH_LEITURA_DB_URL',
   'Visões idealize_ai.rh_* (nome, loja, cargo, datas; sem CPF, endereço, salário ou documentos), usuário só leitura.')
on conflict (id) do nothing;

create or replace function rh._cfg_int(p_chave text, p_padrao int) returns int
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(nullif(core.cfg(p_chave, p_padrao::text), '')::int, p_padrao)
$$;

-- Períodos aquisitivos completos de cada pessoa ativa, com o limite para conceder e os dias já registrados
create or replace view rh.v_periodos_ferias with (security_invoker = true) as
select v.id as vinculo_id, v.nome, v.unidade_id, p.n,
       (v.admissao + make_interval(years => p.n - 1))::date as aquisitivo_inicio,
       (v.admissao + make_interval(years => p.n) - interval '1 day')::date as aquisitivo_fim,
       (v.admissao + make_interval(years => p.n + 1) - interval '1 day')::date as limite_concessao,
       coalesce((select sum(f.fim - f.inicio + 1) from rh.ferias f
                 where f.vinculo_id = v.id and f.aquisitivo_inicio = (v.admissao + make_interval(years => p.n - 1))::date), 0) as dias_registrados,
       coalesce((select sum(f.fim - f.inicio + 1) from rh.ferias f
                 where f.vinculo_id = v.id and f.aquisitivo_inicio = (v.admissao + make_interval(years => p.n - 1))::date
                   and f.inicio > (v.admissao + make_interval(years => p.n + 1) - interval '1 day')::date), 0) as dias_fora_do_prazo
from rh.vinculos v
cross join lateral generate_series(1, greatest(0, (extract(year from age(rh._hoje(), v.admissao)))::int)) p(n)
where v.admissao is not null and v.status in ('ativo','em_ferias','afastado','em_licenca') and v.tipo like 'clt%';

-- ---------------------------------------------------------------------------
-- 3. Alertas (recalculados para o estado inteiro; resolvem sozinhos)
-- ---------------------------------------------------------------------------
create or replace function rh.recalcular() returns jsonb
language plpgsql security definer set search_path = rh, core, pg_catalog as $$
declare d date := rh._hoje(); v_exp int := rh._cfg_int('rh.experiencia_aviso_dias', 10);
  v_fer int := rh._cfg_int('rh.ferias_aviso_dias', 90); v_exa int := rh._cfg_int('rh.exame_aviso_dias', 30);
  v_ace int := rh._cfg_int('rh.acerto_prazo_dias', 10); v_jor int := rh._cfg_int('rh.jornada_max_semanal', 44);
  n_ab int; n_res int;
begin
  drop table if exists _devidos;
  create temp table _devidos (tipo text, referencia text, unidade_id text, prazo date, detalhe jsonb) on commit drop;

  -- contrato de experiência: fim do 1º período (45 dias) e do total (90 dias)
  insert into _devidos
  select 'fim_experiencia', 'vinculo:' || v.id || ':' || m.dias, v.unidade_id, (v.admissao + m.dias - 1),
         jsonb_build_object('nome', v.nome, 'cargo', v.cargo, 'marco_dias', m.dias, 'admissao', v.admissao, 'termina', v.admissao + m.dias - 1)
  from rh.vinculos v cross join (values (45), (90)) m(dias)
  where v.tipo = 'clt_experiencia' and v.status in ('ativo','em_ferias','afastado','em_licenca') and v.admissao is not null
    and (v.admissao + m.dias - 1) between d and d + v_exp;
  insert into _devidos
  select 'experiencia_vencida', 'vinculo:' || v.id, v.unidade_id, (v.admissao + 89),
         jsonb_build_object('nome', v.nome, 'cargo', v.cargo, 'admissao', v.admissao, 'terminou', v.admissao + 89)
  from rh.vinculos v
  where v.tipo = 'clt_experiencia' and v.status in ('ativo','em_ferias','afastado','em_licenca') and v.admissao + 89 < d;

  -- férias: período aquisitivo completo com dias faltando e limite chegando (ou já passado)
  insert into _devidos
  select case when p.limite_concessao < d then 'ferias_vencidas' else 'ferias_limite' end,
         'vinculo:' || p.vinculo_id || ':' || p.aquisitivo_inicio, p.unidade_id, p.limite_concessao,
         jsonb_build_object('nome', p.nome, 'aquisitivo_inicio', p.aquisitivo_inicio, 'aquisitivo_fim', p.aquisitivo_fim,
                            'limite', p.limite_concessao, 'dias_registrados', p.dias_registrados, 'dias_faltando', 30 - p.dias_registrados)
  from rh.v_periodos_ferias p
  where p.aquisitivo_fim < d and p.dias_registrados < 30 and p.limite_concessao <= d + v_fer;
  -- férias registradas fora do prazo (já gozadas depois do limite): pagamento em dobro a conferir
  insert into _devidos
  select 'ferias_vencidas', 'vinculo:' || p.vinculo_id || ':' || p.aquisitivo_inicio || ':fora', p.unidade_id, p.limite_concessao,
         jsonb_build_object('nome', p.nome, 'aquisitivo_inicio', p.aquisitivo_inicio, 'aquisitivo_fim', p.aquisitivo_fim,
                            'limite', p.limite_concessao, 'dias_fora_do_prazo', p.dias_fora_do_prazo)
  from rh.v_periodos_ferias p where p.dias_fora_do_prazo > 0 and p.limite_concessao >= d - 365;

  -- exame ocupacional (e outros documentos com validade) vencendo ou vencido
  insert into _devidos
  select 'exame_vencendo', 'documento:' || dv.id, v.unidade_id, dv.vencimento,
         jsonb_build_object('nome', v.nome, 'categoria', dv.categoria, 'vencimento', dv.vencimento, 'vencido', dv.vencimento < d)
  from rh.documentos_vencimento dv join rh.vinculos v on v.id = dv.vinculo_id
  where v.status not in ('desligado','arquivado') and coalesce(dv.status, '') not in ('arquivado')
    and dv.vencimento <= d + v_exa
    and not exists (select 1 from rh.documentos_vencimento n where n.vinculo_id = dv.vinculo_id and n.categoria = dv.categoria and n.vencimento > dv.vencimento);

  -- desligamento sem acerto concluído perto do prazo legal
  insert into _devidos
  select 'desligamento_prazo', 'desligamento:' || dl.id, v.unidade_id, dl.desligamento + v_ace,
         jsonb_build_object('nome', v.nome, 'modalidade', dl.modalidade, 'desligamento', dl.desligamento, 'prazo_acerto', dl.desligamento + v_ace)
  from rh.desligamentos dl join rh.vinculos v on v.id = dl.vinculo_id
  where not dl.concluido and dl.desligamento is not null and dl.desligamento + v_ace <= d + 3;

  -- tarefa do RH 360 atrasada
  insert into _devidos
  select 'tarefa_atrasada', 'tarefa:' || t.id, t.unidade_id, t.prazo,
         jsonb_build_object('titulo', t.titulo, 'categoria', t.categoria, 'prazo', t.prazo, 'prioridade', t.prioridade)
  from rh.tarefas t
  where t.prazo < d and coalesce(lower(t.status), '') not in ('concluida','concluída','cancelada','feito','concluido');

  -- jornada acima do limite, sem jornada ou sem escala definida
  insert into _devidos
  select 'jornada_irregular', 'vinculo:' || v.id, v.unidade_id, null,
         jsonb_build_object('nome', v.nome, 'cargo', v.cargo, 'jornada', v.jornada_semanal, 'escala', v.escala,
                            'motivo', case when v.jornada_semanal > v_jor then 'acima' when v.jornada_semanal is null then 'sem_jornada' else 'sem_escala' end)
  from rh.vinculos v
  where v.status in ('ativo','em_ferias','afastado','em_licenca') and v.tipo like 'clt%'
    and (v.jornada_semanal > v_jor or v.jornada_semanal is null or coalesce(btrim(v.escala), '') in ('', 'DAS 00:00 AS 00:00'));

  -- uniforme abaixo do estoque mínimo
  insert into _devidos
  select 'uniforme_baixo', 'uniforme:' || u.id, null, null,
         jsonb_build_object('peca', u.peca, 'tamanho', u.tamanho, 'saldo', u.saldo, 'minimo', u.minimo)
  from rh.uniformes u where u.saldo < u.minimo;

  insert into rh.alertas (tipo, referencia, unidade_id, prazo, detalhe)
  select tipo, referencia, unidade_id, prazo, detalhe from _devidos
  on conflict (tipo, referencia) where status = 'aberto'
  do update set detalhe = excluded.detalhe, unidade_id = excluded.unidade_id, prazo = excluded.prazo;
  get diagnostics n_ab = row_count;

  update rh.alertas a set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente_rh: situação deixou de existir'
   where a.status = 'aberto' and not exists (select 1 from _devidos x where x.tipo = a.tipo and x.referencia = a.referencia);
  get diagnostics n_res = row_count;
  return jsonb_build_object('ativos', n_ab, 'resolvidos', n_res);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Aplicação de um lote — retrato completo do RH 360
-- Formato: {vinculos:[{vinculo_id,nome,loja,cargo,tipo,status,data_admissao,data_desligamento,jornada_semanal_horas,escala}],
--   ferias:[{id,vinculo_id,inicio,fim,aquisitivo_inicio,aquisitivo_fim,programada}],
--   desligamentos:[{id,vinculo_id,modalidade,data_comunicacao,data_desligamento,status,concluido_em}],
--   tarefas:[{id,titulo,categoria,loja,prazo,prioridade,status}], documentos:[{id,vinculo_id,categoria,vencimento,status}],
--   mudancas:[{id,vinculo_id,tipo,data}], uniformes:[{id,peca,tamanho,estoque_minimo,saldo}]}
-- ---------------------------------------------------------------------------
create or replace function rh.aplicar_lote(p_tarefa uuid, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = rh, core, pg_catalog as $$
declare v_s uuid := gen_random_uuid(); n_v int; n_f int; n_o int := 0; n int; n_ign int; v_al jsonb;
begin
  if jsonb_typeof(p_lote) is distinct from 'object' or jsonb_typeof(p_lote->'vinculos') is distinct from 'array' then
    raise exception 'lote sem vínculos do RH 360';
  end if;
  if jsonb_array_length(p_lote->'vinculos') = 0 and exists (select 1 from rh.vinculos) then
    raise exception 'lote veio vazio e o espelho tem pessoas: leitura suspeita, nada foi apagado';
  end if;

  delete from rh.mudancas; delete from rh.documentos_vencimento; delete from rh.desligamentos; delete from rh.ferias;
  delete from rh.vinculos; delete from rh.tarefas; delete from rh.uniformes;

  insert into rh.vinculos (id, nome, unidade_id, cargo, tipo, status, admissao, desligamento, jornada_semanal, escala, sincronizacao_id)
  select r.vinculo_id, left(btrim(r.nome), 120), o.unidade_id, left(r.cargo, 80), lower(r.tipo), lower(r.status), r.data_admissao,
         r.data_desligamento, r.jornada_semanal_horas, left(r.escala, 120), v_s
  from jsonb_to_recordset(p_lote->'vinculos') r(vinculo_id text, nome text, loja text, cargo text, tipo text, status text,
    data_admissao date, data_desligamento date, jornada_semanal_horas numeric, escala text)
  left join rh.lojas_origem o on o.origem = upper(r.loja)
  where coalesce(r.vinculo_id, '') ~ '^[A-Za-z0-9_-]{1,64}$' and coalesce(btrim(r.nome), '') <> '' and r.tipo is not null and r.status is not null
  on conflict (id) do nothing;
  get diagnostics n_v = row_count;
  n_ign := jsonb_array_length(p_lote->'vinculos') - n_v;

  insert into rh.ferias (id, vinculo_id, inicio, fim, aquisitivo_inicio, aquisitivo_fim, programada)
  select r.id, r.vinculo_id, r.inicio, r.fim, r.aquisitivo_inicio, r.aquisitivo_fim, coalesce(r.programada, false)
  from jsonb_to_recordset(coalesce(p_lote->'ferias', '[]')) r(id text, vinculo_id text, inicio date, fim date, aquisitivo_inicio date,
    aquisitivo_fim date, programada boolean)
  where exists (select 1 from rh.vinculos v where v.id = r.vinculo_id) and r.inicio is not null and r.fim >= r.inicio and r.fim - r.inicio < 60
  on conflict (id) do nothing;
  get diagnostics n_f = row_count;

  insert into rh.desligamentos (id, vinculo_id, modalidade, comunicacao, desligamento, status, concluido)
  select r.id, r.vinculo_id, left(r.modalidade, 40), r.data_comunicacao, r.data_desligamento, left(r.status, 30),
         r.concluido_em is not null or lower(coalesce(r.status, '')) in ('concluido','concluído','finalizado')
  from jsonb_to_recordset(coalesce(p_lote->'desligamentos', '[]')) r(id text, vinculo_id text, modalidade text, data_comunicacao date,
    data_desligamento date, status text, concluido_em timestamptz)
  where exists (select 1 from rh.vinculos v where v.id = r.vinculo_id) on conflict (id) do nothing;
  get diagnostics n = row_count; n_o := n_o + n;

  insert into rh.tarefas (id, titulo, categoria, unidade_id, prazo, prioridade, status)
  select r.id, left(btrim(r.titulo), 200), left(r.categoria, 40), o.unidade_id, r.prazo, left(r.prioridade, 20), left(r.status, 30)
  from jsonb_to_recordset(coalesce(p_lote->'tarefas', '[]')) r(id text, titulo text, categoria text, loja text, prazo date, prioridade text, status text)
  left join rh.lojas_origem o on o.origem = upper(r.loja)
  where coalesce(r.id, '') <> '' and coalesce(btrim(r.titulo), '') <> '' on conflict (id) do nothing;
  get diagnostics n = row_count; n_o := n_o + n;

  insert into rh.documentos_vencimento (id, vinculo_id, categoria, vencimento, status)
  select r.id, r.vinculo_id, left(r.categoria, 40), r.vencimento, left(r.status, 30)
  from jsonb_to_recordset(coalesce(p_lote->'documentos', '[]')) r(id text, vinculo_id text, categoria text, vencimento date, status text)
  where exists (select 1 from rh.vinculos v where v.id = r.vinculo_id) and r.vencimento is not null and r.categoria is not null
  on conflict (id) do nothing;
  get diagnostics n = row_count; n_o := n_o + n;

  insert into rh.mudancas (id, vinculo_id, tipo, data)
  select r.id, r.vinculo_id, r.tipo, r.data
  from jsonb_to_recordset(coalesce(p_lote->'mudancas', '[]')) r(id text, vinculo_id text, tipo text, data date)
  where exists (select 1 from rh.vinculos v where v.id = r.vinculo_id) and r.tipo in ('cargo','salario') and r.data is not null
  on conflict (id) do nothing;
  get diagnostics n = row_count; n_o := n_o + n;

  insert into rh.uniformes (id, peca, tamanho, minimo, saldo)
  select r.id, left(r.peca, 80), left(r.tamanho, 20), coalesce(r.estoque_minimo, 0), coalesce(r.saldo, 0)
  from jsonb_to_recordset(coalesce(p_lote->'uniformes', '[]')) r(id text, peca text, tamanho text, estoque_minimo int, saldo int)
  where coalesce(r.id, '') <> '' and coalesce(r.peca, '') <> '' on conflict (id) do nothing;
  get diagnostics n = row_count; n_o := n_o + n;

  v_al := rh.recalcular();
  insert into rh.sincronizacoes (id, tarefa_id, vinculos, ativos, ferias, outros, ignoradas, alertas_abertos, alertas_resolvidos, hash_lote)
  values (v_s, p_tarefa, n_v, (select count(*) from rh.vinculos where status in ('ativo','em_ferias','afastado','em_licenca')), n_f, n_o, n_ign,
    (v_al->>'ativos')::int, (v_al->>'resolvidos')::int, md5(p_lote::text));
  return jsonb_build_object('sincronizacao', v_s, 'vinculos', n_v, 'ferias', n_f, 'outros', n_o, 'ignoradas', n_ign,
    'alertas', v_al, 'hash_lote', md5(p_lote::text));
end $$;

create or replace function rh.concluir_sincronizacao(p_tarefa uuid, p_executor text, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = rh, core, pg_catalog as $$
declare t record; v jsonb;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'rh' or t.tipo is distinct from 'rh_sincronizacao' then raise exception 'tarefa não é sincronização do RH'; end if;
  v := rh.aplicar_lote(p_tarefa, p_lote);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', v->>'hash_lote', v);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Validador independente
-- ---------------------------------------------------------------------------
create or replace function rh.validar_sincronizacao(p_tarefa uuid, p_validador text) returns text
language plpgsql security definer set search_path = rh, core, pg_catalog as $$
declare t record; s record; v_erros text[] := '{}'; n int; d date := rh._hoje();
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  select * into s from rh.sincronizacoes where tarefa_id = p_tarefa order by em desc limit 1;
  if s.id is null then
    v_erros := v_erros || 'sincronização sem registro';
  else
    select count(*) into n from rh.vinculos where sincronizacao_id = s.id;
    if n <> s.vinculos then v_erros := v_erros || format('espelho tem %s vínculos, registro diz %s', n, s.vinculos); end if;
    select count(*) into n from rh.vinculos where unidade_id is null and status in ('ativo','em_ferias','afastado','em_licenca');
    if n > 0 then v_erros := v_erros || format('%s pessoas ativas sem loja reconhecida', n); end if;
    -- completude, com conta própria: toda experiência vencida tem alerta
    select count(*) into n from rh.vinculos v
     where v.tipo = 'clt_experiencia' and v.status in ('ativo','em_ferias','afastado','em_licenca') and v.admissao + 89 < d
       and not exists (select 1 from rh.alertas a where a.tipo = 'experiencia_vencida' and a.status = 'aberto' and a.referencia = 'vinculo:' || v.id);
    if n > 0 then v_erros := v_erros || format('%s experiências vencidas sem alerta', n); end if;
  end if;
  if array_length(v_erros, 1) is null then
    return core.registrar_validacao(p_tarefa, p_validador, true, null, jsonb_build_object('sincronizacao', s.id));
  end if;
  return core.registrar_validacao(p_tarefa, p_validador, false, array_to_string(v_erros, '; '),
    jsonb_build_object('sincronizacao', s.id, 'erros', to_jsonb(v_erros)));
end $$;

-- Uma leitura por dia, de manhã
create or replace function rh.agendar_sincronizacao() returns uuid
language plpgsql security definer set search_path = rh, core, pg_catalog as $$
declare v_p uuid;
begin
  if core.cfg('rh.sync.ativo', 'false') <> 'true' then return null; end if;
  select id into v_p from core.principais where agente_id = 'rh';
  return core.criar_tarefa(v_p, 'rh', 'rh_sincronizacao', 'rh.pessoas', 'sincronizar', null,
    jsonb_build_object('origem', 'rh360'), 'rh:sync:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDD'), null, 6);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Painel
-- ---------------------------------------------------------------------------
create or replace function public.painel_rh(p_unidade text default null, p_mes date default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[]; g boolean; d date := rh._hoje(); m0 date; m1 date;
begin
  v_eu := painel._entrar('rh', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; g := false; end if;
  m0 := date_trunc('month', coalesce(p_mes, d))::date; m1 := (m0 + interval '1 month')::date;
  return jsonb_build_object(
    'hoje', d, 'mes', m0,
    'sincronizacao', jsonb_build_object('ativa', core.cfg('rh.sync.ativo', 'false') = 'true',
       'agente', (select status from core.agentes where id = 'rh'),
       'ultima', (select jsonb_build_object('em', em, 'vinculos', vinculos, 'ativos', ativos) from rh.sincronizacoes order by em desc limit 1)),
    'quadro', (select coalesce(jsonb_agg(x order by x->>'unidade_id'), '[]'::jsonb) from (
      select jsonb_build_object('unidade_id', v.unidade_id,
        'ativos', count(*) filter (where v.status in ('ativo','em_ferias','afastado','em_licenca')),
        'em_experiencia', count(*) filter (where v.tipo = 'clt_experiencia' and v.status in ('ativo','em_ferias','afastado','em_licenca')),
        'em_ferias', count(*) filter (where v.status = 'em_ferias'),
        'afastados', count(*) filter (where v.status in ('afastado','em_licenca')),
        'em_admissao', count(*) filter (where v.status in ('pre_admissao','em_admissao')),
        'admitidos_mes', count(*) filter (where v.admissao >= m0 and v.admissao < m1),
        'desligados_mes', count(*) filter (where v.desligamento >= m0 and v.desligamento < m1)) x
      from rh.vinculos v where v.unidade_id = any(un) group by v.unidade_id) q),
    'alertas', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'referencia', a.referencia, 'unidade_id', a.unidade_id, 'prazo', a.prazo,
        'aberto_em', a.aberto_em, 'detalhe', a.detalhe) x
      from rh.alertas a where a.status = 'aberto' and (a.unidade_id = any(un) or (g and a.unidade_id is null))
      order by case a.tipo when 'ferias_vencidas' then 0 when 'experiencia_vencida' then 1 when 'desligamento_prazo' then 2
                           when 'fim_experiencia' then 3 when 'exame_vencendo' then 4 when 'ferias_limite' then 5
                           when 'tarefa_atrasada' then 6 when 'jornada_irregular' then 7 else 8 end, a.prazo nulls last
      limit 300) q),
    -- lista do mês para a contabilidade (sem valores)
    'contabilidade', jsonb_build_object(
      'admissoes', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'unidade_id', unidade_id, 'cargo', cargo, 'data', admissao) order by admissao), '[]'::jsonb)
                    from rh.vinculos where admissao >= m0 and admissao < m1 and unidade_id = any(un)),
      'desligamentos', (select coalesce(jsonb_agg(jsonb_build_object('nome', v.nome, 'unidade_id', v.unidade_id, 'data', coalesce(dl.desligamento, v.desligamento),
                          'modalidade', dl.modalidade) order by coalesce(dl.desligamento, v.desligamento)), '[]'::jsonb)
                        from rh.vinculos v left join rh.desligamentos dl on dl.vinculo_id = v.id
                        where coalesce(dl.desligamento, v.desligamento) >= m0 and coalesce(dl.desligamento, v.desligamento) < m1 and v.unidade_id = any(un)),
      'ferias', (select coalesce(jsonb_agg(jsonb_build_object('nome', v.nome, 'unidade_id', v.unidade_id, 'inicio', f.inicio, 'fim', f.fim,
                   'programada', f.programada) order by f.inicio), '[]'::jsonb)
                 from rh.ferias f join rh.vinculos v on v.id = f.vinculo_id
                 where f.inicio < m1 and f.fim >= m0 and v.unidade_id = any(un)),
      'mudancas', (select coalesce(jsonb_agg(jsonb_build_object('nome', v.nome, 'unidade_id', v.unidade_id, 'tipo', mu.tipo, 'data', mu.data) order by mu.data), '[]'::jsonb)
                   from rh.mudancas mu join rh.vinculos v on v.id = mu.vinculo_id
                   where mu.data >= m0 and mu.data < m1 and v.unidade_id = any(un))));
end $$;

-- ---------------------------------------------------------------------------
-- 7. Endurecimento
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'rh' loop
    execute format('alter table rh.%I enable row level security', r.tablename);
    execute format('alter table rh.%I force row level security', r.tablename);
    execute format('revoke all on rh.%I from public', r.tablename);
  end loop;
  execute 'revoke all on rh.v_periodos_ferias from public';
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'rh' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', r.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema rh from anon, authenticated';
    execute 'revoke all on function public.painel_rh(text, date) from public, anon';
    execute 'grant execute on function public.painel_rh(text, date) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema rh to service_role';
    execute 'grant select on all tables in schema rh to service_role';
    execute 'grant execute on function public.painel_rh(text, date) to service_role';
  end if;
end $$;
