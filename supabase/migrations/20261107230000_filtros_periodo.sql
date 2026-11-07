-- =============================================================================
-- Idealize AI — Filtros por período no Caixa e no Multicrediário + conversa com o agente nos avisos  · Migração 20261107230000
-- Pedido do Diego (07/11): "preciso que melhore os filtros, estão bem limitados" — período de/até com atalhos,
-- forma de pagamento, situação (inclui resolvidos) e busca por valor ou venda.
--  • painel_caixa(p_unidade, p_dias, p_de, p_ate): período livre (até 400 dias); cada forma do dia traz os valores
--    lançados (para a busca por valor); devolve também os avisos resolvidos no período.
--  • painel_multi(p_dia, p_ate): com p_ate, vendas, consultas e parcelas de um período (cada uma com o dia).
--  • Conversa com o agente (pedido 07/11: "nas situações a resolver deveria poder me comunicar com o agente para que
--    possa buscar o erro"): em cada aviso do Caixa a pessoa escreve para o agente (core.avisos_conversa); o agente de
--    avisos (tarefa agendada) investiga e responde no mesmo lugar. A diretoria pode marcar o aviso como "explicado":
--    o agente para de cobrar aquele aviso (e pode voltar a cobrar pelo mesmo botão).
-- =============================================================================
create table if not exists core.avisos_conversa (
  id          bigserial primary key,
  area        text not null check (area in ('caixa')),
  tipo        text not null,
  referencia  text not null,
  unidade_id  text,
  papel       text not null check (papel in ('pessoa', 'agente')),
  autor_id    uuid,
  autor_nome  text not null,
  texto       text not null check (length(btrim(texto)) between 2 and 2000),
  acao        text not null default 'comentar' check (acao in ('comentar', 'explicar', 'reabrir', 'responder')),
  respondida  boolean not null default false,          -- mensagem da pessoa já respondida pelo agente
  criado_em   timestamptz not null default now()
);
create index if not exists avisos_conversa_ref on core.avisos_conversa (area, tipo, referencia, criado_em);
create index if not exists avisos_conversa_pend on core.avisos_conversa (criado_em) where papel = 'pessoa' and not respondida;
alter table core.avisos_conversa enable row level security; alter table core.avisos_conversa force row level security;
do $$ begin
  revoke all on core.avisos_conversa from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on core.avisos_conversa from anon, authenticated'; end if;
end $$;

-- aviso "explicado": a diretoria disse por que está certo; o agente não volta a abrir o mesmo aviso
alter table cx.alertas drop constraint if exists alertas_status_check;
alter table cx.alertas add constraint alertas_status_check check (status in ('aberto', 'resolvido', 'explicado'));
do $$ declare v text;
begin
  v := pg_get_functiondef('cx.recalcular()'::regprocedure);
  if v !~ 'explicado' then
    v := replace(v, $a$  perform cx._conferir_depositos(v_ini, d);$a$, $a$  perform cx._conferir_depositos(v_ini, d);

  -- aviso explicado pela diretoria não volta a abrir
  delete from _devidos x where exists (select 1 from cx.alertas e where e.status = 'explicado' and e.tipo = x.tipo and e.referencia = x.referencia);$a$);
    if v !~ 'explicado' then raise exception 'recalcular do caixa não foi atualizado'; end if;
    execute v;
  end if;
end $$;

drop function if exists public.painel_caixa(text, int);
create or replace function public.painel_caixa(p_unidade text default null, p_dias int default 7, p_de date default null, p_ate date default null)
returns jsonb language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[]; g boolean; d int := least(greatest(coalesce(p_dias, 7), 1), 400); v_hoje date := cx._hoje();
  v_ini date; v_fim date; v_t date;
begin
  v_eu := painel._entrar('caixa', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; g := false; end if;
  v_fim := least(coalesce(p_ate, v_hoje), v_hoje);
  v_ini := coalesce(p_de, v_fim - (d - 1));
  if v_ini > v_fim then v_t := v_ini; v_ini := v_fim; v_fim := v_t; end if;
  if v_fim - v_ini > 400 then v_ini := v_fim - 400; end if;
  return jsonb_build_object(
    'periodo_dias', v_fim - v_ini + 1, 'desde', v_ini, 'ate', v_fim,
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
    'conferencia', (select coalesce(jsonb_agg(x order by x->>'dia' desc, x->>'unidade_id', x->>'forma'), '[]'::jsonb) from (
      select jsonb_build_object('unidade_id', pg.unidade_id, 'dia', pg.dia, 'forma', pg.forma,
        'sistema', sum(pg.valor), 'quantidade', count(*), 'valores', jsonb_agg(pg.valor order by pg.valor desc),
        'achado', coalesce(sum(pg.valor) filter (where exists (select 1 from cx.casamentos c where c.pagamento_id = pg.id)), 0),
        'faltando', coalesce(sum(pg.valor) filter (where not exists (select 1 from cx.casamentos c where c.pagamento_id = pg.id)), 0)) x
      from cx.pagamentos pg
      where pg.dia between v_ini and v_fim and pg.unidade_id = any(un)
      group by pg.unidade_id, pg.dia, pg.forma) q),
    'dias', (select coalesce(jsonb_agg(jsonb_build_object('unidade_id', x.unidade_id, 'dia', x.dia, 'status_adm', x.status_adm,
        'caixa', x.caixa, 'soma_formas', x.soma_formas, 'deposito_valor', x.deposito_valor) order by x.dia desc, x.unidade_id), '[]'::jsonb)
      from cx.dias x where x.dia between v_ini and v_fim and x.unidade_id = any(un)),
    'alertas', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'referencia', a.referencia, 'unidade_id', a.unidade_id, 'dia', a.dia,
        'aberto_em', a.aberto_em, 'detalhe', a.detalhe,
        'mensagens', (select count(*) from core.avisos_conversa m where m.area = 'caixa' and m.tipo = a.tipo and m.referencia = a.referencia)) x
      from cx.alertas a
      where a.status = 'aberto' and (a.unidade_id = any(un) or (g and a.unidade_id is null))
      order by case a.tipo when 'nao_encontrado' then 0 when 'caixa_nao_fechado' then 1 when 'dinheiro_sem_deposito' then 2
                           when 'caixa_inconsistente' then 3 when 'extrato_atrasado' then 4 else 5 end, a.dia desc nulls last
      limit 500) q),
    'resolvidos', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'referencia', a.referencia, 'unidade_id', a.unidade_id, 'dia', a.dia,
        'aberto_em', a.aberto_em, 'detalhe', a.detalhe, 'resolvido_em', a.resolvido_em, 'resolvido_por', a.resolvido_por, 'status', a.status,
        'mensagens', (select count(*) from core.avisos_conversa m where m.area = 'caixa' and m.tipo = a.tipo and m.referencia = a.referencia)) x
      from cx.alertas a
      where a.status in ('resolvido', 'explicado') and (a.unidade_id = any(un) or (g and a.unidade_id is null))
        and coalesce(a.dia, (a.resolvido_em at time zone 'America/Sao_Paulo')::date) between v_ini and v_fim
      order by a.resolvido_em desc limit 300) q));
