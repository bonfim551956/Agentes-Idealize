-- =============================================================================
-- Idealize AI — Relatório do dia + agentes de Inteligência (Radar do Mercado e Concorrentes)  · Migração 20261107040000
-- Pedido do Diego (07/11): "todos os agentes dentro do painel, fazendo a varredura diária e trazendo um relatório".
--  • intel.*  — concorrentes (lista editável pelo painel), anúncios vistos na Biblioteca de Anúncios da Meta,
--               notícias do mercado e ideias para aplicar (aprovar / descartar / feita).
--    - Radar do Mercado e Concorrentes rodam como tarefas agendadas do Claude (busca na web e Biblioteca de Anúncios
--      da Meta, que não é liberada para sistema próprio no Brasil): pedem o trabalho em intel.iniciar(...) e devolvem
--      em intel.concluir_radar / intel.concluir_concorrentes. Notícia só entra uma vez (url única).
--    Os dois passam pela mesma esteira dos outros agentes (tarefa, execução, validação, auditoria) e nascem LIGADOS
--    só depois do PODE FAZER (07/11). Não agem fora: só leem fontes públicas e gravam aqui.
--  • rel.*    — Relatório do dia (07h): prioridades de todas as áreas, o que cada agente fez em 24 h, mercado e
--               concorrentes. Fica guardado por dia (histórico) e pode ser gerado de novo pelo painel.
-- =============================================================================
create schema if not exists intel;
create schema if not exists rel;
revoke all on schema intel, rel from public;

