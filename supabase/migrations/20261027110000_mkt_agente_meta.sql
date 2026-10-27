-- =============================================================================
-- Idealize AI — Agente de Marketing / Meta Ads (v0.1.0)  · Migração 20261027110000
--
-- Primeira versão = LEITURA e MEDIÇÃO (Prompt Master §5.4 "monitoramento de campanhas", "relatórios por unidade").
-- Lê a Marketing API da Meta (só GET, permissão ads_read) e guarda, por campanha e por dia: gasto, impressões,
-- alcance, cliques, conversas iniciadas, leads e visitas à página. Alerta: gasto sem resultado, custo por resultado
-- muito acima do normal da própria campanha, conta com problema (pagamento/bloqueio), anúncio reprovado, entrega
-- parada e conta sem loja. Nada é criado, pausado, ativado ou alterado na Meta (políticas proibidas).
-- Campanhas de vagas de emprego (nome com "vaga") ficam separadas como recrutamento: não entram no custo comercial.
-- Nasce PAUSADO e com a sincronização DESLIGADA (mkt.sync.ativo = false).
-- =============================================================================

create schema if not exists mkt;
revoke all on schema mkt from public;

create or replace function mkt._hoje() returns date
language sql stable set search_path = pg_catalog as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

-- Sem acento e minúsculo, para sugerir a loja e a marca pelo nome da conta
create or replace function mkt._simples(s text) returns text
language sql immutable set search_path = pg_catalog as $$
  select lower(translate(coalesce(s, ''), 'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇç', 'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCc'))
$$;

-- ---------------------------------------------------------------------------
-- 1. Espelho
-- ---------------------------------------------------------------------------
create table mkt.contas (
  id               text primary key check (id ~ '^[0-9]{5,25}$'),   -- número da conta, sem "act_"
  nome             text not null,
  status_meta      int not null,                -- account_status da Meta: 1 = ativa
  motivo_bloqueio  int,                          -- disable_reason da Meta (0 = nenhum)
  moeda            text not null default 'BRL',
  unidade_id       text references core.unidades(id),      -- loja: confirmada pelo Diego (null = sem loja)
  marca            text check (marca in ('idealize','visao_ideal','outra')),   -- confirmada pelo Diego
  atualizado_em    timestamptz not null default now()
);
create index mkt_contas_unidade on mkt.contas (unidade_id);

create table mkt.campanhas (
  id               text primary key check (id ~ '^[0-9]{5,25}$'),
  conta_id         text not null references mkt.contas(id),
  nome             text not null,
  objetivo         text,
  status           text,                         -- effective_status da Meta
  orcamento_diario numeric(14,2),
  recrutamento     boolean not null default false,
  atualizado_em    timestamptz not null default now()
);
create index mkt_campanhas_conta on mkt.campanhas (conta_id);

create table mkt.metricas (
  campanha_id      text not null references mkt.campanhas(id),
  dia              date not null,
  conta_id         text not null references mkt.contas(id),
  gasto            numeric(14,2) not null default 0 check (gasto >= 0),
  impressoes       bigint not null default 0 check (impressoes >= 0),
  alcance          bigint not null default 0 check (alcance >= 0),
  cliques          bigint not null default 0 check (cliques >= 0),
  conversas        int not null default 0 check (conversas >= 0),
  leads            int not null default 0 check (leads >= 0),
  visitas          int not null default 0 check (visitas >= 0),
  sincronizacao_id uuid,
  primary key (campanha_id, dia)
);
create index mkt_metricas_conta_dia on mkt.metricas (conta_id, dia);
create index mkt_metricas_dia on mkt.metricas (dia);
create index mkt_metricas_sinc on mkt.metricas (sincronizacao_id);

-- Retrato atual dos anúncios com problema (substituído a cada leitura da conta)
create table mkt.anuncios_problema (
  id               text primary key check (id ~ '^[0-9]{5,25}$'),
  conta_id         text not null references mkt.contas(id),
  campanha_id      text,
  nome             text not null,
  status           text not null,
  visto_em         timestamptz not null default now()
);
create index mkt_anuncios_problema_conta on mkt.anuncios_problema (conta_id);