end $$;

do $$ begin
  revoke all on function public.painel_caixa(text, int, date, date) from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on function public.painel_caixa(text, int, date, date) from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'grant execute on function public.painel_caixa(text, int, date, date) to authenticated'; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then execute 'grant execute on function public.painel_caixa(text, int, date, date) to service_role'; end if;
end $$;

drop function if exists public.painel_multi(date);
create or replace function public.painel_multi(p_dia date default null, p_ate date default null) returns jsonb
language plpgsql security definer set search_path = multi, core, pg_catalog as $$
declare v_eu uuid; d date; f date; v_t date;
begin
  v_eu := painel._entrar('multicrediario', coalesce(p_dia::text, '') || coalesce('..' || p_ate::text, ''));
  if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão' using errcode = '42501'; end if;
  d := coalesce(p_dia, (select max(dia) from multi.capturas where relatorio = 'operacao_detalhe' and dia <= current_date), current_date - 1);
  f := coalesce(p_ate, d);
  if d > f then v_t := d; d := f; f := v_t; end if;
  if f - d > 400 then d := f - 400; end if;
  return jsonb_build_object(
    'dia', d, 'ate', f, 'pode_editar', painel._pode(v_eu, 'administrar'),
    'ultima_leitura', (select max(capturado_em) from multi.capturas),
    'ultima_conferencia', (select max(em) from intel.sincronizacoes where agente_id = 'multicrediario' and resumo ? 'avisos'),
    'dias', (select coalesce(jsonb_agg(x order by x desc), '[]'::jsonb) from (select distinct dia x from multi.capturas where relatorio = 'operacao_detalhe' and dia is not null order by 1 desc limit 60) q),
    'resumo', jsonb_build_object(
      'aprovadas', (select count(*) from multi.v_operacoes where tipo = 1 and dia between d and f),
      'aprovado_valor', (select coalesce(sum(garantido), 0) from multi.v_operacoes where tipo = 1 and dia between d and f),
      'negadas', (select count(*) from multi.v_operacoes where tipo = 2 and dia between d and f),
      'canceladas', (select count(*) from multi.v_operacoes where tipo = 4 and dia between d and f),
      'parcelas', (select count(*) from multi.v_recebidas where dia between d and f),
      'parcelas_valor', (select coalesce(sum(valor), 0) from multi.v_recebidas where dia between d and f),
      'abertos', (select count(*) from multi.achados where status = 'aberto')),
    'abertos', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'dia', dia, 'descricao', descricao, 'aberto_em', aberto_em) order by dia desc nulls last, id), '[]'::jsonb)
      from multi.achados where status = 'aberto'),
    'vendas', (select coalesce(jsonb_agg(jsonb_build_object('dia', dia, 'venda', venda, 'os', os, 'plano', plano, 'garantido', garantido, 'adm', valor_adm, 'situacao', situacao) order by dia desc, venda), '[]'::jsonb)
      from multi.v_conferencia where dia between d and f),
    'negadas', (select coalesce(jsonb_agg(jsonb_build_object('dia', dia, 'venda', venda, 'tipo', tipo, 'valor', coalesce(total, valor_venda), 'resposta', resposta) order by dia desc, tipo, venda), '[]'::jsonb)
      from multi.v_operacoes where dia between d and f and tipo in (2, 4)),
    'recebidas', (select coalesce(jsonb_agg(jsonb_build_object('dia', dia, 'venda', venda, 'parcela', parcela, 'valor', valor) order by dia desc, venda), '[]'::jsonb)
      from multi.v_recebidas where dia between d and f),
    'resolvidos', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'dia', dia, 'descricao', descricao, 'resolvido_em', resolvido_em, 'resolvido_por', resolvido_por, 'nota', nota) order by resolvido_em desc), '[]'::jsonb)
      from (select * from multi.achados where status = 'resolvido' order by resolvido_em desc limit 200) q));