-- ---------------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------------
create table intel.concorrentes (
  id           serial primary key,
  nome         text not null check (length(btrim(nome)) between 2 and 120),
  praca        text,                                   -- cidade/região que interessa (livre)
  unidade_id   text references core.unidades(id),      -- loja da Idealize que disputa com ele (opcional)
  instagram    text check (instagram is null or instagram ~ '^[A-Za-z0-9._]{1,30}$'),
  termo_busca  text,                                   -- como achar na Biblioteca de Anúncios (padrão: nome)
  page_ids     text[] not null default '{}',           -- páginas do Facebook confirmadas (vazio = buscar pelo termo)
  observacao   text,
  ativo        boolean not null default true,
  criado_em    timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index intel_concorrentes_nome on intel.concorrentes (lower(nome));

create table intel.anuncios (
  id             text primary key check (id ~ '^[0-9]{5,25}$'),
  concorrente_id int not null references intel.concorrentes(id),
  page_id        text,
  page_nome      text,
  titulo         text,
  inicio         timestamptz,
  snapshot_url   text check (snapshot_url is null or snapshot_url like 'https://www.facebook.com/ads/library/%'),
  primeiro_visto timestamptz not null default now(),
  ultimo_visto   timestamptz not null default now(),
  ativo          boolean not null default true
);
create index intel_anuncios_conc on intel.anuncios (concorrente_id, ativo);
create index intel_anuncios_visto on intel.anuncios (primeiro_visto desc);

create table intel.noticias (
  id          bigserial primary key,
  dia         date not null,
  titulo      text not null,
  fonte       text,
  url         text not null check (url ~ '^https?://'),
  resumo      text,
  impacto     text,                                    -- "o que muda para a Idealize"
  tema        text,
  relevancia  int not null default 3 check (relevancia between 1 and 5),
  tarefa_id   uuid references core.tarefas(id),
  criado_em   timestamptz not null default now()
);
create unique index intel_noticias_url on intel.noticias (url);
create index intel_noticias_dia on intel.noticias (dia desc, relevancia desc);

create table intel.ideias (
  id             bigserial primary key,
  concorrente_id int references intel.concorrentes(id),
  titulo         text not null,
  evidencia      text,
  como_aplicar   text,
  link           text check (link is null or link ~ '^https?://'),
  status         text not null default 'sugerida' check (status in ('sugerida','aprovada','descartada','feita')),
  tarefa_id      uuid references core.tarefas(id),
  decidido_por   uuid references core.principais(id),
  decidido_em    timestamptz,
  nota           text,
  criado_em      timestamptz not null default now()
);
create index intel_ideias_status on intel.ideias (status, criado_em desc);

create table intel.sincronizacoes (
  id         bigserial primary key,
  agente_id  text not null references core.agentes(id),
  tarefa_id  uuid references core.tarefas(id),
  em         timestamptz not null default now(),
  resumo     jsonb
);
create index intel_sinc_agente on intel.sincronizacoes (agente_id, em desc);

create table rel.relatorios (
  dia        date primary key,
  conteudo   jsonb not null,
  gerado_em  timestamptz not null default now(),
  versao     int not null default 1
);

do $$ begin
  revoke all on all tables in schema intel, rel from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema intel from anon, authenticated';
    execute 'revoke all on all tables in schema rel from anon, authenticated';
  end if;
end $$;
alter table intel.concorrentes enable row level security; alter table intel.concorrentes force row level security;
alter table intel.anuncios enable row level security; alter table intel.anuncios force row level security;
alter table intel.noticias enable row level security; alter table intel.noticias force row level security;
alter table intel.ideias enable row level security; alter table intel.ideias force row level security;
alter table intel.sincronizacoes enable row level security; alter table intel.sincronizacoes force row level security;
alter table rel.relatorios enable row level security; alter table rel.relatorios force row level security;

-- ---------------------------------------------------------------------------
-- 2. Agentes, papéis, políticas e configuração
-- ---------------------------------------------------------------------------
insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('radar', 'Radar do Mercado', 'comercial', 'ativo', '0.1.0',
   'Todo dia procura na web as novidades do mercado óptico (lentes, armações, fabricantes, regras, impostos, marketing) e grava as que importam, cada uma com o que muda para a Idealize. Só leitura de fontes públicas.'),
  ('concorrentes', 'Concorrentes', 'comercial', 'ativo', '0.1.0',
   'Todo dia lê os anúncios ativos dos concorrentes na Biblioteca de Anúncios da Meta, marca campanha nova e anúncio que roda há muito tempo, e sugere ideias para aplicar. Só leitura de fontes públicas.')
on conflict (id) do nothing;
insert into core.papeis (id, nome) values ('agente_intel', 'Agentes de inteligência de mercado (máquina)') on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', v.n, v.a from (values ('Radar do Mercado', 'radar'), ('Concorrentes', 'concorrentes')) v(n, a)
where not exists (select 1 from core.principais where agente_id = v.a);
insert into core.principal_papeis (principal_id, papel_id)
select id, 'agente_intel' from core.principais where agente_id in ('radar', 'concorrentes') on conflict do nothing;
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_intel', v.r, 'pesquisar', 'baixo', 'automatica' from (values ('intel.mercado'), ('intel.concorrentes')) v(r)
where not exists (select 1 from core.politicas where papel_id = 'agente_intel' and recurso = v.r and operacao = 'pesquisar' and ativo);
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_intel', 'intel.concorrentes', v.op, 'alto', 'proibida'
from (values ('enviar_mensagem'), ('comentar'), ('publicar'), ('criar_anuncio'), ('contatar')) v(op)
where not exists (select 1 from core.politicas where papel_id = 'agente_intel' and recurso = 'intel.concorrentes' and operacao = v.op and ativo);

insert into core.config (chave, valor) values
  ('intel.radar.ativo', 'true'), ('intel.concorrentes.ativo', 'true'),
  ('intel.radar.modelo', 'claude-sonnet-5-5'),
  ('intel.radar.temas', 'mercado óptico Brasil; lentes oftálmicas lançamentos; armações e marcas de óculos; fabricantes Essilor Zeiss Hoya; laboratórios ópticos; varejo óptico redes de óticas; regras Anvisa e conselhos de óptica e optometria; impostos e nota fiscal varejo; crediário e meios de pagamento varejo; Meta Ads e WhatsApp Business novidades; Google Meu Negócio novidades'),
  ('intel.anuncio_longo_dias', '30'),
  ('rel.prioridades', '5')
on conflict (chave) do nothing;

-- o Supervisor vigia os dois como os demais (1 rodada por dia, folga de 2 h)
insert into sup.limites (agente_id, chave_ativo, max_minutos) values
  ('radar', 'intel.radar.ativo', 1560), ('concorrentes', 'intel.concorrentes.ativo', 1560)
on conflict (agente_id) do nothing;

create or replace view sup.v_ultimas as
  select 'laboratorio'::text agente_id, max(em) em from lab.sincronizacoes
  union all select 'comercial', max(em) from com.sincronizacoes
  union all select 'marketing', max(em) from mkt.sincronizacoes
  union all select 'caixa', max(em) from cx.sincronizacoes
  union all select 'cobrancas', max(em) from cob.sincronizacoes
  union all select 'rh', max(em) from rh.sincronizacoes
  union all select 'atribuicao', max(em) from atr.sincronizacoes
  union all select 'supervisor', max(em) from sup.verificacoes
  union all select 'radar', max(em) from intel.sincronizacoes where agente_id = 'radar'
  union all select 'concorrentes', max(em) from intel.sincronizacoes where agente_id = 'concorrentes';

-- lista inicial (pedido do Diego, 07/11). Páginas confirmadas na Biblioteca de Anúncios em 07/11; o resto busca pelo termo.
insert into intel.concorrentes (nome, praca, termo_busca, page_ids, observacao) values
  ('Óticas Prevent', null, 'Óticas Prevent', '{350151402721384}', null),
  ('Óticas Gassi', 'São Vicente e região', 'Óticas Gassi', '{173707529380179,1335226946332018}', null),
  ('Óticas Style', null, 'Óticas Style', '{}', 'confirmar cidade ou Instagram'),
  ('Óticas BellaVision', 'Baixada Santista', 'BellaVision', '{103122405202746,618923017974293,219774611222906,712428878610117}', null),
  ('Óticas Santês', 'Piracicaba e região', 'Óticas Santês', '{406041326612915}', null),
  ('Óticas Golden Mix', null, 'Golden Mix ótica', '{}', null),
  ('Óticas Carol', null, 'Óticas Carol', '{}', 'muitas franquias: confirmar as unidades da região'),
  ('Óticas Diniz', null, 'Óticas Diniz', '{104005575824660}', null),
  ('Belliótica', null, 'Belliótica', '{}', 'sem anúncio ativo em 07/11: confirmar Instagram'),
  ('Óticas Center', null, 'Óticas Center', '{}', 'confirmar cidade ou Instagram'),
  ('Óticas Mabe', null, 'Óticas Mabe', '{}', 'sem anúncio ativo em 07/11: confirmar Instagram'),
  ('Instituto Visão Solidária', 'Campinas e região', 'Instituto Visão Solidária', '{979973325193584}', null),
  ('Chilli Beans', null, 'Chilli Beans', '{}', null)
on conflict do nothing;
update intel.concorrentes set unidade_id = 'sao_vicente' where nome in ('Óticas Gassi', 'Óticas BellaVision') and exists (select 1 from core.unidades where id = 'sao_vicente');
update intel.concorrentes set unidade_id = 'piracicaba' where nome = 'Óticas Santês' and exists (select 1 from core.unidades where id = 'piracicaba');
update intel.concorrentes set unidade_id = 'campinas' where nome = 'Instituto Visão Solidária' and exists (select 1 from core.unidades where id = 'campinas');

-- ---------------------------------------------------------------------------
-- 3. Esteira dos agentes (pedir trabalho → devolver resultado → validação independente)
-- ---------------------------------------------------------------------------
create or replace function intel._hoje() returns date
language sql stable set search_path = pg_catalog as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

-- cria (ou reaproveita) a tarefa do dia e a reivindica; devolve o que o executor precisa
create or replace function intel.iniciar(p_agente text, p_executor text) returns jsonb
language plpgsql security definer set search_path = intel, core, pg_catalog as $$
declare v_p uuid; v_t uuid; x record; v_rec text;
begin
  if p_agente not in ('radar', 'concorrentes') then raise exception 'agente inválido'; end if;
  if core.cfg('intel.' || p_agente || '.ativo', 'false') <> 'true' then return jsonb_build_object('status', 'desligado'); end if;
  if (select status from core.agentes where id = p_agente) <> 'ativo' then return jsonb_build_object('status', 'pausado'); end if;
  v_rec := case p_agente when 'radar' then 'intel.mercado' else 'intel.concorrentes' end;
  select id into v_p from core.principais where agente_id = p_agente;
  v_t := core.criar_tarefa(v_p, p_agente, p_agente || '_varredura', v_rec, 'pesquisar', null,
    jsonb_build_object('dia', intel._hoje()), p_agente || ':varredura:' || to_char(intel._hoje(), 'YYYYMMDD'), null, 6);
  -- tarefa do dia já feita: nada a fazer
  if (select status from core.tarefas where id = v_t) in ('concluida', 'validando') then
    return jsonb_build_object('status', 'ja_feita', 'tarefa', v_t);
  end if;
  update core.tarefas set prioridade = 1 where id = v_t and status = 'pronta';
  select * into x from core.reivindicar(p_agente, p_executor, 1800) where id = v_t;
  if x.id is null then return jsonb_build_object('status', 'ocupada', 'tarefa', v_t); end if;
  if p_agente = 'radar' then
    return jsonb_build_object('status', 'ok', 'tarefa', v_t, 'dia', intel._hoje(),
      'modelo', core.cfg('intel.radar.modelo', 'claude-sonnet-5-5'),
      'temas', core.cfg('intel.radar.temas', ''),
      'ja_vistas', (select coalesce(jsonb_agg(url order by id desc), '[]'::jsonb) from (
         select id, url from intel.noticias where dia > intel._hoje() - 14 order by id desc limit 150) q));
  end if;
  return jsonb_build_object('status', 'ok', 'tarefa', v_t, 'dia', intel._hoje(),
    'concorrentes', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'praca', praca,
        'termo_busca', coalesce(nullif(btrim(termo_busca), ''), nome), 'page_ids', page_ids, 'instagram', instagram) order by id), '[]'::jsonb)
      from intel.concorrentes where ativo));
