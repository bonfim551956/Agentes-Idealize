-- =============================================================================
-- Idealize AI — Agentes de Conteúdo (Ideias, Avaliador, Roteirista)  · Migração 20261107060000
-- Pedido do Diego (07/11, PODE FAZER): "um agente trazendo ideias, outro avaliando e um roteirizando com experiência
-- master sênior em copy" — Reels cena por cena, com gancho e roteiro completo, todo dia.
--  • cont.ideias   — ideias do dia (Ideias), com a nota e o parecer do Avaliador.
--  • cont.roteiros — roteiros prontos para gravar (Roteirista): cenas com tempo, o que aparece, fala e texto na tela,
--                    capa, trilha, legenda e CTA. O Diego aprova, pede ajuste ou descarta pelo painel e marca gravado
--                    e publicado; isso volta como aprendizado para os agentes no dia seguinte.
--  • Regras (quantidade, nota mínima, foco, ofertas, tom, rosto, proibições) ficam em core.config e o Diego muda
--    pela tela Conteúdo → Regras dos agentes.
-- Os três rodam como tarefas agendadas do Claude (pesquisa e escrita) e passam pela esteira de sempre
-- (tarefa → execução → validação → auditoria). Não publicam nada nem falam com ninguém: só gravam aqui.
-- Quem aprova é o Avaliador, pela regra do banco (nota mínima e quantidade do dia), não quem teve a ideia.
-- =============================================================================
create schema if not exists cont;
revoke all on schema cont from public;

-- ---------------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------------
create table cont.ideias (
  id           bigserial primary key,
  dia          date not null,
  titulo       text not null check (length(btrim(titulo)) between 5 and 200),
  formato      text not null default 'reel' check (formato in ('reel','carrossel','stories','imagem')),
  unidade_id   text references core.unidades(id),               -- loja (nulo = todas)
  gancho       text,                                            -- a frase dos 3 primeiros segundos
  conceito     text,                                            -- o que acontece no vídeo, em 2 a 3 frases
  evidencia    text,                                            -- por que deve funcionar (com número/fonte)
  fonte        text,                                            -- concorrentes | radar | historico | data | oferta
  status       text not null default 'nova' check (status in ('nova','aprovada','descartada')),
  nota         int check (nota between 0 and 100),
  criterios    jsonb,                                           -- {gancho, prova, oferta, gravacao, marca} 0–20 cada
  parecer      text,                                            -- por que passou ou não passou
  promovida_por uuid references core.principais(id),            -- Diego mandou roteirizar uma descartada
  tarefa_id    uuid references core.tarefas(id),
  avaliada_em  timestamptz,
  criado_em    timestamptz not null default now()
);
create index cont_ideias_dia on cont.ideias (dia desc, nota desc nulls last);
create index cont_ideias_status on cont.ideias (status, dia desc);

create table cont.roteiros (
  id            bigserial primary key,
  ideia_id      bigint references cont.ideias(id),
  dia           date not null,
  titulo        text not null check (length(btrim(titulo)) between 5 and 200),
  formato       text not null default 'reel' check (formato in ('reel','carrossel','stories','imagem')),
  unidade_id    text references core.unidades(id),
  duracao_s     int check (duracao_s between 5 and 180),
  gancho        text not null,
  cenas         jsonb not null check (jsonb_typeof(cenas) = 'array'),   -- [{tempo, tipo, aparece, fala, tela}]
  capa          text,
  trilha        text,
  legenda       text,
  cta           text,
  observacoes   text,                                           -- dicas de gravação e cuidados
  status        text not null default 'pronto' check (status in ('pronto','aprovado','ajuste','descartado','gravado','publicado')),
  pedido_ajuste text,                                           -- o que o Diego pediu para mudar
  historico     jsonb not null default '[]',                    -- versões anteriores (ajustes)
  versao        int not null default 1,
  nota_diego    text,                                           -- comentário dele ao decidir
  link          text check (link is null or link ~ '^https?://'),
  anuncio_nome  text,                                           -- nome do anúncio no Meta, para ligar ao resultado
  decidido_por  uuid references core.principais(id),
  decidido_em   timestamptz,
  tarefa_id     uuid references core.tarefas(id),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index cont_roteiros_status on cont.roteiros (status, dia desc);
create index cont_roteiros_dia on cont.roteiros (dia desc);
create unique index cont_roteiros_ideia on cont.roteiros (ideia_id) where ideia_id is not null;

do $$ begin
  revoke all on all tables in schema cont from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema cont from anon, authenticated';
  end if;
end $$;
alter table cont.ideias enable row level security; alter table cont.ideias force row level security;
alter table cont.roteiros enable row level security; alter table cont.roteiros force row level security;

-- ---------------------------------------------------------------------------
-- 2. Agentes, papel, políticas, regras e Supervisor
-- ---------------------------------------------------------------------------
insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('conteudo_ideias', 'Ideias de Conteúdo', 'comercial', 'ativo', '0.1.0',
   'Todo dia traz ideias de Reels a partir do que os concorrentes mantêm no ar, das notícias do Radar, das datas e ofertas do mês e do que o Diego já aprovou, gravou ou descartou. Cada ideia vem com gancho e evidência.'),
  ('conteudo_avaliador', 'Avaliador de Conteúdo', 'comercial', 'ativo', '0.1.0',
   'Diretor criativo exigente: dá nota de 0 a 100 a cada ideia (gancho, prova, oferta clara, facilidade de gravar, cara da Idealize). Passam só as melhores acima da nota mínima; o descarte vem com o motivo.'),
  ('conteudo_roteirista', 'Roteirista', 'comercial', 'ativo', '0.1.0',
   'Copywriter sênior de resposta direta: transforma as ideias aprovadas em roteiro pronto para gravar, cena por cena (tempo, o que aparece, fala, texto na tela), com capa, trilha, legenda e CTA para o WhatsApp. Refaz os roteiros em que o Diego pediu ajuste.')
on conflict (id) do nothing;
insert into core.papeis (id, nome) values ('agente_conteudo', 'Agentes de conteúdo (máquina)') on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', v.n, v.a from (values ('Ideias de Conteúdo', 'conteudo_ideias'), ('Avaliador de Conteúdo', 'conteudo_avaliador'),
  ('Roteirista', 'conteudo_roteirista')) v(n, a)