end $$;

do $$ begin
  revoke all on function public.painel_multi(date, date) from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on function public.painel_multi(date, date) from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'grant execute on function public.painel_multi(date, date) to authenticated'; end if;
end $$;

-- conversa de um aviso
create or replace function public.painel_aviso_conversa(p_area text, p_tipo text, p_ref text) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_un text; v_status text;
begin
  v_eu := painel._entrar('aviso_conversa', p_area || ':' || p_tipo || ':' || p_ref);
  if p_area <> 'caixa' then raise exception 'área inválida' using errcode = '22023'; end if;
  select a.unidade_id, a.status into v_un, v_status from cx.alertas a where a.tipo = p_tipo and a.referencia = p_ref order by a.id desc limit 1;
  if not found then raise exception 'aviso não encontrado' using errcode = 'P0002'; end if;
  if v_un is null then perform painel._exigir(v_eu, 'consultar'); else perform painel._exigir(v_eu, 'consultar', v_un); end if;
  return jsonb_build_object('status', v_status, 'pode_explicar', painel._pode(v_eu, 'administrar'),
    'mensagens', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'papel', m.papel, 'autor', m.autor_nome, 'texto', m.texto, 'acao', m.acao,
        'em', m.criado_em, 'respondida', m.respondida) order by m.criado_em, m.id), '[]'::jsonb)
      from core.avisos_conversa m where m.area = p_area and m.tipo = p_tipo and m.referencia = p_ref));