end $$;

-- erro do executor (não deixa tarefa presa)
create or replace function intel.falhar(p_tarefa uuid, p_executor text, p_erro text) returns text
language plpgsql security definer set search_path = intel, core, pg_catalog as $$
begin
  return core.registrar_execucao(p_tarefa, p_executor, 'erro', null, null, left(coalesce(p_erro, 'falha sem detalhe'), 300));
end $$;

-- Radar: p_itens = [{titulo, fonte, url, resumo, impacto, tema, relevancia(1-5)}]
create or replace function intel.concluir_radar(p_tarefa uuid, p_executor text, p_itens jsonb) returns jsonb
language plpgsql security definer set search_path = intel, core, pg_catalog as $$
declare t record; x jsonb; n int := 0; d int := 0; v jsonb; v_id bigint;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'radar' then raise exception 'tarefa não é do Radar'; end if;
  if jsonb_typeof(coalesce(p_itens, '[]')) <> 'array' then raise exception 'itens inválidos'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_itens, '[]')) loop
    if coalesce(x->>'url', '') !~ '^https?://' or length(btrim(coalesce(x->>'titulo', ''))) < 5 then d := d + 1; continue; end if;
    insert into intel.noticias (dia, titulo, fonte, url, resumo, impacto, tema, relevancia, tarefa_id)
    values (intel._hoje(), left(btrim(x->>'titulo'), 300), left(x->>'fonte', 120), left(x->>'url', 1000), left(x->>'resumo', 1200),
      left(x->>'impacto', 600), left(x->>'tema', 80), least(greatest(coalesce((x->>'relevancia')::int, 3), 1), 5), p_tarefa)
    on conflict (url) do nothing returning id into v_id;
    if v_id is not null then n := n + 1; else d := d + 1; end if;
    v_id := null;
  end loop;
  v := jsonb_build_object('novas', n, 'descartadas', d);
  insert into intel.sincronizacoes (agente_id, tarefa_id, resumo) values ('radar', p_tarefa, v);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', null, v);
  -- validação independente: o que a tarefa diz que gravou está gravado
  if (select count(*) from intel.noticias where tarefa_id = p_tarefa) = n then
    perform core.registrar_validacao(p_tarefa, 'validador_sql', true, null, v);
  else
    perform core.registrar_validacao(p_tarefa, 'validador_sql', false, 'notícias gravadas não conferem', v);
  end if;
  return v;