create table mkt.sincronizacoes (
  id                 uuid primary key default gen_random_uuid(),
  tarefa_id          uuid references core.tarefas(id),
  desde              date not null,
  ate                date not null check (ate >= desde),
  contas             int not null,
  campanhas          int not null,
  linhas             int not null,
  gasto_janela       numeric(14,2) not null,
  ignoradas          int not null,
  alertas_abertos    int not null,
  alertas_resolvidos int not null,
  hash_lote          text not null,
  em                 timestamptz not null default now()
);
create index mkt_sincronizacoes_tarefa on mkt.sincronizacoes (tarefa_id);
create index mkt_sincronizacoes_em on mkt.sincronizacoes (em desc);

create table mkt.alertas (
  id            bigserial primary key,
  tipo          text not null check (tipo in ('gasto_sem_resultado','custo_alto','conta_com_problema','anuncio_reprovado',
                                              'entrega_parada','conta_sem_loja')),
  referencia    text not null,                -- 'campanha:123', 'conta:456', 'anuncio:789'
  conta_id      text references mkt.contas(id),
  unidade_id    text references core.unidades(id),
  detalhe       jsonb,
  status        text not null default 'aberto' check (status in ('aberto','resolvido')),
  aberto_em     timestamptz not null default now(),
  resolvido_em  timestamptz,
  resolvido_por text
);
create unique index mkt_alertas_abertos_uk on mkt.alertas (tipo, referencia) where status = 'aberto';
create index mkt_alertas_unidade on mkt.alertas (unidade_id) where status = 'aberto';
create index mkt_alertas_conta on mkt.alertas (conta_id);

insert into core.config (chave, valor) values
  ('mkt.sync.ativo', 'false'),
  ('mkt.gasto_sem_resultado_min', '60'),     -- R$ gastos em ontem+hoje sem nenhuma conversa/lead = alerta
  ('mkt.custo_alto_pct', '60'),              -- custo por resultado dos últimos 3 dias X% acima da média da campanha
  ('mkt.custo_alto_gasto_min', '100'),       -- só avalia custo alto com pelo menos R$ 100 gastos nos 3 dias
  ('mkt.releitura_dias', '3'),               -- a Meta corrige números dos últimos dias: relê sempre essa janela
  ('mkt.sync.primeira_janela_dias', '30'),
  ('mkt.graph_versao', 'v23.0'),
  ('versao_mkt', '0.1.0')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Agente, papel, políticas e integração (nasce pausado; nunca altera nada na Meta)
-- ---------------------------------------------------------------------------
insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('marketing', 'Agente de Marketing', 'comercial', 'pausado', '0.1.0',
   'Acompanha as campanhas da Meta por loja: gasto, conversas, custo por resultado, anúncios reprovados e problemas de conta. Só leitura: não cria, pausa nem altera nada nos anúncios.')
on conflict (id) do nothing;
insert into core.papeis (id, nome) values ('agente_marketing', 'Agente de marketing (máquina)') on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', 'Agente de Marketing', 'marketing' where not exists (select 1 from core.principais where agente_id = 'marketing');
insert into core.principal_papeis (principal_id, papel_id)
select id, 'agente_marketing' from core.principais where agente_id = 'marketing' on conflict do nothing;
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_marketing', 'mkt.meta', 'sincronizar', 'baixo', 'automatica'
where not exists (select 1 from core.politicas where papel_id = 'agente_marketing' and recurso = 'mkt.meta' and operacao = 'sincronizar' and ativo);
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_marketing', 'mkt.meta', v.op, 'alto', 'proibida'
from (values ('criar_campanha'), ('alterar_campanha'), ('alterar_orcamento'), ('pausar'), ('ativar'), ('criar_anuncio'), ('excluir')) v(op)
where not exists (select 1 from core.politicas where papel_id = 'agente_marketing' and recurso = 'mkt.meta' and operacao = v.op and ativo);

insert into core.integracoes (id, nome, status, credencial_leitura, observacoes) values
  ('meta_ads', 'Meta Ads (Marketing API)', 'nao_verificada', 'META_TOKENS',
   'Só leitura (ads_read), um token de usuário do sistema por Business Manager. Escrita proibida pela matriz.')
on conflict (id) do update set credencial_leitura = excluded.credencial_leitura, observacoes = excluded.observacoes;

create or replace function mkt._cfg_num(p_chave text, p_padrao numeric) returns numeric
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(nullif(core.cfg(p_chave, p_padrao::text), '')::numeric, p_padrao)
$$;