where not exists (select 1 from core.principais where agente_id = v.a);
insert into core.principal_papeis (principal_id, papel_id)
select id, 'agente_conteudo' from core.principais where agente_id in ('conteudo_ideias','conteudo_avaliador','conteudo_roteirista') on conflict do nothing;
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_conteudo', 'cont.conteudo', 'criar', 'baixo', 'automatica'
where not exists (select 1 from core.politicas where papel_id = 'agente_conteudo' and recurso = 'cont.conteudo' and operacao = 'criar' and ativo);
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_conteudo', 'cont.conteudo', v.op, 'alto', 'proibida'
from (values ('publicar'), ('enviar_mensagem'), ('comentar'), ('criar_anuncio'), ('contatar')) v(op)
where not exists (select 1 from core.politicas where papel_id = 'agente_conteudo' and recurso = 'cont.conteudo' and operacao = v.op and ativo);

insert into core.config (chave, valor) values
  ('cont.ideias.ativo', 'true'), ('cont.avaliador.ativo', 'true'), ('cont.roteirista.ativo', 'true'),
  ('cont.ideias_por_dia', '10'),
  ('cont.nota_minima', '75'),
  ('cont.roteiros_por_dia', '3'),
  ('cont.formatos', 'reel'),
  ('cont.foco', 'Black Friday Idealize em 27/11 nas 4 lojas: esquenta, Grupos VIP, ofertas e contagem regressiva. Depois da Black: fim de ano e 13º salário.'),
  ('cont.ofertas', '2 óculos de grau por R$ 199,90 (grau até ±0,25); visão simples a partir de R$ 149,90; 10x sem juros; lentes LIGHT, EXTRA, RUBI e SAPHIRA; multifocais de 45% a 98%; lente fotossensível; exame de vista sem custo com a Visão Ideal; Técnica A ou B no fechamento.'),
  ('cont.tom', 'Próximo, direto e bem-humorado, português do Brasil falado. Frases curtas. Nada de exagero nem de linguagem de anúncio velho.'),
  ('cont.rosto', 'Influencer da campanha, gravando na loja de São Vicente; time da loja e clientes reais com autorização.'),
  ('cont.proibido', 'Promessa de cura, diagnóstico ou resultado de saúde; preço sem as condições; falar mal de concorrente pelo nome; usar música, marca ou personagem de terceiros; mostrar cliente sem autorização.')
on conflict (chave) do nothing;

insert into sup.limites (agente_id, chave_ativo, max_minutos) values
  ('conteudo_ideias', 'cont.ideias.ativo', 1560), ('conteudo_avaliador', 'cont.avaliador.ativo', 1560),
  ('conteudo_roteirista', 'cont.roteirista.ativo', 1560)
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
  union all select 'concorrentes', max(em) from intel.sincronizacoes where agente_id = 'concorrentes'
  union all select 'conteudo_ideias', max(em) from intel.sincronizacoes where agente_id = 'conteudo_ideias'
  union all select 'conteudo_avaliador', max(em) from intel.sincronizacoes where agente_id = 'conteudo_avaliador'
  union all select 'conteudo_roteirista', max(em) from intel.sincronizacoes where agente_id = 'conteudo_roteirista';

-- ---------------------------------------------------------------------------
-- 3. Esteira
-- ---------------------------------------------------------------------------
create or replace function cont._int(p_chave text, p_padrao int) returns int
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(case when core.cfg(p_chave, '') ~ '^\d{1,4}$' then core.cfg(p_chave, '')::int end, p_padrao)
$$;

create or replace function cont._regras() returns jsonb
language sql stable security definer set search_path = core, pg_catalog as $$
  select jsonb_build_object(
    'ideias_por_dia', cont._int('cont.ideias_por_dia', 10), 'nota_minima', cont._int('cont.nota_minima', 75),
    'roteiros_por_dia', cont._int('cont.roteiros_por_dia', 3),
    'formatos', to_jsonb(string_to_array(regexp_replace(core.cfg('cont.formatos', 'reel'), '\s', '', 'g'), ',')),
    'foco', core.cfg('cont.foco', ''), 'ofertas', core.cfg('cont.ofertas', ''), 'tom', core.cfg('cont.tom', ''),
    'rosto', core.cfg('cont.rosto', ''), 'proibido', core.cfg('cont.proibido', ''),
    'ativos', jsonb_build_object('ideias', core.cfg('cont.ideias.ativo', 'false') = 'true',
      'avaliador', core.cfg('cont.avaliador.ativo', 'false') = 'true', 'roteirista', core.cfg('cont.roteirista.ativo', 'false') = 'true'))
$$;

-- o que o Diego já decidiu: é o aprendizado dos três agentes
create or replace function cont._aprendizado() returns jsonb
language sql stable security definer set search_path = cont, core, pg_catalog as $$
  select jsonb_build_object(
    'diego_aprovou', (select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'gancho', gancho, 'status', status, 'nota_diego', nota_diego,
         'anuncio', anuncio_nome) order by decidido_em desc), '[]'::jsonb)
       from (select * from cont.roteiros where status in ('aprovado','gravado','publicado') order by decidido_em desc nulls last limit 15) q),
    'diego_descartou', (select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'gancho', gancho, 'motivo', nota_diego) order by decidido_em desc), '[]'::jsonb)
       from (select * from cont.roteiros where status = 'descartado' order by decidido_em desc nulls last limit 15) q),
    'ajustes_pedidos', (select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'pedido', h->>'pedido_ajuste')), '[]'::jsonb)
       from (select r.titulo, h from cont.roteiros r, jsonb_array_elements(r.historico) h order by r.atualizado_em desc limit 15) q))