end $$;

-- Concorrentes:
--   p_anuncios = [{concorrente_id, id, page_id, page_nome, titulo, inicio (epoch s ou ISO), snapshot_url}]
--   p_lidos    = ids dos concorrentes varridos por completo (o que deles não veio na lista saiu do ar)
--   p_ideias   = [{concorrente_id?, titulo, evidencia, como_aplicar, link?}]
create or replace function intel.concluir_concorrentes(p_tarefa uuid, p_executor text, p_anuncios jsonb, p_lidos int[], p_ideias jsonb default '[]')
returns jsonb
language plpgsql security definer set search_path = intel, core, pg_catalog as $$
declare t record; x jsonb; v_ini timestamptz; n_novos int := 0; n_vistos int := 0; n_sairam int := 0; n_ideias int := 0;
  v jsonb; v_ids text[] := '{}'; v_novo boolean;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'concorrentes' then raise exception 'tarefa não é do agente Concorrentes'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_anuncios, '[]')) loop
    if coalesce(x->>'id', '') !~ '^[0-9]{5,25}$' or not exists (select 1 from intel.concorrentes where id = (x->>'concorrente_id')::int) then continue; end if;
    v_ini := case when x->>'inicio' ~ '^[0-9]{9,11}$' then to_timestamp((x->>'inicio')::bigint)
                  when x->>'inicio' ~ '^\d{4}-\d{2}-\d{2}' then (x->>'inicio')::timestamptz end;
    -- "novo" = entrou no ar agora; anúncio antigo visto pela 1ª vez (1ª leitura, concorrente incluído) não é novidade
    insert into intel.anuncios (id, concorrente_id, page_id, page_nome, titulo, inicio, snapshot_url, primeiro_visto)
    values (x->>'id', (x->>'concorrente_id')::int, left(x->>'page_id', 30), left(x->>'page_nome', 200), left(x->>'titulo', 300), v_ini,
      case when x->>'snapshot_url' like 'https://www.facebook.com/ads/library/%' then left(x->>'snapshot_url', 300) end,
      case when v_ini < now() - interval '2 days' then v_ini else now() end)
    on conflict (id) do update set ultimo_visto = now(), ativo = true, titulo = coalesce(excluded.titulo, intel.anuncios.titulo),
      inicio = coalesce(intel.anuncios.inicio, excluded.inicio)
    returning (xmax = 0) into v_novo;
    if v_novo and (v_ini is null or v_ini >= now() - interval '2 days') then n_novos := n_novos + 1; end if;
    n_vistos := n_vistos + 1;
    v_ids := v_ids || (x->>'id');
  end loop;
  update intel.anuncios set ativo = false
   where ativo and concorrente_id = any(coalesce(p_lidos, '{}')) and not (id = any(v_ids));
  get diagnostics n_sairam = row_count;
  for x in select * from jsonb_array_elements(coalesce(p_ideias, '[]')) loop
    if length(btrim(coalesce(x->>'titulo', ''))) < 5 then continue; end if;
    if exists (select 1 from intel.ideias where lower(titulo) = lower(btrim(x->>'titulo')) and criado_em > now() - interval '30 days') then continue; end if;
    insert into intel.ideias (concorrente_id, titulo, evidencia, como_aplicar, link, tarefa_id)
    values (case when exists (select 1 from intel.concorrentes where id = nullif(x->>'concorrente_id', '')::int) then (x->>'concorrente_id')::int end,
      left(btrim(x->>'titulo'), 200), left(x->>'evidencia', 1000), left(x->>'como_aplicar', 1000),
      case when x->>'link' ~ '^https?://' then left(x->>'link', 500) end, p_tarefa);
    n_ideias := n_ideias + 1;
  end loop;
  v := jsonb_build_object('anuncios_vistos', n_vistos, 'novos', n_novos, 'sairam_do_ar', n_sairam, 'ideias', n_ideias,
    'concorrentes_lidos', coalesce(cardinality(p_lidos), 0));
  insert into intel.sincronizacoes (agente_id, tarefa_id, resumo) values ('concorrentes', p_tarefa, v);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', null, v);
  if (select count(*) from intel.anuncios where id = any(v_ids) and ativo) = cardinality(v_ids) then
    perform core.registrar_validacao(p_tarefa, 'validador_sql', true, null, v);
  else
    perform core.registrar_validacao(p_tarefa, 'validador_sql', false, 'anúncios gravados não conferem', v);
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Relatório do dia
-- ---------------------------------------------------------------------------
create or replace view rel.v_alertas as
  select 'laboratorio'::text agente_id, tipo, unidade_id, aberto_em, status from lab.alertas
  union all select 'comercial', tipo, unidade_id, aberto_em, status from com.alertas
  union all select 'marketing', tipo, unidade_id, aberto_em, status from mkt.alertas
  union all select 'caixa', tipo, unidade_id, aberto_em, status from cx.alertas
  union all select 'cobrancas', tipo, unidade_id, aberto_em, status from cob.alertas
  union all select 'rh', tipo, unidade_id, aberto_em, status from rh.alertas;