end $$;

-- escrever para o agente; 'explicar' (diretoria) para de cobrar o aviso, 'reabrir' volta a cobrar
create or replace function public.painel_aviso_escrever(p_area text, p_tipo text, p_ref text, p_texto text, p_acao text default 'comentar')
returns jsonb language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_un text; v_id bigint; v_nome text; v_alerta bigint; v_status text;
begin
  v_eu := painel._entrar('aviso_escrever', p_area || ':' || p_tipo || ':' || p_ref);
  if p_area <> 'caixa' then raise exception 'área inválida' using errcode = '22023'; end if;
  if p_acao not in ('comentar', 'explicar', 'reabrir') then raise exception 'ação inválida' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_texto, ''))) < 2 then raise exception 'escreva a mensagem' using errcode = '22023'; end if;
  if length(p_texto) > 2000 then raise exception 'mensagem longa demais (até 2.000 letras)' using errcode = '22023'; end if;
  select a.id, a.unidade_id, a.status into v_alerta, v_un, v_status from cx.alertas a where a.tipo = p_tipo and a.referencia = p_ref order by a.id desc limit 1;
  if not found then raise exception 'aviso não encontrado' using errcode = 'P0002'; end if;
  if v_un is null then perform painel._exigir(v_eu, 'consultar'); else perform painel._exigir(v_eu, 'consultar', v_un); end if;
  if p_acao in ('explicar', 'reabrir') then perform painel._exigir(v_eu, 'administrar'); end if;
  select nome into v_nome from core.principais where id = v_eu;
  insert into core.avisos_conversa (area, tipo, referencia, unidade_id, papel, autor_id, autor_nome, texto, acao, respondida)
  values (p_area, p_tipo, p_ref, v_un, 'pessoa', v_eu, coalesce(v_nome, 'Painel'), btrim(p_texto), p_acao, p_acao = 'reabrir')
  returning id into v_id;
  if p_acao = 'explicar' and v_status = 'aberto' then
    update cx.alertas set status = 'explicado', resolvido_em = now(), resolvido_por = 'explicado por ' || coalesce(v_nome, 'painel') where id = v_alerta;
  elsif p_acao = 'reabrir' and v_status = 'explicado' then
    update cx.alertas set status = 'resolvido', resolvido_por = 'voltou a ser cobrado por ' || coalesce(v_nome, 'painel') where id = v_alerta;
    perform cx.recalcular();
  end if;
  perform core.auditar(v_eu, null, 'aviso_' || p_acao, 'cx.alertas', v_alerta::text, jsonb_build_object('status', v_status),
    jsonb_build_object('mensagem', v_id, 'acao', p_acao), left(btrim(p_texto), 500));
  return jsonb_build_object('id', v_id);
end $$;