$$;

-- p_agente: 'ideias' | 'avaliador' | 'roteirista'; p_modo 'ajustes' (só roteirista): refaz os pedidos de ajuste do dia
create or replace function cont.iniciar(p_agente text, p_executor text, p_modo text default 'diario') returns jsonb
language plpgsql security definer set search_path = cont, intel, core, pg_catalog as $$
declare v_ag text; v_p uuid; v_t uuid; x record; d date := intel._hoje(); v_chave text; v_ctx jsonb; v_nada boolean := false;
begin
  if p_agente not in ('ideias','avaliador','roteirista') then raise exception 'agente inválido'; end if;
  if p_modo not in ('diario','ajustes') or (p_modo = 'ajustes' and p_agente <> 'roteirista') then raise exception 'modo inválido'; end if;
  v_ag := 'conteudo_' || p_agente;
  if core.cfg('cont.' || p_agente || '.ativo', 'false') <> 'true' then return jsonb_build_object('status', 'desligado'); end if;
  if (select status from core.agentes where id = v_ag) <> 'ativo' then return jsonb_build_object('status', 'pausado'); end if;

  -- o que cada um precisa para trabalhar (e se há trabalho)
  if p_agente = 'ideias' then
    v_ctx := jsonb_build_object(
      'unidades', (select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome) from core.unidades where id <> 'administrativo'),
      'concorrentes_longos', (select coalesce(jsonb_agg(jsonb_build_object('concorrente', k.nome, 'praca', k.praca, 'titulo', a.titulo,
           'dias_no_ar', d - a.inicio::date, 'versoes', a.n, 'link', a.link) order by d - a.inicio::date desc), '[]'::jsonb)
         from (select concorrente_id, titulo, min(inicio) inicio, count(*) n, min(snapshot_url) link from intel.anuncios
                where ativo and inicio < now() - interval '14 days' and coalesce(titulo, '') <> '' group by concorrente_id, titulo
                order by min(inicio) limit 25) a join intel.concorrentes k on k.id = a.concorrente_id),
      'concorrentes_novos', (select coalesce(jsonb_agg(jsonb_build_object('concorrente', k.nome, 'titulo', a.titulo, 'inicio', a.inicio::date)), '[]'::jsonb)
         from (select * from intel.anuncios where primeiro_visto > now() - interval '7 days' and coalesce(titulo, '') <> '' order by inicio desc limit 20) a
         join intel.concorrentes k on k.id = a.concorrente_id),
      'noticias', (select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'impacto', impacto)), '[]'::jsonb)
         from (select * from intel.noticias where dia > d - 7 order by relevancia desc, id desc limit 8) n),
      'ideias_concorrentes', (select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'como_aplicar', como_aplicar, 'status', status)), '[]'::jsonb)
         from (select * from intel.ideias where status <> 'descartada' order by criado_em desc limit 10) i),
      'ja_propostas', (select coalesce(jsonb_agg(titulo), '[]'::jsonb) from (select titulo from cont.ideias where dia > d - 30 order by id desc limit 120) q),
      'avaliador_reprovou', (select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'nota', nota, 'parecer', parecer)), '[]'::jsonb)
         from (select * from cont.ideias where status = 'descartada' and parecer is not null order by id desc limit 15) q));
  elsif p_agente = 'avaliador' then
    if not exists (select 1 from cont.ideias where dia = d and status = 'nova') then
      return jsonb_build_object('status', 'aguardando', 'motivo', 'nenhuma ideia nova hoje: o agente de Ideias ainda não terminou');
    end if;
    v_ctx := jsonb_build_object('ideias', (select jsonb_agg(jsonb_build_object('id', id, 'titulo', titulo, 'formato', formato,
        'loja', rel._unidade(unidade_id), 'gancho', gancho, 'conceito', conceito, 'evidencia', evidencia, 'fonte', fonte) order by id)
      from cont.ideias where dia = d and status = 'nova'));
  else
    v_ctx := jsonb_build_object(
      'ideias', case when p_modo = 'diario' then (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'titulo', i.titulo, 'formato', i.formato,
          'unidade_id', i.unidade_id, 'loja', rel._unidade(i.unidade_id), 'gancho', i.gancho, 'conceito', i.conceito, 'evidencia', i.evidencia,
          'nota', i.nota, 'parecer', i.parecer) order by i.nota desc nulls last), '[]'::jsonb)
        from cont.ideias i where i.status = 'aprovada' and i.dia > d - 7 and not exists (select 1 from cont.roteiros r where r.ideia_id = i.id))
        else '[]'::jsonb end,
      'ajustes', (select coalesce(jsonb_agg(jsonb_build_object('roteiro_id', r.id, 'pedido_ajuste', r.pedido_ajuste, 'titulo', r.titulo,
          'formato', r.formato, 'loja', rel._unidade(r.unidade_id), 'duracao_s', r.duracao_s, 'gancho', r.gancho, 'cenas', r.cenas, 'capa', r.capa,
          'trilha', r.trilha, 'legenda', r.legenda, 'cta', r.cta, 'observacoes', r.observacoes) order by r.decidido_em), '[]'::jsonb)
        from cont.roteiros r where r.status = 'ajuste'),
      'exemplos_aprovados', (select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'gancho', gancho, 'cenas', cenas, 'legenda', legenda)), '[]'::jsonb)
        from (select * from cont.roteiros where status in ('aprovado','gravado','publicado') order by decidido_em desc nulls last limit 3) q));
    v_nada := jsonb_array_length(v_ctx->'ideias') = 0 and jsonb_array_length(v_ctx->'ajustes') = 0;
    if v_nada and p_modo = 'ajustes' then return jsonb_build_object('status', 'nada_a_fazer'); end if;
  end if;

  v_chave := v_ag || ':' || p_modo || ':' || to_char(d, 'YYYYMMDD') || case when p_modo = 'ajustes' then ':' || to_char(now(), 'HH24MI') else '' end;
  select id into v_p from core.principais where agente_id = v_ag;
  v_t := core.criar_tarefa(v_p, v_ag, v_ag || '_' || p_modo, 'cont.conteudo', 'criar', null, jsonb_build_object('dia', d, 'modo', p_modo), v_chave, null, 6);
  if (select status from core.tarefas where id = v_t) in ('concluida', 'validando') then
    return jsonb_build_object('status', 'ja_feita', 'tarefa', v_t);
  end if;
  update core.tarefas set prioridade = 1 where id = v_t and status = 'pronta';
  select * into x from core.reivindicar(v_ag, p_executor, 1800) where id = v_t;
  if x.id is null then return jsonb_build_object('status', 'ocupada', 'tarefa', v_t); end if;

  -- roteirista sem nada para escrever hoje: fecha a rodada (o Supervisor vê que ele passou) e avisa
  if v_nada then
    insert into intel.sincronizacoes (agente_id, tarefa_id, resumo) values (v_ag, v_t, jsonb_build_object('roteiros', 0, 'ajustes', 0));
    perform core.registrar_execucao(v_t, p_executor, 'sucesso', null, jsonb_build_object('roteiros', 0, 'motivo', 'nenhuma ideia aprovada'));
    perform core.registrar_validacao(v_t, 'validador_sql', true, null, jsonb_build_object('roteiros', 0));
    return jsonb_build_object('status', 'nada_a_fazer', 'tarefa', v_t);
  end if;

  return jsonb_build_object('status', 'ok', 'tarefa', v_t, 'dia', d, 'modo', p_modo, 'regras', cont._regras(),
    'aprendizado', cont._aprendizado()) || v_ctx;