create or replace function rel._unidade(p text) returns text
language sql stable security definer set search_path = core, pg_catalog as $$ select nome from core.unidades where id = p $$;

create or replace function rel.gerar(p_dia date default null) returns jsonb
language plpgsql security definer set search_path = rel, intel, core, pg_catalog as $$
declare d date := coalesce(p_dia, intel._hoje()); desde timestamptz := now() - interval '24 hours';
  v_ag jsonb; v_pri jsonb; v_merc jsonb; v_conc jsonb; v jsonb; v_lim int := coalesce(nullif(core.cfg('rel.prioridades', '5'), '')::int, 5);
  v_longo int := coalesce(nullif(core.cfg('intel.anuncio_longo_dias', '30'), '')::int, 30);
begin
  -- o que cada agente fez
  select coalesce(jsonb_agg(x order by x->>'ordem', x->>'nome'), '[]'::jsonb) into v_ag from (
    select jsonb_build_object('id', a.id, 'nome', a.nome, 'status', a.status,
      'ordem', case when a.id in ('radar','concorrentes') then '0' when a.id = 'supervisor' then '9' else '5' end,
      'rodadas', (select count(*) from core.tarefas t where t.agente_id = a.id and t.criado_em > desde),
      'falhas', (select count(*) from core.tarefas t where t.agente_id = a.id and t.status in ('falhou','incerta') and t.atualizado_em > desde),
      'novos', case a.id
         when 'radar' then (select count(*) from intel.noticias where criado_em > desde)
         when 'concorrentes' then (select count(*) from intel.anuncios where primeiro_visto > desde)
         when 'financeiro' then (select count(*) from fin.envios where criado_em > desde)
         when 'supervisor' then (select count(*) from sup.achados where status = 'aberto')
         else (select count(*) from rel.v_alertas al where al.agente_id = a.id and al.aberto_em > desde) end,
      'abertos', case a.id
         when 'radar' then 0
         when 'concorrentes' then (select count(*) from intel.ideias where status = 'sugerida')
         when 'financeiro' then (select count(*) from fin.pendencias where status = 'aberta')
         when 'supervisor' then (select count(*) from sup.achados where status = 'aberto')
         else (select count(*) from rel.v_alertas al where al.agente_id = a.id and al.status = 'aberto') end,
      'rotulo_novos', case a.id when 'radar' then 'notícias novas' when 'concorrentes' then 'anúncios novos'
         when 'financeiro' then 'arquivos recebidos' when 'supervisor' then 'achados abertos' else 'avisos novos' end,
      'rotulo_abertos', case a.id when 'concorrentes' then 'ideias para aprovar' when 'financeiro' then 'pendências abertas'
         when 'radar' then '' else 'em aberto' end) x
    from core.agentes a where a.status <> 'desativado') q;

  -- prioridades: candidatos de todas as áreas, com peso; ficam as N maiores
  with c(peso, area, unidade, texto, rota) as (
    select 99, 'Plataforma', null::text, format('%s incidente(s) aberto(s): %s', count(*), string_agg(titulo, '; ')), '/incidentes'
      from core.incidentes where status <> 'resolvido' having count(*) > 0
    union all
    -- concorrentes: no máximo 2 prioridades por dia (primeiro quem disputa com uma loja), o resto fica no quadro deles
    select peso, area, unidade, texto, rota from (
      select 92 - row_number() over (order by (k.unidade_id is not null) desc, count(*) desc)::int peso, 'Concorrentes' area,
             rel._unidade(k.unidade_id) unidade,
             format('%s colocou %s anúncio(s) novo(s) no ar%s', k.nome, count(*),
               coalesce(': "' || (array_agg(a.titulo order by a.inicio desc nulls last) filter (where coalesce(a.titulo,'') <> ''))[1] || '"', '')) texto,
             '/mercado' rota,
             row_number() over (order by (k.unidade_id is not null) desc, count(*) desc) rn
        from intel.anuncios a join intel.concorrentes k on k.id = a.concorrente_id
       where a.primeiro_visto > desde and k.ativo group by k.id, k.nome, k.unidade_id) cc
     where rn <= 2
    union all
    select 85, 'Financeiro', rel._unidade(f.unidade_id), f.descricao, '/enviar' from fin.arquivos_faltando() f
    union all
    select 82, 'Financeiro', null, format('%s pendência(s) financeira(s) bloqueando o fechamento', count(*)), '/pendencias'
      from fin.pendencias where status = 'aberta' and material having count(*) > 0
    union all
    select 80, 'Caixa', rel._unidade(unidade_id), format('%s caixa(s) com diferença nas últimas 24 h', count(*)), '/caixa'
      from cx.alertas where tipo = 'caixa_inconsistente' and aberto_em > desde group by unidade_id
    union all
    select 76, 'Laboratório', null, format('%s OS entraram em atraso ou parada nas últimas 24 h; %s com prazo vencido em aberto', count(*) filter (where aberto_em > desde),
             count(*) filter (where tipo = 'prazo_vencido')), '/laboratorio'
      from lab.alertas where status = 'aberto' and tipo in ('prazo_vencido','parado_na_etapa','refeito')
      having count(*) filter (where aberto_em > desde) > 0
    union all
    select 74, 'Marketing', null, format('%s alerta(s) de gasto sem resultado ou custo alto nas últimas 24 h', count(*)), '/marketing'
      from mkt.alertas where tipo in ('gasto_sem_resultado','custo_alto') and aberto_em > desde having count(*) > 0
    union all
    select 72, 'Cobranças', null, format('%s pagamento(s) sem baixa ou baixa sem pagamento em aberto', count(*)), '/cobrancas'
      from cob.alertas where status = 'aberto' and tipo in ('pago_sem_baixa','baixa_sem_pagamento') having count(*) > 0
    union all
    select 70, 'Comercial', null, format('%s cliente(s) esperando resposta no WhatsApp', count(*)), '/comercial'
      from com.alertas where status = 'aberto' and tipo = 'cliente_sem_resposta' having count(*) > 0
    union all
    select 66, 'RH', null, format('%s prazo(s) de RH vencido(s): experiência ou férias', count(*)), '/rh'
      from rh.alertas where status = 'aberto' and tipo in ('experiencia_vencida','ferias_vencidas') having count(*) > 0
    union all
    select 60, 'Concorrentes', null, format('%s ideia(s) dos concorrentes esperando sua decisão', count(*)), '/mercado'
      from intel.ideias where status = 'sugerida' having count(*) > 0
    union all
    select 55, 'Marketing', null, format('%s anúncio(s) reprovado(s) em aberto nas contas da Meta', count(*)), '/marketing'
      from mkt.alertas where status = 'aberto' and tipo = 'anuncio_reprovado' having count(*) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object('area', area, 'unidade', unidade, 'texto', texto, 'rota', rota, 'peso', peso) order by peso desc), '[]'::jsonb)
    into v_pri from (select * from c order by peso desc limit v_lim) q;

  select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'fonte', fonte, 'url', url, 'impacto', impacto, 'tema', tema,
      'relevancia', relevancia) order by relevancia desc, id desc), '[]'::jsonb)
    into v_merc from (select * from intel.noticias where criado_em > desde order by relevancia desc, id desc limit 6) q;

  v_conc := jsonb_build_object(
    'novos', (select coalesce(jsonb_agg(jsonb_build_object('concorrente', k.nome, 'praca', k.praca, 'titulo', a.titulo,
        'inicio', a.inicio, 'link', a.snapshot_url) order by a.inicio desc nulls last), '[]'::jsonb)
      from (select * from intel.anuncios where primeiro_visto > desde order by inicio desc nulls last limit 8) a
      join intel.concorrentes k on k.id = a.concorrente_id),
    'longos', (select coalesce(jsonb_agg(jsonb_build_object('concorrente', k.nome, 'praca', k.praca, 'titulo', a.titulo,
        'dias', (now()::date - a.inicio::date), 'link', a.snapshot_url) order by a.inicio), '[]'::jsonb)
      from (select distinct on (concorrente_id, coalesce(titulo, id)) * from intel.anuncios
             where ativo and inicio < now() - make_interval(days => v_longo) order by concorrente_id, coalesce(titulo, id), inicio) a
      join intel.concorrentes k on k.id = a.concorrente_id),
    'ideias', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'titulo', i.titulo, 'evidencia', i.evidencia,
        'como_aplicar', i.como_aplicar, 'link', i.link, 'concorrente', k.nome) order by i.criado_em desc), '[]'::jsonb)
      from (select * from intel.ideias where status = 'sugerida' order by criado_em desc limit 5) i
      left join intel.concorrentes k on k.id = i.concorrente_id));

  v := jsonb_build_object('dia', d, 'gerado_em', now(), 'desde', desde,
    'totais', jsonb_build_object(
      'agentes', (select count(*) from core.agentes where status = 'ativo'),
      'rodadas', (select count(*) from core.tarefas where criado_em > desde),
      'falhas', (select count(*) from core.tarefas where status in ('falhou','incerta') and atualizado_em > desde),
      'ideias', (select count(*) from intel.ideias where status = 'sugerida')),
    'prioridades', v_pri, 'agentes', v_ag, 'mercado', v_merc, 'concorrentes', v_conc);
  insert into rel.relatorios (dia, conteudo) values (d, v)
  on conflict (dia) do update set conteudo = excluded.conteudo, gerado_em = now(), versao = rel.relatorios.versao + 1;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Painel