-- Sugestão de loja/marca pelo nome da conta (só sugestão: quem confirma é o Diego)
create or replace function mkt.sugestao(p_nome text) returns jsonb
language sql stable security definer set search_path = mkt, core, pg_catalog as $$
  select jsonb_build_object(
    'unidade_id', (select u.id from core.unidades u
                   where u.ativo and u.id <> 'administrativo' and mkt._simples(p_nome) like '%' || mkt._simples(u.nome) || '%'
                   order by length(u.nome) desc limit 1),
    'marca', case when mkt._simples(p_nome) like '%visao ideal%' then 'visao_ideal'
                  when mkt._simples(p_nome) like '%idealize%' then 'idealize' end)
$$;

-- ---------------------------------------------------------------------------
-- 3. Regras dos alertas (recalculadas a cada lote, para o estado inteiro; resolvem sozinhas)
-- ---------------------------------------------------------------------------
create or replace function mkt.recalcular_alertas() returns jsonb
language plpgsql security definer set search_path = mkt, core, pg_catalog as $$
declare d date := mkt._hoje(); v_min numeric := mkt._cfg_num('mkt.gasto_sem_resultado_min', 60);
  v_pct numeric := mkt._cfg_num('mkt.custo_alto_pct', 60); v_gmin numeric := mkt._cfg_num('mkt.custo_alto_gasto_min', 100);
  n_ab int; n_res int;
begin
  drop table if exists _devidos;
  create temp table _devidos (tipo text, referencia text, conta_id text, unidade_id text, detalhe jsonb) on commit drop;

  -- gasto de ontem + hoje sem nenhuma conversa nem lead (campanhas comerciais)
  insert into _devidos
  select 'gasto_sem_resultado', 'campanha:' || c.id, c.conta_id, ct.unidade_id,
         jsonb_build_object('campanha', c.nome, 'conta', ct.nome, 'gasto', sum(m.gasto), 'desde', d - 1, 'minimo', v_min)
  from mkt.campanhas c join mkt.contas ct on ct.id = c.conta_id join mkt.metricas m on m.campanha_id = c.id and m.dia >= d - 1
  where not c.recrutamento
  group by c.id, c.nome, c.conta_id, ct.nome, ct.unidade_id
  having sum(m.gasto) >= v_min and sum(m.conversas + m.leads) = 0;

  -- custo por resultado dos últimos 3 dias muito acima da média da própria campanha nos 27 dias anteriores
  insert into _devidos
  select 'custo_alto', 'campanha:' || q.id, q.conta_id, q.unidade_id,
         jsonb_build_object('campanha', q.nome, 'conta', q.conta, 'custo_recente', round(q.g3 / q.r3, 2),
                            'custo_base', round(q.gb / q.rb, 2), 'acima_pct', round(100 * ((q.g3 / q.r3) / (q.gb / q.rb) - 1)),
                            'gasto_recente', q.g3, 'limite_pct', v_pct)
  from (
    select c.id, c.nome, c.conta_id, ct.nome conta, ct.unidade_id,
      sum(m.gasto) filter (where m.dia >= d - 2) g3, sum(m.conversas + m.leads) filter (where m.dia >= d - 2) r3,
      sum(m.gasto) filter (where m.dia < d - 2) gb, sum(m.conversas + m.leads) filter (where m.dia < d - 2) rb
    from mkt.campanhas c join mkt.contas ct on ct.id = c.conta_id
    join mkt.metricas m on m.campanha_id = c.id and m.dia >= d - 29
    where not c.recrutamento
    group by c.id, c.nome, c.conta_id, ct.nome, ct.unidade_id) q
  where q.g3 >= v_gmin and q.r3 > 0 and q.rb >= 10 and q.gb > 0
    and (q.g3 / q.r3) > (q.gb / q.rb) * (1 + v_pct / 100);

  -- conta com problema na Meta (pagamento, bloqueio, revisão)
  insert into _devidos
  select 'conta_com_problema', 'conta:' || ct.id, ct.id, ct.unidade_id,
         jsonb_build_object('conta', ct.nome, 'status_meta', ct.status_meta, 'motivo_bloqueio', ct.motivo_bloqueio)
  from mkt.contas ct where ct.status_meta <> 1;

  -- anúncio reprovado ou com problema (retrato da última leitura)
  insert into _devidos
  select 'anuncio_reprovado', 'anuncio:' || a.id, a.conta_id, ct.unidade_id,
         jsonb_build_object('anuncio', a.nome, 'status', a.status, 'conta', ct.nome,
                            'campanha', (select nome from mkt.campanhas where id = a.campanha_id))
  from mkt.anuncios_problema a join mkt.contas ct on ct.id = a.conta_id;

  -- entrega parada: a conta gastou nos 7 dias antes de ontem, tem campanha comercial ativa e não gastou nada ontem
  insert into _devidos
  select 'entrega_parada', 'conta:' || ct.id, ct.id, ct.unidade_id,
         jsonb_build_object('conta', ct.nome, 'gasto_7d', (select sum(gasto) from mkt.metricas where conta_id = ct.id and dia between d - 8 and d - 2))
  from mkt.contas ct
  where ct.status_meta = 1
    and exists (select 1 from mkt.campanhas c where c.conta_id = ct.id and c.status = 'ACTIVE' and not c.recrutamento)
    and coalesce((select sum(gasto) from mkt.metricas where conta_id = ct.id and dia between d - 8 and d - 2), 0) > 0
    and coalesce((select sum(gasto) from mkt.metricas where conta_id = ct.id and dia = d - 1), 0) = 0;

  -- conta que gastou nos últimos 30 dias e ainda não tem loja confirmada
  insert into _devidos
  select 'conta_sem_loja', 'conta:' || ct.id, ct.id, null, jsonb_build_object('conta', ct.nome, 'sugestao', mkt.sugestao(ct.nome))
  from mkt.contas ct
  where ct.unidade_id is null and exists (select 1 from mkt.metricas m where m.conta_id = ct.id and m.dia >= d - 29 and m.gasto > 0);

  insert into mkt.alertas (tipo, referencia, conta_id, unidade_id, detalhe)
  select tipo, referencia, conta_id, unidade_id, detalhe from _devidos
  on conflict (tipo, referencia) where status = 'aberto'
  do update set detalhe = excluded.detalhe, unidade_id = excluded.unidade_id, conta_id = excluded.conta_id;
  get diagnostics n_ab = row_count;

  update mkt.alertas a set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente_marketing: situação deixou de existir'
   where a.status = 'aberto' and not exists (select 1 from _devidos x where x.tipo = a.tipo and x.referencia = a.referencia);
  get diagnostics n_res = row_count;
  return jsonb_build_object('ativos', n_ab, 'resolvidos', n_res);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Aplicação de um lote — operações em conjunto; idempotente.