end $$;

create or replace function cont.falhar(p_tarefa uuid, p_executor text, p_erro text) returns text
language plpgsql security definer set search_path = cont, core, pg_catalog as $$
begin
  if (select agente_id from core.tarefas where id = p_tarefa) not like 'conteudo\_%' then raise exception 'tarefa não é de conteúdo'; end if;
  return core.registrar_execucao(p_tarefa, p_executor, 'erro', null, null, left(coalesce(p_erro, 'falha sem detalhe'), 300));
end $$;

-- Ideias: p_ideias = [{titulo, formato, unidade_id?, gancho, conceito, evidencia, fonte}]
create or replace function cont.concluir_ideias(p_tarefa uuid, p_executor text, p_ideias jsonb) returns jsonb
language plpgsql security definer set search_path = cont, intel, core, pg_catalog as $$
declare t record; x jsonb; n int := 0; d int := 0; v jsonb; v_lim int := cont._int('cont.ideias_por_dia', 10);
  v_form text[] := string_to_array(regexp_replace(core.cfg('cont.formatos', 'reel'), '\s', '', 'g'), ','); v_fmt text;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'conteudo_ideias' or t.status <> 'executando' then raise exception 'tarefa não é do agente de Ideias em execução'; end if;
  if jsonb_typeof(coalesce(p_ideias, '[]')) <> 'array' then raise exception 'ideias inválidas'; end if;
  for x in select * from jsonb_array_elements(p_ideias) loop
    v_fmt := coalesce(nullif(lower(btrim(x->>'formato')), ''), 'reel');
    if n >= v_lim or length(btrim(coalesce(x->>'titulo', ''))) < 5 or length(btrim(coalesce(x->>'gancho', ''))) < 5
       or not v_fmt = any(v_form)
       or exists (select 1 from cont.ideias where lower(titulo) = lower(btrim(x->>'titulo')) and dia > intel._hoje() - 30) then
      d := d + 1; continue;
    end if;
    insert into cont.ideias (dia, titulo, formato, unidade_id, gancho, conceito, evidencia, fonte, tarefa_id)
    values (intel._hoje(), left(btrim(x->>'titulo'), 200), v_fmt,
      (select id from core.unidades where id = nullif(x->>'unidade_id', '') and id <> 'administrativo'),
      left(btrim(x->>'gancho'), 400), left(x->>'conceito', 1500), left(x->>'evidencia', 1000), left(x->>'fonte', 60), p_tarefa);
    n := n + 1;
  end loop;
  v := jsonb_build_object('ideias', n, 'recusadas', d);
  insert into intel.sincronizacoes (agente_id, tarefa_id, resumo) values ('conteudo_ideias', p_tarefa, v);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', null, v);
  if n > 0 and (select count(*) from cont.ideias where tarefa_id = p_tarefa) = n then
    perform core.registrar_validacao(p_tarefa, 'validador_sql', true, null, v);
  else
    perform core.registrar_validacao(p_tarefa, 'validador_sql', false, case when n = 0 then 'nenhuma ideia válida' else 'ideias gravadas não conferem' end, v);
  end if;
  return v;
end $$;