-- ---------------------------------------------------------------------------
create or replace function public.painel_relatorio(p_dia date default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; d date := coalesce(p_dia, intel._hoje()); r record;
begin
  v_eu := painel._entrar('relatorio', d::text);
  if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão para o relatório da rede' using errcode = '42501'; end if;
  select * into r from rel.relatorios where dia = d;
  if r.dia is null and d = intel._hoje() then perform rel.gerar(d); select * into r from rel.relatorios where dia = d; end if;
  return jsonb_build_object('dia', d, 'existe', r.dia is not null, 'versao', r.versao, 'conteudo', r.conteudo,
    'pode_gerar', painel._pode(v_eu, 'administrar'),
    'dias', (select coalesce(jsonb_agg(dia order by dia desc), '[]'::jsonb) from (select dia from rel.relatorios order by dia desc limit 60) q));
end $$;

create or replace function public.painel_relatorio_gerar() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('relatorio_gerar');
  perform painel._exigir(v_eu, 'administrar');
  perform rel.gerar(intel._hoje());
  perform core.auditar(v_eu, null, 'relatorio_gerado', 'rel.relatorio', intel._hoje()::text, null, jsonb_build_object('canal', 'painel'));
  return public.painel_relatorio(intel._hoje());
end $$;

create or replace function public.painel_inteligencia() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_longo int := coalesce(nullif(core.cfg('intel.anuncio_longo_dias', '30'), '')::int, 30);
begin
  v_eu := painel._entrar('inteligencia');
  if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão' using errcode = '42501'; end if;
  return jsonb_build_object(
    'pode_editar', painel._pode(v_eu, 'administrar'),
    'anuncio_longo_dias', v_longo,
    'ultima_varredura', (select jsonb_object_agg(agente_id, em) from (select agente_id, max(em) em from intel.sincronizacoes group by 1) q),
    'concorrentes', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'nome', k.nome, 'praca', k.praca, 'unidade_id', k.unidade_id,
        'instagram', k.instagram, 'termo_busca', k.termo_busca, 'page_ids', k.page_ids, 'observacao', k.observacao, 'ativo', k.ativo,
        'anuncios_ativos', (select count(*) from intel.anuncios a where a.concorrente_id = k.id and a.ativo),
        'anuncios_novos_7d', (select count(*) from intel.anuncios a where a.concorrente_id = k.id and a.primeiro_visto > now() - interval '7 days'),
        'anuncios', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'titulo', a.titulo, 'page_nome', a.page_nome, 'inicio', a.inicio,
             'dias', (now()::date - a.inicio::date), 'link', a.snapshot_url, 'novo', a.primeiro_visto > now() - interval '24 hours') order by a.inicio desc nulls last), '[]'::jsonb)
           from (select * from intel.anuncios a where a.concorrente_id = k.id and a.ativo order by a.inicio desc nulls last limit 30) a)
      ) order by k.ativo desc, k.nome), '[]'::jsonb) from intel.concorrentes k),
    'noticias', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'dia', dia, 'titulo', titulo, 'fonte', fonte, 'url', url,
        'resumo', resumo, 'impacto', impacto, 'tema', tema, 'relevancia', relevancia) order by dia desc, relevancia desc, id desc), '[]'::jsonb)
      from (select * from intel.noticias order by dia desc, relevancia desc, id desc limit 60) n),
    'ideias', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'titulo', i.titulo, 'evidencia', i.evidencia, 'como_aplicar', i.como_aplicar,
        'link', i.link, 'status', i.status, 'nota', i.nota, 'criado_em', i.criado_em, 'decidido_em', i.decidido_em,
        'concorrente', (select nome from intel.concorrentes where id = i.concorrente_id)) order by
        case i.status when 'sugerida' then 0 when 'aprovada' then 1 else 2 end, i.criado_em desc), '[]'::jsonb)
      from (select * from intel.ideias order by criado_em desc limit 100) i));