-- lado do agente (tarefa agendada, service_role): mensagens sem resposta, com o aviso, e a resposta
create or replace function public.agente_avisos_pendentes(p_limite int default 20) returns jsonb
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('id', m.id, 'area', m.area, 'tipo', m.tipo, 'referencia', m.referencia, 'unidade_id', m.unidade_id,
      'texto', m.texto, 'acao', m.acao, 'em', m.criado_em,
      'aviso', (select jsonb_build_object('status', a.status, 'dia', a.dia, 'detalhe', a.detalhe) from cx.alertas a
                 where a.tipo = m.tipo and a.referencia = m.referencia order by a.id desc limit 1),
      'conversa', (select jsonb_agg(jsonb_build_object('papel', c.papel, 'texto', c.texto, 'em', c.criado_em) order by c.criado_em)
                     from core.avisos_conversa c where c.area = m.area and c.tipo = m.tipo and c.referencia = m.referencia)) x
    from core.avisos_conversa m where m.papel = 'pessoa' and not m.respondida order by m.criado_em limit least(greatest(coalesce(p_limite, 20), 1), 100)) q
$$;

create or replace function public.agente_aviso_responder(p_mensagem bigint, p_texto text) returns bigint
language plpgsql security definer set search_path = core, pg_catalog as $$
declare m core.avisos_conversa; v_id bigint;
begin
  select * into m from core.avisos_conversa where id = p_mensagem and papel = 'pessoa' for update;
  if not found then raise exception 'mensagem não encontrada' using errcode = 'P0002'; end if;
  if length(btrim(coalesce(p_texto, ''))) < 2 then raise exception 'resposta vazia' using errcode = '22023'; end if;
  insert into core.avisos_conversa (area, tipo, referencia, unidade_id, papel, autor_nome, texto, acao)
  values (m.area, m.tipo, m.referencia, m.unidade_id, 'agente', 'Agente do caixa', left(btrim(p_texto), 2000), 'responder') returning id into v_id;
  update core.avisos_conversa set respondida = true where area = m.area and tipo = m.tipo and referencia = m.referencia and papel = 'pessoa' and not respondida and id <= p_mensagem;
  return v_id;
end $$;

do $$ declare f text; begin
  foreach f in array array['public.painel_aviso_conversa(text,text,text)', 'public.painel_aviso_escrever(text,text,text,text,text)',
                           'public.agente_avisos_pendentes(int)', 'public.agente_aviso_responder(bigint,text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', f); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.painel_aviso_conversa(text,text,text) to authenticated';
    execute 'grant execute on function public.painel_aviso_escrever(text,text,text,text,text) to authenticated';
    execute 'revoke all on function public.agente_avisos_pendentes(int) from authenticated';
    execute 'revoke all on function public.agente_aviso_responder(bigint,text) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.agente_avisos_pendentes(int) to service_role';
    execute 'grant execute on function public.agente_aviso_responder(bigint,text) to service_role';
  end if;
end $$;

-- Tudo para resolver: avisos do Caixa levam a referência, para conversar com o agente dali mesmo
do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_central(text)'::regprocedure);
  if v !~ 'avisos_conversa' then
    v := replace(v, $a$link text, desde timestamptz) on commit drop;$a$, $a$link text, desde timestamptz, ref text, mensagens int) on commit drop;$a$);
    v := replace(v, $a$           '/caixa', a.aberto_em
      from cx.alertas a where a.status = 'aberto'$a$, $a$           '/caixa', a.aberto_em, a.tipo || '|' || a.referencia,
           (select count(*)::int from core.avisos_conversa m where m.area = 'caixa' and m.tipo = a.tipo and m.referencia = a.referencia)
      from cx.alertas a where a.status = 'aberto'$a$);
    v := replace(v, $a$'titulo', titulo, 'texto', texto, 'link', link, 'desde', desde)$a$,
                    $a$'titulo', titulo, 'texto', texto, 'link', link, 'desde', desde, 'ref', ref, 'mensagens', mensagens)$a$);
    if v !~ 'avisos_conversa' or v !~ '''ref'', ref' or v !~ 'ref text, mensagens int' then raise exception 'central não foi atualizada'; end if;
    execute v;
  end if;
end $$;