-- Avaliador: p_avaliacoes = [{ideia_id, criterios:{gancho,prova,oferta,gravacao,marca} (0–20 cada), parecer}]
-- A aprovação é do banco: as N maiores notas que atingem a nota mínima (regras do Diego).
create or replace function cont.concluir_avaliacao(p_tarefa uuid, p_executor text, p_avaliacoes jsonb) returns jsonb
language plpgsql security definer set search_path = cont, intel, core, pg_catalog as $$
declare t record; x jsonb; c jsonb; v_nota int; n int := 0; v jsonb; v_ok int; v_min int := cont._int('cont.nota_minima', 75);
  v_qtd int := cont._int('cont.roteiros_por_dia', 3); k text; v_c int;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'conteudo_avaliador' or t.status <> 'executando' then raise exception 'tarefa não é do Avaliador em execução'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_avaliacoes, '[]')) loop
    if not exists (select 1 from cont.ideias where id = nullif(x->>'ideia_id', '')::bigint and status = 'nova') then continue; end if;
    c := '{}'; v_nota := 0;
    foreach k in array array['gancho','prova','oferta','gravacao','marca'] loop
      v_c := least(greatest(coalesce(case when x->'criterios'->>k ~ '^\d{1,3}$' then (x->'criterios'->>k)::int end, 0), 0), 20);
      c := c || jsonb_build_object(k, v_c); v_nota := v_nota + v_c;
    end loop;
    update cont.ideias set nota = v_nota, criterios = c, parecer = left(x->>'parecer', 800), avaliada_em = now()
     where id = (x->>'ideia_id')::bigint;
    n := n + 1;
  end loop;
  -- decide: as melhores do dia acima da nota mínima viram roteiro; o resto fica descartado com o parecer
  with r as (select id, row_number() over (order by nota desc, id) rn, nota from cont.ideias
              where dia = intel._hoje() and status = 'nova' and nota is not null)
  update cont.ideias i set status = case when r.nota >= v_min and r.rn <= v_qtd then 'aprovada' else 'descartada' end
    from r where r.id = i.id;
  select count(*) into v_ok from cont.ideias where dia = intel._hoje() and status = 'aprovada' and avaliada_em > now() - interval '1 hour';
  v := jsonb_build_object('avaliadas', n, 'aprovadas', v_ok, 'descartadas', n - v_ok, 'nota_minima', v_min);
  insert into intel.sincronizacoes (agente_id, tarefa_id, resumo) values ('conteudo_avaliador', p_tarefa, v);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', null, v);
  if n > 0 and not exists (select 1 from cont.ideias where dia = intel._hoje() and status = 'nova') then
    perform core.registrar_validacao(p_tarefa, 'validador_sql', true, null, v);
  else
    perform core.registrar_validacao(p_tarefa, 'validador_sql', false, 'ideias do dia ficaram sem avaliação', v);
  end if;
  return v;
end $$;

-- Roteirista: p_roteiros = [{ideia_id | roteiro_id (ajuste), titulo, formato, duracao_s, gancho,
--   cenas:[{tempo, tipo (gancho|desenvolvimento|prova|cta), aparece, fala, tela}], capa, trilha, legenda, cta, observacoes}]
create or replace function cont.concluir_roteiros(p_tarefa uuid, p_executor text, p_roteiros jsonb) returns jsonb
language plpgsql security definer set search_path = cont, intel, core, pg_catalog as $$
declare t record; x jsonb; n_novos int := 0; n_aj int := 0; d int := 0; v jsonb; i record; r record; v_ids bigint[] := '{}'; v_id bigint;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'conteudo_roteirista' or t.status <> 'executando' then raise exception 'tarefa não é do Roteirista em execução'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_roteiros, '[]')) loop
    -- roteiro bom tem gancho e pelo menos 3 cenas com o que aparece e o que se fala ou escreve
    if length(btrim(coalesce(x->>'gancho', ''))) < 5 or length(btrim(coalesce(x->>'titulo', ''))) < 5
       or jsonb_typeof(x->'cenas') <> 'array' or jsonb_array_length(x->'cenas') < 3
       or exists (select 1 from jsonb_array_elements(x->'cenas') e
                   where length(btrim(coalesce(e->>'aparece', ''))) < 3 or length(btrim(coalesce(e->>'fala', '') || coalesce(e->>'tela', ''))) < 3) then
      d := d + 1; continue;
    end if;
    if nullif(x->>'roteiro_id', '') is not null then
      select * into r from cont.roteiros where id = (x->>'roteiro_id')::bigint and status = 'ajuste' for update;
      if r.id is null then d := d + 1; continue; end if;
      update cont.roteiros set
        historico = historico || jsonb_build_array(jsonb_build_object('versao', r.versao, 'em', now(), 'pedido_ajuste', r.pedido_ajuste,
          'gancho', r.gancho, 'cenas', r.cenas, 'legenda', r.legenda)),
        versao = r.versao + 1, titulo = left(btrim(x->>'titulo'), 200), duracao_s = least(greatest(nullif(x->>'duracao_s', '')::int, 5), 180),
        gancho = left(btrim(x->>'gancho'), 400), cenas = x->'cenas', capa = left(x->>'capa', 300), trilha = left(x->>'trilha', 300),
        legenda = left(x->>'legenda', 2200), cta = left(x->>'cta', 300), observacoes = left(x->>'observacoes', 1500),
        status = 'pronto', pedido_ajuste = null, tarefa_id = p_tarefa, atualizado_em = now()
       where id = r.id;
      v_ids := v_ids || r.id; n_aj := n_aj + 1;
    else
      select * into i from cont.ideias where id = nullif(x->>'ideia_id', '')::bigint and status = 'aprovada'
         and not exists (select 1 from cont.roteiros where ideia_id = cont.ideias.id);
      if i.id is null then d := d + 1; continue; end if;
      insert into cont.roteiros (ideia_id, dia, titulo, formato, unidade_id, duracao_s, gancho, cenas, capa, trilha, legenda, cta, observacoes, tarefa_id)
      values (i.id, intel._hoje(), left(btrim(x->>'titulo'), 200), i.formato, i.unidade_id,
        least(greatest(nullif(x->>'duracao_s', '')::int, 5), 180), left(btrim(x->>'gancho'), 400), x->'cenas',
        left(x->>'capa', 300), left(x->>'trilha', 300), left(x->>'legenda', 2200), left(x->>'cta', 300), left(x->>'observacoes', 1500), p_tarefa)
      returning id into v_id;
      v_ids := v_ids || v_id; n_novos := n_novos + 1;
    end if;
  end loop;
  v := jsonb_build_object('roteiros', n_novos, 'ajustes', n_aj, 'recusados', d);
  insert into intel.sincronizacoes (agente_id, tarefa_id, resumo) values ('conteudo_roteirista', p_tarefa, v);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', null, v);
  if n_novos + n_aj > 0 and (select count(*) from cont.roteiros where id = any(v_ids) and status = 'pronto') = n_novos + n_aj then
    perform core.registrar_validacao(p_tarefa, 'validador_sql', true, null, v);
  else
    perform core.registrar_validacao(p_tarefa, 'validador_sql', false, case when n_novos + n_aj = 0 then 'nenhum roteiro válido' else 'roteiros gravados não conferem' end, v);
  end if;
  -- relatório do dia já montado: atualiza para os roteiros aparecerem nele
  if exists (select 1 from rel.relatorios where dia = intel._hoje()) then perform rel.gerar(intel._hoje()); end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Relatório do dia (inclui os três agentes e os roteiros para aprovar)