end $$;

create or replace function public.painel_concorrente_salvar(p_id int, p_nome text, p_praca text default null, p_unidade text default null,
  p_instagram text default null, p_termo text default null, p_page_ids text[] default '{}', p_observacao text default null,
  p_ativo boolean default true) returns int
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_id int; v_antes jsonb; v_ig text := nullif(btrim(regexp_replace(coalesce(p_instagram, ''), '^(https?://(www\.)?instagram\.com/|@)', '', 'i'), '/ '), '');
begin
  v_eu := painel._entrar('concorrente_salvar', coalesce(p_id::text, p_nome));
  perform painel._exigir(v_eu, 'administrar');
  if length(btrim(coalesce(p_nome, ''))) < 2 then raise exception 'informe o nome do concorrente' using errcode = '22023'; end if;
  if v_ig is not null and v_ig !~ '^[A-Za-z0-9._]{1,30}$' then raise exception 'Instagram inválido: use só o @' using errcode = '22023'; end if;
  if p_unidade is not null and not exists (select 1 from core.unidades where id = p_unidade) then raise exception 'loja inválida' using errcode = '22023'; end if;
  if exists (select 1 from unnest(coalesce(p_page_ids, '{}')) x where x !~ '^[0-9]{5,25}$') then raise exception 'página do Facebook inválida (só números)' using errcode = '22023'; end if;
  if p_id is null then
    insert into intel.concorrentes (nome, praca, unidade_id, instagram, termo_busca, page_ids, observacao, ativo)
    values (btrim(p_nome), nullif(btrim(coalesce(p_praca, '')), ''), p_unidade, v_ig, nullif(btrim(coalesce(p_termo, '')), ''),
      coalesce(p_page_ids, '{}'), nullif(btrim(coalesce(p_observacao, '')), ''), coalesce(p_ativo, true))
    returning id into v_id;
  else
    select to_jsonb(k) into v_antes from intel.concorrentes k where id = p_id;
    if v_antes is null then raise exception 'concorrente inexistente' using errcode = '22023'; end if;
    update intel.concorrentes set nome = btrim(p_nome), praca = nullif(btrim(coalesce(p_praca, '')), ''), unidade_id = p_unidade, instagram = v_ig,
      termo_busca = nullif(btrim(coalesce(p_termo, '')), ''), page_ids = coalesce(p_page_ids, '{}'),
      observacao = nullif(btrim(coalesce(p_observacao, '')), ''), ativo = coalesce(p_ativo, true), atualizado_em = now()
     where id = p_id returning id into v_id;
  end if;
  perform core.auditar(v_eu, null, case when p_id is null then 'concorrente_incluido' else 'concorrente_alterado' end, 'intel.concorrente', v_id::text,
    v_antes, (select to_jsonb(k) from intel.concorrentes k where id = v_id));
  return v_id;