-- Formato: {desde:'AAAA-MM-DD', ate:'AAAA-MM-DD',
--   contas:[{id,nome,status_meta,motivo_bloqueio,moeda}],
--   campanhas:[{id,conta_id,nome,objetivo,status,orcamento_diario}],
--   metricas:[{campanha_id,conta_id,dia,gasto,impressoes,alcance,cliques,conversas,leads,visitas}],
--   anuncios_problema:[{id,conta_id,campanha_id,nome,status}]}
-- As métricas da janela são SUBSTITUÍDAS para as contas do lote (a Meta revisa números dos últimos dias).
-- ---------------------------------------------------------------------------
create or replace function mkt.aplicar_lote(p_tarefa uuid, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = mkt, core, pg_catalog as $$
declare v_s uuid := gen_random_uuid(); v_desde date; v_ate date; v_contas text[];
  n_ct int; n_ca int; n_li int; n_ign int; v_gasto numeric; v_al jsonb;
begin
  if jsonb_typeof(p_lote) is distinct from 'object' then raise exception 'lote inválido'; end if;
  if coalesce(p_lote->>'desde', '') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(p_lote->>'ate', '') !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'lote sem janela (desde/ate)';
  end if;
  v_desde := (p_lote->>'desde')::date; v_ate := (p_lote->>'ate')::date;
  if v_ate < v_desde or v_ate - v_desde > 92 then raise exception 'janela inválida'; end if;

  insert into mkt.contas as c (id, nome, status_meta, motivo_bloqueio, moeda, atualizado_em)
  select r.id, left(btrim(r.nome), 120), r.status_meta, nullif(r.motivo_bloqueio, 0), coalesce(r.moeda, 'BRL'), now()
  from jsonb_to_recordset(coalesce(p_lote->'contas', '[]')) r(id text, nome text, status_meta int, motivo_bloqueio int, moeda text)
  where r.id ~ '^[0-9]{5,25}$' and coalesce(btrim(r.nome), '') <> '' and r.status_meta is not null
  on conflict (id) do update set nome = excluded.nome, status_meta = excluded.status_meta, motivo_bloqueio = excluded.motivo_bloqueio,
    moeda = excluded.moeda, atualizado_em = now()
   where (c.nome, c.status_meta, c.motivo_bloqueio, c.moeda) is distinct from (excluded.nome, excluded.status_meta, excluded.motivo_bloqueio, excluded.moeda);
  select array_agg(r.id) into v_contas
  from jsonb_to_recordset(coalesce(p_lote->'contas', '[]')) r(id text) where exists (select 1 from mkt.contas where id = r.id);
  v_contas := coalesce(v_contas, '{}');
  n_ct := cardinality(v_contas);

  insert into mkt.campanhas as c (id, conta_id, nome, objetivo, status, orcamento_diario, recrutamento, atualizado_em)
  select r.id, r.conta_id, left(btrim(r.nome), 200), left(r.objetivo, 60), left(r.status, 40),
         case when r.orcamento_diario >= 0 then r.orcamento_diario end, mkt._simples(r.nome) ~ 'vaga|curriculo|recrutamento', now()
  from jsonb_to_recordset(coalesce(p_lote->'campanhas', '[]')) r(id text, conta_id text, nome text, objetivo text, status text, orcamento_diario numeric)
  where r.id ~ '^[0-9]{5,25}$' and r.conta_id = any(v_contas) and coalesce(btrim(r.nome), '') <> ''
  on conflict (id) do update set conta_id = excluded.conta_id, nome = excluded.nome, objetivo = excluded.objetivo, status = excluded.status,
    orcamento_diario = excluded.orcamento_diario, recrutamento = excluded.recrutamento, atualizado_em = now();
  get diagnostics n_ca = row_count;

  -- substitui a janela das contas lidas
  delete from mkt.metricas where conta_id = any(v_contas) and dia between v_desde and v_ate;
  with r as (
    select x.* from jsonb_to_recordset(coalesce(p_lote->'metricas', '[]')) x(campanha_id text, conta_id text, dia date, gasto numeric,
      impressoes bigint, alcance bigint, cliques bigint, conversas int, leads int, visitas int)
  ), ok as (
    select r.* from r join mkt.campanhas c on c.id = r.campanha_id and c.conta_id = r.conta_id
    where r.conta_id = any(v_contas) and r.dia between v_desde and v_ate
  ), ins as (
    insert into mkt.metricas (campanha_id, dia, conta_id, gasto, impressoes, alcance, cliques, conversas, leads, visitas, sincronizacao_id)
    select campanha_id, dia, conta_id, round(greatest(coalesce(sum(gasto), 0), 0), 2), greatest(coalesce(sum(impressoes), 0), 0),
           greatest(coalesce(max(alcance), 0), 0), greatest(coalesce(sum(cliques), 0), 0), greatest(coalesce(sum(conversas), 0), 0),
           greatest(coalesce(sum(leads), 0), 0), greatest(coalesce(sum(visitas), 0), 0), v_s
    from ok group by campanha_id, dia, conta_id
    returning gasto)
  select (select count(*) from ins), (select coalesce(sum(gasto), 0) from ins), (select count(*) from r) - (select count(*) from ok)
    into n_li, v_gasto, n_ign;

  -- retrato dos anúncios com problema: substitui o das contas lidas
  delete from mkt.anuncios_problema where conta_id = any(v_contas);
  insert into mkt.anuncios_problema (id, conta_id, campanha_id, nome, status)
  select r.id, r.conta_id, r.campanha_id, left(btrim(r.nome), 200), left(r.status, 40)
  from jsonb_to_recordset(coalesce(p_lote->'anuncios_problema', '[]')) r(id text, conta_id text, campanha_id text, nome text, status text)
  where r.id ~ '^[0-9]{5,25}$' and r.conta_id = any(v_contas) and coalesce(btrim(r.nome), '') <> '' and r.status is not null
  on conflict (id) do nothing;

  v_al := mkt.recalcular_alertas();

  insert into mkt.sincronizacoes (id, tarefa_id, desde, ate, contas, campanhas, linhas, gasto_janela, ignoradas,
    alertas_abertos, alertas_resolvidos, hash_lote)
  values (v_s, p_tarefa, v_desde, v_ate, n_ct, n_ca, n_li, v_gasto, n_ign, (v_al->>'ativos')::int, (v_al->>'resolvidos')::int, md5(p_lote::text));
  return jsonb_build_object('sincronizacao', v_s, 'desde', v_desde, 'ate', v_ate, 'contas', n_ct, 'campanhas', n_ca, 'linhas', n_li,
    'gasto_janela', v_gasto, 'ignoradas', n_ign, 'alertas', v_al, 'hash_lote', md5(p_lote::text));
end $$;

create or replace function mkt.concluir_sincronizacao(p_tarefa uuid, p_executor text, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = mkt, core, pg_catalog as $$
declare t record; v jsonb;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'marketing' or t.tipo is distinct from 'mkt_sincronizacao' then
    raise exception 'tarefa não é sincronização do marketing';
  end if;
  v := mkt.aplicar_lote(p_tarefa, p_lote);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', v->>'hash_lote', v);
  return v;
end $$;

-- Janela da próxima leitura: sempre relê os últimos N dias; na primeira vez, 30 dias
create or replace function mkt.proxima_janela() returns jsonb
language sql stable security definer set search_path = mkt, core, pg_catalog as $$
  select jsonb_build_object(
    'desde', case when exists (select 1 from mkt.sincronizacoes)
                  then mkt._hoje() - (mkt._cfg_num('mkt.releitura_dias', 3)::int - 1)
                  else mkt._hoje() - (mkt._cfg_num('mkt.sync.primeira_janela_dias', 30)::int - 1) end,
    'ate', mkt._hoje(),
    'versao', core.cfg('mkt.graph_versao', 'v23.0'))
$$;

-- ---------------------------------------------------------------------------
-- 5. Validador independente (reconta o espelho e reavalia o alerta principal com consulta própria)
-- ---------------------------------------------------------------------------
create or replace function mkt.validar_sincronizacao(p_tarefa uuid, p_validador text) returns text
language plpgsql security definer set search_path = mkt, core, pg_catalog as $$
declare t record; s record; v_erros text[] := '{}'; n int; g numeric; d date := mkt._hoje();
  v_min numeric := mkt._cfg_num('mkt.gasto_sem_resultado_min', 60);
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  select * into s from mkt.sincronizacoes where tarefa_id = p_tarefa order by em desc limit 1;
  if s.id is null then
    v_erros := v_erros || 'sincronização sem registro';
  else
    select count(*), coalesce(sum(gasto), 0) into n, g from mkt.metricas where sincronizacao_id = s.id;
    if n <> s.linhas then v_erros := v_erros || format('espelho tem %s linhas do lote, registro diz %s', n, s.linhas); end if;
    if g <> s.gasto_janela then v_erros := v_erros || format('gasto no espelho %s, registro diz %s', g, s.gasto_janela); end if;
    if exists (select 1 from mkt.metricas where sincronizacao_id = s.id and (dia < s.desde or dia > s.ate)) then
      v_erros := v_erros || 'linha fora da janela';
    end if;
    -- completude: toda campanha comercial que gastou o mínimo sem resultado em ontem+hoje tem alerta aberto
    select count(*) into n from (
      select m.campanha_id from mkt.metricas m join mkt.campanhas c on c.id = m.campanha_id
      where m.dia >= d - 1 and not c.recrutamento
      group by m.campanha_id having sum(m.gasto) >= v_min and sum(m.conversas) + sum(m.leads) = 0) x
    where not exists (select 1 from mkt.alertas a where a.tipo = 'gasto_sem_resultado' and a.status = 'aberto'
                      and a.referencia = 'campanha:' || x.campanha_id);
    if n > 0 then v_erros := v_erros || format('%s campanhas gastando sem resultado sem alerta', n); end if;
    -- coerência: conta ativa não pode estar com alerta de problema aberto
    select count(*) into n from mkt.alertas a join mkt.contas c on 'conta:' || c.id = a.referencia
     where a.tipo = 'conta_com_problema' and a.status = 'aberto' and c.status_meta = 1;
    if n > 0 then v_erros := v_erros || format('%s alertas de conta com problema em conta ativa', n); end if;
  end if;
  if array_length(v_erros, 1) is null then
    return core.registrar_validacao(p_tarefa, p_validador, true, null, jsonb_build_object('sincronizacao', s.id));
  end if;
  return core.registrar_validacao(p_tarefa, p_validador, false, array_to_string(v_erros, '; '),
    jsonb_build_object('sincronizacao', s.id, 'erros', to_jsonb(v_erros)));
end $$;

-- Uma leitura por hora (a Meta atualiza os números com atraso; mais que isso só gasta limite da API)
create or replace function mkt.agendar_sincronizacao() returns uuid
language plpgsql security definer set search_path = mkt, core, pg_catalog as $$
declare v_p uuid;
begin
  if core.cfg('mkt.sync.ativo', 'false') <> 'true' then return null; end if;
  select id into v_p from core.principais where agente_id = 'marketing';
  return core.criar_tarefa(v_p, 'marketing', 'mkt_sincronizacao', 'mkt.meta', 'sincronizar', null,
    jsonb_build_object('origem', 'meta_ads'), 'mkt:sync:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDDHH24'), null, 6);
end $$;

-- Loja e marca de cada conta: decisão humana, auditada
create or replace function mkt.definir_loja_conta(p_conta text, p_unidade text, p_marca text, p_ator uuid, p_motivo text) returns void
language plpgsql security definer set search_path = mkt, core, pg_catalog as $$
declare v_antes jsonb;
begin
  if not exists (select 1 from core.principais where id = p_ator and tipo = 'usuario' and ativo) then
    raise exception 'definição de loja é feita por pessoa' using errcode = '42501';
  end if;
  if p_marca is not null and p_marca not in ('idealize','visao_ideal','outra') then raise exception 'marca inválida' using errcode = '22023'; end if;
  select jsonb_build_object('unidade', unidade_id, 'marca', marca) into v_antes from mkt.contas where id = p_conta for update;
  if not found then raise exception 'conta inexistente'; end if;
  update mkt.contas set unidade_id = p_unidade, marca = p_marca, atualizado_em = now() where id = p_conta;
  perform mkt.recalcular_alertas();
  perform core.auditar(p_ator, null, 'conta_loja', 'mkt.conta', p_conta, v_antes,
    jsonb_build_object('unidade', p_unidade, 'marca', p_marca), p_motivo);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Painel (login vinculado, 2FA, escopo por unidade; contas sem loja só no escopo global)
-- ---------------------------------------------------------------------------
create or replace function public.painel_marketing(p_unidade text default null, p_dias int default 7) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[]; g boolean; d int := least(greatest(coalesce(p_dias, 7), 1), 90); v_ini date; v_hoje date := mkt._hoje();
begin
  v_eu := painel._entrar('marketing', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; g := false; end if;
  v_ini := v_hoje - (d - 1);
  return jsonb_build_object(
    'periodo_dias', d, 'desde', v_ini, 'ate', v_hoje,
    'sincronizacao', jsonb_build_object('ativa', core.cfg('mkt.sync.ativo', 'false') = 'true',
       'agente', (select status from core.agentes where id = 'marketing'),
       'ultima', (select jsonb_build_object('em', em, 'desde', desde, 'ate', ate, 'contas', contas, 'linhas', linhas)
                  from mkt.sincronizacoes order by em desc limit 1)),
    'lojas', (select coalesce(jsonb_agg(x order by (x->>'gasto')::numeric desc), '[]'::jsonb) from (
      select jsonb_build_object('id', coalesce(ct.unidade_id, '_sem_loja'),
        'nome', coalesce((select nome from core.unidades where id = ct.unidade_id), 'Contas sem loja definida'),
        'gasto', coalesce(sum(m.gasto) filter (where not c.recrutamento), 0),
        'conversas', coalesce(sum(m.conversas) filter (where not c.recrutamento), 0),
        'leads', coalesce(sum(m.leads) filter (where not c.recrutamento), 0),
        'impressoes', coalesce(sum(m.impressoes) filter (where not c.recrutamento), 0),
        'gasto_recrutamento', coalesce(sum(m.gasto) filter (where c.recrutamento), 0)) x
      from mkt.metricas m join mkt.campanhas c on c.id = m.campanha_id join mkt.contas ct on ct.id = m.conta_id
      where m.dia >= v_ini and ((g and ct.unidade_id is null) or ct.unidade_id = any(un))
      group by ct.unidade_id) q),
    'marcas', (select coalesce(jsonb_agg(x order by (x->>'gasto')::numeric desc), '[]'::jsonb) from (
      select jsonb_build_object('marca', coalesce(ct.marca, 'sem_marca'), 'gasto', sum(m.gasto), 'conversas', sum(m.conversas),
        'leads', sum(m.leads)) x
      from mkt.metricas m join mkt.campanhas c on c.id = m.campanha_id join mkt.contas ct on ct.id = m.conta_id
      where m.dia >= v_ini and not c.recrutamento and ((g and ct.unidade_id is null) or ct.unidade_id = any(un))
      group by coalesce(ct.marca, 'sem_marca')) q),
    'campanhas', (select coalesce(jsonb_agg(x order by (x->>'gasto')::numeric desc), '[]'::jsonb) from (
      select jsonb_build_object('id', c.id, 'nome', c.nome, 'conta', ct.nome, 'unidade_id', ct.unidade_id, 'status', c.status,
        'objetivo', c.objetivo, 'recrutamento', c.recrutamento, 'orcamento_diario', c.orcamento_diario,
        'gasto', sum(m.gasto), 'conversas', sum(m.conversas), 'leads', sum(m.leads), 'cliques', sum(m.cliques),
        'impressoes', sum(m.impressoes), 'visitas', sum(m.visitas)) x
      from mkt.metricas m join mkt.campanhas c on c.id = m.campanha_id join mkt.contas ct on ct.id = m.conta_id
      where m.dia >= v_ini and ((g and ct.unidade_id is null) or ct.unidade_id = any(un))
      group by c.id, c.nome, ct.nome, ct.unidade_id, c.status, c.objetivo, c.recrutamento, c.orcamento_diario
      having sum(m.gasto) > 0
      order by sum(m.gasto) desc limit 100) q),
    'por_dia', (select coalesce(jsonb_agg(x order by x->>'dia'), '[]'::jsonb) from (
      select jsonb_build_object('dia', m.dia, 'gasto', sum(m.gasto), 'resultados', sum(m.conversas + m.leads)) x
      from mkt.metricas m join mkt.campanhas c on c.id = m.campanha_id join mkt.contas ct on ct.id = m.conta_id
      where m.dia >= v_ini and not c.recrutamento and ((g and ct.unidade_id is null) or ct.unidade_id = any(un))
      group by m.dia) q),
    'alertas', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'referencia', a.referencia, 'unidade_id', a.unidade_id,
        'aberto_em', a.aberto_em, 'detalhe', painel._mascarar(a.detalhe)) x
      from mkt.alertas a
      where a.status = 'aberto' and ((g and a.unidade_id is null) or a.unidade_id = any(un))
      order by case a.tipo when 'conta_com_problema' then 0 when 'gasto_sem_resultado' then 1 when 'entrega_parada' then 2
                           when 'anuncio_reprovado' then 3 when 'custo_alto' then 4 else 5 end, a.aberto_em
      limit 300) q),
    'contas', case when g then (select coalesce(jsonb_agg(jsonb_build_object('id', ct.id, 'nome', ct.nome, 'unidade_id', ct.unidade_id,
        'marca', ct.marca, 'status_meta', ct.status_meta, 'sugestao', mkt.sugestao(ct.nome),
        'gasto_30d', (select coalesce(sum(gasto), 0) from mkt.metricas where conta_id = ct.id and dia >= v_hoje - 29))
        order by ct.nome), '[]'::jsonb) from mkt.contas ct) end);