-- ---------------------------------------------------------------------------
create or replace function rel.gerar(p_dia date default null) returns jsonb
language plpgsql security definer set search_path = rel, intel, core, pg_catalog as $$
declare d date := coalesce(p_dia, intel._hoje()); desde timestamptz := now() - interval '24 hours';
  v_ag jsonb; v_pri jsonb; v_merc jsonb; v_conc jsonb; v_cont jsonb; v jsonb; v_lim int := coalesce(nullif(core.cfg('rel.prioridades', '5'), '')::int, 5);
  v_longo int := coalesce(nullif(core.cfg('intel.anuncio_longo_dias', '30'), '')::int, 30);
begin
  -- o que cada agente fez
  select coalesce(jsonb_agg(x order by x->>'ordem', x->>'nome'), '[]'::jsonb) into v_ag from (
    select jsonb_build_object('id', a.id, 'nome', a.nome, 'status', a.status,
      'ordem', case when a.id in ('radar','concorrentes') then '0' when a.id like 'conteudo\_%' then '1' when a.id = 'supervisor' then '9' else '5' end,
      'rodadas', (select count(*) from core.tarefas t where t.agente_id = a.id and t.criado_em > desde),
      'falhas', (select count(*) from core.tarefas t where t.agente_id = a.id and t.status in ('falhou','incerta') and t.atualizado_em > desde),
      'novos', case a.id
         when 'radar' then (select count(*) from intel.noticias where criado_em > desde)
         when 'concorrentes' then (select count(*) from intel.anuncios where primeiro_visto > desde)
         when 'conteudo_ideias' then (select count(*) from cont.ideias where criado_em > desde)
         when 'conteudo_avaliador' then (select count(*) from cont.ideias where avaliada_em > desde)
         when 'conteudo_roteirista' then (select count(*) from cont.roteiros where atualizado_em > desde and status = 'pronto')
         when 'financeiro' then (select count(*) from fin.envios where criado_em > desde)
         when 'supervisor' then (select count(*) from sup.achados where status = 'aberto')
         else (select count(*) from rel.v_alertas al where al.agente_id = a.id and al.aberto_em > desde) end,
      'abertos', case a.id
         when 'radar' then 0
         when 'concorrentes' then (select count(*) from intel.ideias where status = 'sugerida')
         when 'conteudo_ideias' then 0
         when 'conteudo_avaliador' then (select count(*) from cont.ideias where avaliada_em > desde and status = 'aprovada')
         when 'conteudo_roteirista' then (select count(*) from cont.roteiros where status = 'pronto')
         when 'financeiro' then (select count(*) from fin.pendencias where status = 'aberta')
         when 'supervisor' then (select count(*) from sup.achados where status = 'aberto')
         else (select count(*) from rel.v_alertas al where al.agente_id = a.id and al.status = 'aberto') end,
      'rotulo_novos', case a.id when 'radar' then 'notícias novas' when 'concorrentes' then 'anúncios novos'
         when 'conteudo_ideias' then 'ideias novas' when 'conteudo_avaliador' then 'ideias avaliadas' when 'conteudo_roteirista' then 'roteiros escritos'
         when 'financeiro' then 'arquivos recebidos' when 'supervisor' then 'achados abertos' else 'avisos novos' end,
      'rotulo_abertos', case a.id when 'concorrentes' then 'ideias para aprovar' when 'financeiro' then 'pendências abertas'
         when 'conteudo_avaliador' then 'aprovadas para roteiro' when 'conteudo_roteirista' then 'roteiros para você aprovar'
         when 'radar' then '' when 'conteudo_ideias' then '' else 'em aberto' end) x
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
    select 64, 'Conteúdo', null, format('%s roteiro(s) prontos para você aprovar e gravar', count(*)), '/conteudo'
      from cont.roteiros where status = 'pronto' having count(*) > 0
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

  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'titulo', r.titulo, 'gancho', r.gancho, 'formato', r.formato,
      'loja', rel._unidade(r.unidade_id), 'nota', i.nota, 'duracao_s', r.duracao_s) order by i.nota desc nulls last, r.id), '[]'::jsonb)
    into v_cont from (select * from cont.roteiros where status = 'pronto' order by id desc limit 6) r left join cont.ideias i on i.id = r.ideia_id;

  v := jsonb_build_object('dia', d, 'gerado_em', now(), 'desde', desde,
    'totais', jsonb_build_object(
      'agentes', (select count(*) from core.agentes where status = 'ativo'),
      'rodadas', (select count(*) from core.tarefas where criado_em > desde),
      'falhas', (select count(*) from core.tarefas where status in ('falhou','incerta') and atualizado_em > desde),
      'ideias', (select count(*) from intel.ideias where status = 'sugerida')),
    'prioridades', v_pri, 'agentes', v_ag, 'mercado', v_merc, 'concorrentes', v_conc, 'conteudo', v_cont);
  insert into rel.relatorios (dia, conteudo) values (d, v)
  on conflict (dia) do update set conteudo = excluded.conteudo, gerado_em = now(), versao = rel.relatorios.versao + 1;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Painel