exception when unique_violation then
  raise exception 'já existe um concorrente com esse nome' using errcode = '22023';
end $$;

create or replace function public.painel_ideia_decidir(p_id bigint, p_status text, p_nota text default null) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; i record;
begin
  v_eu := painel._entrar('ideia_decidir', p_id::text);
  perform painel._exigir(v_eu, 'administrar');
  if p_status not in ('aprovada','descartada','feita','sugerida') then raise exception 'situação inválida' using errcode = '22023'; end if;
  select * into i from intel.ideias where id = p_id for update;
  if i.id is null then raise exception 'ideia inexistente' using errcode = '22023'; end if;
  update intel.ideias set status = p_status, nota = coalesce(nullif(btrim(coalesce(p_nota, '')), ''), nota), decidido_por = v_eu, decidido_em = now()
   where id = p_id;
  perform core.auditar(v_eu, null, 'ideia_' || p_status, 'intel.ideia', p_id::text, jsonb_build_object('status', i.status),
    jsonb_build_object('status', p_status, 'canal', 'painel'), nullif(btrim(coalesce(p_nota, '')), ''));
end $$;

-- ---------------------------------------------------------------------------
-- 6. Permissões
-- ---------------------------------------------------------------------------
do $$ declare f text; begin
  foreach f in array array['intel._hoje()', 'intel.iniciar(text,text)', 'intel.falhar(uuid,text,text)', 'intel.concluir_radar(uuid,text,jsonb)',
    'intel.concluir_concorrentes(uuid,text,jsonb,int[],jsonb)', 'rel._unidade(text)', 'rel.gerar(date)',
    'public.painel_relatorio(date)', 'public.painel_relatorio_gerar()', 'public.painel_inteligencia()',
    'public.painel_concorrente_salvar(int,text,text,text,text,text,text[],text,boolean)', 'public.painel_ideia_decidir(bigint,text,text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', f); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    foreach f in array array['intel._hoje()', 'intel.iniciar(text,text)', 'intel.falhar(uuid,text,text)', 'intel.concluir_radar(uuid,text,jsonb)',
      'intel.concluir_concorrentes(uuid,text,jsonb,int[],jsonb)', 'rel._unidade(text)', 'rel.gerar(date)'] loop
      execute format('revoke all on function %s from authenticated', f);
    end loop;
    foreach f in array array['public.painel_relatorio(date)', 'public.painel_relatorio_gerar()', 'public.painel_inteligencia()',
      'public.painel_concorrente_salvar(int,text,text,text,text,text,text[],text,boolean)', 'public.painel_ideia_decidir(bigint,text,text)'] loop
      execute format('grant execute on function %s to authenticated', f);
    end loop;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema intel to service_role';
    foreach f in array array['intel.iniciar(text,text)', 'intel.falhar(uuid,text,text)', 'intel.concluir_radar(uuid,text,jsonb)',
      'intel.concluir_concorrentes(uuid,text,jsonb,int[],jsonb)'] loop
      execute format('grant execute on function %s to service_role', f);
    end loop;
  end if;
end $$;

-- relatório às 07h (horário de Brasília), quando o agendador existe (no banco de testes não existe).
-- Radar (06h) e Concorrentes (06h15) rodam como tarefas agendadas do Claude, com busca na web e a Biblioteca de
-- Anúncios, e devolvem o resultado por intel.iniciar / intel.concluir_* (mesma esteira, auditoria e validação).
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'rel-relatorio';
    perform cron.schedule('rel-relatorio', '0 10 * * *', 'select rel.gerar()');
  end if;
end $$;