end $$;

create or replace function public.painel_marketing_conta_loja(p_conta text, p_unidade text, p_marca text, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('marketing_conta_loja', p_conta);
  perform painel._exigir(v_eu, 'administrar');
  if p_unidade is not null and not exists (select 1 from core.unidades where id = p_unidade and ativo) then
    raise exception 'loja inválida' using errcode = '22023';
  end if;
  perform mkt.definir_loja_conta(p_conta, p_unidade, p_marca, v_eu, painel._texto(5, p_motivo, 'motivo'));
end $$;

-- ---------------------------------------------------------------------------
-- 7. Endurecimento (mesmo padrão)
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'mkt' loop
    execute format('alter table mkt.%I enable row level security', r.tablename);
    execute format('alter table mkt.%I force row level security', r.tablename);
    execute format('revoke all on mkt.%I from public', r.tablename);
  end loop;
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'mkt' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', r.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema mkt from anon, authenticated';
    execute 'revoke all on function public.painel_marketing(text, int) from public, anon';
    execute 'revoke all on function public.painel_marketing_conta_loja(text, text, text, text) from public, anon';
    execute 'grant execute on function public.painel_marketing(text, int) to authenticated';
    execute 'grant execute on function public.painel_marketing_conta_loja(text, text, text, text) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema mkt to service_role';
    execute 'grant select on all tables in schema mkt to service_role';
    execute 'grant execute on function public.painel_marketing(text, int) to service_role';
    execute 'grant execute on function public.painel_marketing_conta_loja(text, text, text, text) to service_role';
  end if;
end $$;