-- ---------------------------------------------------------------------------
create or replace function cont._roteiro_json(r cont.roteiros) returns jsonb
language sql stable security definer set search_path = cont, core, pg_catalog as $$
  select jsonb_build_object('id', r.id, 'ideia_id', r.ideia_id, 'dia', r.dia, 'titulo', r.titulo, 'formato', r.formato,
    'unidade_id', r.unidade_id, 'loja', rel._unidade(r.unidade_id), 'duracao_s', r.duracao_s, 'gancho', r.gancho, 'cenas', r.cenas,
    'capa', r.capa, 'trilha', r.trilha, 'legenda', r.legenda, 'cta', r.cta, 'observacoes', r.observacoes, 'status', r.status,
    'pedido_ajuste', r.pedido_ajuste, 'versao', r.versao, 'nota_diego', r.nota_diego, 'link', r.link, 'anuncio_nome', r.anuncio_nome,
    'decidido_em', r.decidido_em, 'atualizado_em', r.atualizado_em,
    'nota', i.nota, 'criterios', i.criterios, 'parecer', i.parecer, 'evidencia', i.evidencia)
  from (select 1) _ left join cont.ideias i on i.id = r.ideia_id
$$;

create or replace function public.painel_conteudo(p_dia date default null) returns jsonb
language plpgsql security definer set search_path = cont, core, pg_catalog as $$
declare v_eu uuid; d date := coalesce(p_dia, intel._hoje());
begin
  v_eu := painel._entrar('conteudo', d::text);
  if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão para o conteúdo da rede' using errcode = '42501'; end if;
  return jsonb_build_object('dia', d, 'pode_editar', painel._pode(v_eu, 'administrar'),
    'dias', (select coalesce(jsonb_agg(dia order by dia desc), '[]'::jsonb) from (select distinct dia from cont.ideias order by dia desc limit 60) q),
    'agentes', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'nome', a.nome, 'status', a.status,
        'ultima', (select em from intel.sincronizacoes s where s.agente_id = a.id order by em desc limit 1),
        'resumo', (select resumo from intel.sincronizacoes s where s.agente_id = a.id order by em desc limit 1),
        'falhou_hoje', exists (select 1 from core.tarefas t where t.agente_id = a.id and t.status in ('falhou','incerta') and t.criado_em::date = d))
        order by case a.id when 'conteudo_ideias' then 1 when 'conteudo_avaliador' then 2 else 3 end), '[]'::jsonb)
      from core.agentes a where a.id like 'conteudo\_%'),
    -- roteiros: os do dia + tudo que ainda espera decisão ou ajuste
    'roteiros', (select coalesce(jsonb_agg(cont._roteiro_json(r) order by case r.status when 'pronto' then 0 when 'ajuste' then 1 else 2 end, r.dia desc, r.id), '[]'::jsonb)
      from cont.roteiros r where r.dia = d or r.status in ('pronto','ajuste')),
    'ideias', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'titulo', i.titulo, 'formato', i.formato, 'loja', rel._unidade(i.unidade_id),
        'gancho', i.gancho, 'conceito', i.conceito, 'evidencia', i.evidencia, 'fonte', i.fonte, 'status', i.status, 'nota', i.nota,
        'criterios', i.criterios, 'parecer', i.parecer,
        'roteiro_id', (select id from cont.roteiros r where r.ideia_id = i.id)) order by i.nota desc nulls last, i.id), '[]'::jsonb)
      from cont.ideias i where i.dia = d),
    'producao', (select coalesce(jsonb_agg(cont._roteiro_json(r) order by r.decidido_em desc nulls last), '[]'::jsonb)
      from (select * from cont.roteiros where status in ('aprovado','gravado','publicado','descartado') order by decidido_em desc nulls last limit 80) r),
    'regras', cont._regras());
end $$;

-- p_acao: aprovar | ajuste (p_texto obrigatório) | descartar | gravado | publicado (p_link, p_anuncio) | voltar (para "pronto")
create or replace function public.painel_roteiro_decidir(p_id bigint, p_acao text, p_texto text default null, p_link text default null,
  p_anuncio text default null) returns void
language plpgsql security definer set search_path = cont, core, pg_catalog as $$
declare v_eu uuid; r record; v_novo text; v_txt text := nullif(btrim(coalesce(p_texto, '')), ''); v_link text := nullif(btrim(coalesce(p_link, '')), '');
begin
  v_eu := painel._entrar('roteiro_decidir', p_id::text);
  perform painel._exigir(v_eu, 'administrar');
  select * into r from cont.roteiros where id = p_id for update;
  if r.id is null then raise exception 'roteiro inexistente' using errcode = '22023'; end if;
  v_novo := case p_acao when 'aprovar' then 'aprovado' when 'ajuste' then 'ajuste' when 'descartar' then 'descartado'
    when 'gravado' then 'gravado' when 'publicado' then 'publicado' when 'voltar' then 'pronto' end;
  if v_novo is null then raise exception 'ação inválida' using errcode = '22023'; end if;
  if p_acao = 'ajuste' and length(coalesce(v_txt, '')) < 5 then raise exception 'escreva o que precisa mudar no roteiro' using errcode = '22023'; end if;
  if p_acao in ('gravado','publicado') and r.status not in ('aprovado','gravado','publicado') then
    raise exception 'aprove o roteiro antes de marcar como gravado ou publicado' using errcode = '22023'; end if;
  if v_link is not null and v_link !~ '^https?://' then raise exception 'link inválido: use o endereço completo (https://...)' using errcode = '22023'; end if;
  update cont.roteiros set status = v_novo,
    pedido_ajuste = case when p_acao = 'ajuste' then v_txt else pedido_ajuste end,
    nota_diego = case when p_acao in ('aprovar','descartar') then coalesce(v_txt, nota_diego) else nota_diego end,
    link = coalesce(v_link, link), anuncio_nome = coalesce(nullif(btrim(coalesce(p_anuncio, '')), ''), anuncio_nome),
    decidido_por = v_eu, decidido_em = now(), atualizado_em = now()
   where id = p_id;
  perform core.auditar(v_eu, null, 'roteiro_' || v_novo, 'cont.roteiro', p_id::text, jsonb_build_object('status', r.status),
    jsonb_build_object('status', v_novo, 'canal', 'painel'), v_txt);
end $$;

-- Diego manda roteirizar uma ideia que o Avaliador descartou (entra no próximo roteiro)
create or replace function public.painel_ideia_conteudo_promover(p_id bigint) returns void
language plpgsql security definer set search_path = cont, core, pg_catalog as $$
declare v_eu uuid; i record;
begin
  v_eu := painel._entrar('ideia_conteudo_promover', p_id::text);
  perform painel._exigir(v_eu, 'administrar');
  select * into i from cont.ideias where id = p_id for update;
  if i.id is null then raise exception 'ideia inexistente' using errcode = '22023'; end if;
  if i.status = 'aprovada' then raise exception 'essa ideia já vai para roteiro' using errcode = '22023'; end if;
  update cont.ideias set status = 'aprovada', promovida_por = v_eu, dia = greatest(dia, intel._hoje() - 6) where id = p_id;
  perform core.auditar(v_eu, null, 'ideia_conteudo_promovida', 'cont.ideia', p_id::text, jsonb_build_object('status', i.status),
    jsonb_build_object('status', 'aprovada', 'canal', 'painel'));
end $$;

-- regras dos agentes, editáveis pelo Diego
create or replace function public.painel_conteudo_regras_salvar(p_regras jsonb, p_motivo text default null) returns jsonb
language plpgsql security definer set search_path = cont, core, pg_catalog as $$
declare v_eu uuid; v_antes jsonb := cont._regras(); k text; v text; v_n int; v_fmt text[];
begin
  v_eu := painel._entrar('conteudo_regras_salvar');
  perform painel._exigir(v_eu, 'administrar');
  if jsonb_typeof(coalesce(p_regras, 'null')) <> 'object' then raise exception 'regras inválidas' using errcode = '22023'; end if;
  for k, v in select key, case when jsonb_typeof(value) = 'array' then (select string_agg(e, ',') from jsonb_array_elements_text(value) e) else value #>> '{}' end
                from jsonb_each(p_regras) loop
    v := btrim(coalesce(v, ''));
    if k in ('ideias_por_dia','nota_minima','roteiros_por_dia') then
      if v !~ '^\d{1,3}$' then raise exception 'valor inválido em %', k using errcode = '22023'; end if;
      v_n := v::int;
      if (k = 'ideias_por_dia' and v_n not between 3 and 30) then raise exception 'ideias por dia: de 3 a 30' using errcode = '22023'; end if;
      if (k = 'nota_minima' and v_n not between 50 and 95) then raise exception 'nota mínima: de 50 a 95' using errcode = '22023'; end if;
      if (k = 'roteiros_por_dia' and v_n not between 1 and 10) then raise exception 'roteiros por dia: de 1 a 10' using errcode = '22023'; end if;
    elsif k = 'formatos' then
      v_fmt := array(select distinct lower(btrim(e)) from unnest(string_to_array(v, ',')) e where btrim(e) <> '');
      if cardinality(v_fmt) = 0 or exists (select 1 from unnest(v_fmt) e where e not in ('reel','carrossel','stories','imagem')) then
        raise exception 'formatos: escolha entre reel, carrossel, stories e imagem' using errcode = '22023'; end if;
      v := array_to_string(v_fmt, ',');
    elsif k in ('foco','ofertas','tom','rosto','proibido') then
      if length(v) < 5 or length(v) > 2000 then raise exception 'texto de % entre 5 e 2000 caracteres', k using errcode = '22023'; end if;
    elsif k in ('ideias','avaliador','roteirista') then
      if v not in ('true','false') then raise exception 'liga/desliga inválido' using errcode = '22023'; end if;
      k := k || '.ativo';
    else
      raise exception 'regra desconhecida: %', k using errcode = '22023';
    end if;
    insert into core.config (chave, valor) values ('cont.' || k, v)
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  end loop;
  perform core.auditar(v_eu, null, 'conteudo_regras_alteradas', 'core.config', 'cont', v_antes, cont._regras(), nullif(btrim(coalesce(p_motivo, '')), ''));
  return cont._regras();
end $$;

-- ---------------------------------------------------------------------------
-- 6. Permissões
-- ---------------------------------------------------------------------------
do $$ declare f text; begin
  foreach f in array array['cont._int(text,int)', 'cont._regras()', 'cont._aprendizado()', 'cont.iniciar(text,text,text)',
    'cont.falhar(uuid,text,text)', 'cont.concluir_ideias(uuid,text,jsonb)', 'cont.concluir_avaliacao(uuid,text,jsonb)',
    'cont.concluir_roteiros(uuid,text,jsonb)', 'cont._roteiro_json(cont.roteiros)', 'rel.gerar(date)',
    'public.painel_conteudo(date)', 'public.painel_roteiro_decidir(bigint,text,text,text,text)',
    'public.painel_ideia_conteudo_promover(bigint)', 'public.painel_conteudo_regras_salvar(jsonb,text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', f); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    foreach f in array array['cont._int(text,int)', 'cont._regras()', 'cont._aprendizado()', 'cont.iniciar(text,text,text)',
      'cont.falhar(uuid,text,text)', 'cont.concluir_ideias(uuid,text,jsonb)', 'cont.concluir_avaliacao(uuid,text,jsonb)',
      'cont.concluir_roteiros(uuid,text,jsonb)', 'cont._roteiro_json(cont.roteiros)', 'rel.gerar(date)'] loop
      execute format('revoke all on function %s from authenticated', f);
    end loop;
    foreach f in array array['public.painel_conteudo(date)', 'public.painel_roteiro_decidir(bigint,text,text,text,text)',
      'public.painel_ideia_conteudo_promover(bigint)', 'public.painel_conteudo_regras_salvar(jsonb,text)'] loop
      execute format('grant execute on function %s to authenticated', f);
    end loop;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema cont to service_role';
    foreach f in array array['cont.iniciar(text,text,text)', 'cont.falhar(uuid,text,text)', 'cont.concluir_ideias(uuid,text,jsonb)',
      'cont.concluir_avaliacao(uuid,text,jsonb)', 'cont.concluir_roteiros(uuid,text,jsonb)'] loop
      execute format('grant execute on function %s to service_role', f);
    end loop;
  end if;
end $$;
