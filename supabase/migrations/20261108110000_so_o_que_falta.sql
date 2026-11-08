-- =============================================================================
-- Idealize AI — Só aparece o que falta resolver · Migração 20261108110000
-- Pedido do Diego (08/11): "o que o agente já resolveu deveria ficar escondido; somente o que não foi resolvido fica
-- aparecendo, pois causa muita confusão" + "filtros nos outros agentes, principalmente em datas específicas" +
-- "usar o agente mais inteligente disponível de acordo com o nível de dificuldade".
--  1. Página inicial: "avisos novos" passa a contar só os novos que CONTINUAM abertos; os resolvidos em 24 h viram um
--     número à parte ("resolvidos sozinhos").
--  2. public.painel_avisos_resolvidos: o que já foi resolvido em cada tela, por período — fica numa gaveta fechada.
--  3. Período de/até (datas específicas) no Comercial, Marketing, Retorno (atribuição), Origem das vendas e
--     Auditoria do atendimento.
--  4. Modelo de IA por nível de dificuldade (rápido / avançado / máximo), escolhido pelo Diego numa tela.
-- =============================================================================

-- 1. a visão de alertas ganha a data em que foi resolvido (coluna nova no fim: a visão continua compatível)
create or replace view rel.v_alertas as
  select 'laboratorio'::text agente_id, tipo, unidade_id, aberto_em, status, resolvido_em from lab.alertas
  union all select 'comercial', tipo, unidade_id, aberto_em, status, resolvido_em from com.alertas
  union all select 'marketing', tipo, unidade_id, aberto_em, status, resolvido_em from mkt.alertas
  union all select 'caixa', tipo, unidade_id, aberto_em, status, resolvido_em from cx.alertas
  union all select 'cobrancas', tipo, unidade_id, aberto_em, status, resolvido_em from cob.alertas
  union all select 'rh', tipo, unidade_id, aberto_em, status, resolvido_em from rh.alertas;

do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_inicio()'::regprocedure);
  if v !~ '''resolvidos''' then
    v := replace(v, $a$when 'multicrediario' then (select count(*) from multi.achados where aberto_em > desde)$a$,
                    $a$when 'multicrediario' then (select count(*) from multi.achados where aberto_em > desde and status = 'aberto')$a$);
    v := replace(v, $a$else (select count(*) from rel.v_alertas al where al.agente_id = a.id and al.aberto_em > desde) end,$a$,
                    $a$else (select count(*) from rel.v_alertas al where al.agente_id = a.id and al.aberto_em > desde and al.status = 'aberto') end,
      'resolvidos', case a.id
         when 'multicrediario' then (select count(*) from multi.achados where resolvido_em > desde)
         when 'supervisor' then (select count(*) from sup.achados where resolvido_em > desde)
         when 'financeiro' then (select count(*) from fin.pendencias where status <> 'aberta' and resolvido_em > desde)
         else (select count(*) from rel.v_alertas al where al.agente_id = a.id and al.status <> 'aberto' and al.resolvido_em > desde) end,$a$);
    v := replace(v, $a$else 'avisos novos' end,$a$, $a$else 'novos ainda abertos' end,$a$);
    if v !~ '''resolvidos''' or v !~ 'novos ainda abertos' then raise exception 'início não foi atualizado'; end if;
    execute v;
  end if;
end $$;

-- 2. o que já foi resolvido, por tela e período (só leitura; dados de cliente mascarados como no resto do painel)
create or replace function public.painel_avisos_resolvidos(p_area text, p_unidade text default null, p_de date default null,
  p_ate date default null, p_limite int default 300) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; g boolean; un text[];
  v_de date := coalesce(p_de, (now() at time zone 'America/Sao_Paulo')::date - 6);
  v_ate date := coalesce(p_ate, (now() at time zone 'America/Sao_Paulo')::date);
  v_ini timestamptz; v_fim timestamptz; lim int := least(greatest(coalesce(p_limite, 300), 1), 500);
begin
  v_eu := painel._entrar('avisos_resolvidos', p_area);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; g := false; end if;
  if v_ate < v_de then raise exception 'a data final é antes da inicial' using errcode = '22023'; end if;
  v_ini := v_de::timestamp at time zone 'America/Sao_Paulo';
  v_fim := (v_ate + 1)::timestamp at time zone 'America/Sao_Paulo';

  drop table if exists _rs;
  create temp table _rs (id bigint, tipo text, referencia text, unidade_id text, dia date, titulo text, detalhe jsonb, status text,
    aberto_em timestamptz, resolvido_em timestamptz, resolvido_por text, responsavel text) on commit drop;

  case p_area
    when 'caixa' then insert into _rs select a.id, a.tipo, a.referencia, a.unidade_id, a.dia, null, a.detalhe, a.status, a.aberto_em, a.resolvido_em, a.resolvido_por, null
      from cx.alertas a where a.status <> 'aberto' and a.resolvido_em >= v_ini and a.resolvido_em < v_fim and (a.unidade_id = any(un) or (g and a.unidade_id is null));
    when 'cobrancas' then insert into _rs select a.id, a.tipo, a.referencia, a.unidade_id, null, null, a.detalhe, a.status, a.aberto_em, a.resolvido_em, a.resolvido_por, null
      from cob.alertas a where a.status <> 'aberto' and a.resolvido_em >= v_ini and a.resolvido_em < v_fim and (a.unidade_id = any(un) or (g and a.unidade_id is null));
    when 'comercial' then insert into _rs select a.id, a.tipo, a.referencia, a.unidade_id, null, null, a.detalhe, a.status, a.aberto_em, a.resolvido_em, a.resolvido_por,
        (select nome from com.usuarios u where u.id = a.responsavel_id)
      from com.alertas a where a.status <> 'aberto' and a.resolvido_em >= v_ini and a.resolvido_em < v_fim and (a.unidade_id = any(un) or (g and a.unidade_id is null));
    when 'laboratorio' then insert into _rs select a.id, a.tipo, a.id_origem::text, a.unidade_id, null, (select o.os from lab.os o where o.id_origem = a.id_origem), a.detalhe,
        a.status, a.aberto_em, a.resolvido_em, a.resolvido_por, null
      from lab.alertas a where a.status <> 'aberto' and a.resolvido_em >= v_ini and a.resolvido_em < v_fim and (a.unidade_id = any(un) or (g and a.unidade_id is null));
    when 'marketing' then insert into _rs select a.id, a.tipo, a.referencia, a.unidade_id, null, null, a.detalhe, a.status, a.aberto_em, a.resolvido_em, a.resolvido_por, null
      from mkt.alertas a where a.status <> 'aberto' and a.resolvido_em >= v_ini and a.resolvido_em < v_fim and (a.unidade_id = any(un) or (g and a.unidade_id is null));
    when 'rh' then insert into _rs select a.id, a.tipo, a.referencia, a.unidade_id, a.prazo, null, a.detalhe, a.status, a.aberto_em, a.resolvido_em, a.resolvido_por, null
      from rh.alertas a where a.status <> 'aberto' and a.resolvido_em >= v_ini and a.resolvido_em < v_fim and (a.unidade_id = any(un) or (g and a.unidade_id is null));
    when 'multicrediario' then
      if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
      insert into _rs select a.id, a.tipo, a.chave, null, a.dia, a.descricao, a.detalhe, a.status, a.aberto_em, a.resolvido_em,
          coalesce(a.resolvido_por, '') || coalesce(': ' || a.nota, ''), null
        from multi.achados a where a.status <> 'aberto' and a.resolvido_em >= v_ini and a.resolvido_em < v_fim;
    when 'supervisor' then
      if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
      insert into _rs select a.id, a.tipo, a.referencia, null, null, a.titulo, a.detalhe, a.status, a.aberto_em, a.resolvido_em, 'agente', null
        from sup.achados a where a.status <> 'aberto' and a.resolvido_em >= v_ini and a.resolvido_em < v_fim;
    else raise exception 'tela desconhecida: %', p_area using errcode = '22023';
  end case;

  return jsonb_build_object('de', v_de, 'ate', v_ate, 'total', (select count(*) from _rs),
    'itens', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'tipo', r.tipo, 'referencia', r.referencia, 'unidade_id', r.unidade_id,
        'dia', r.dia, 'titulo', painel._mascarar_texto(r.titulo), 'detalhe', painel._mascarar(r.detalhe), 'status', r.status,
        'aberto_em', r.aberto_em, 'resolvido_em', r.resolvido_em, 'responsavel', r.responsavel,
        -- quem resolveu: o próprio agente (a situação deixou de existir) ou uma pessoa pelo painel/WhatsApp
        'sozinho', r.resolvido_por is null or r.resolvido_por ~* '^agente' or r.resolvido_por ~* 'deixou de existir',
        'por', case when r.resolvido_por is null or r.resolvido_por ~* '^agente' or r.resolvido_por ~* 'deixou de existir' then null
                    else painel._mascarar_texto(r.resolvido_por) end) order by r.resolvido_em desc), '[]'::jsonb)
      from (select * from _rs order by resolvido_em desc limit lim) r));
end $$;
do $$ begin
  revoke all on function public.painel_avisos_resolvidos(text, text, date, date, int) from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on function public.painel_avisos_resolvidos(text, text, date, date, int) from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'grant execute on function public.painel_avisos_resolvidos(text, text, date, date, int) to authenticated'; end if;
end $$;

-- 3. período de/até nas telas que só aceitavam "últimos N dias"
--    Cada função ganha p_de/p_ate (opcionais; sem eles, vale o "últimos N dias" de antes) e a versão antiga sai.
create or replace function core._trocar_funcao(p_antiga regprocedure, p_nova text, p_marcador text) returns void
language plpgsql as $$
begin
  if p_nova !~ p_marcador then raise exception 'a função % não foi atualizada (marcador %)', p_antiga, p_marcador; end if;
  execute format('drop function %s', p_antiga);
  execute p_nova;
end $$;

do $$ declare v text;
begin
  -- Comercial
  if to_regprocedure('public.painel_comercial(text,integer)') is not null then
    v := pg_get_functiondef('public.painel_comercial(text,integer)'::regprocedure);
    v := replace(v, 'p_dias integer DEFAULT 7)', 'p_dias integer DEFAULT 7, p_de date DEFAULT NULL::date, p_ate date DEFAULT NULL::date)');
    v := replace(v, 'v_ini timestamptz;', 'v_ini timestamptz; v_fim timestamptz;');
    v := replace(v, 'v_ini := now() - make_interval(days => d);',
      $a$v_ini := coalesce(p_de::timestamp at time zone 'America/Sao_Paulo', now() - make_interval(days => d));
  v_fim := coalesce((p_ate + 1)::timestamp at time zone 'America/Sao_Paulo', now() + interval '1 minute');
  if v_fim <= v_ini then raise exception 'a data final é antes da inicial' using errcode = '22023'; end if;$a$);
    v := regexp_replace(v, '(\m[a-z0-9_]+\.[a-z_]+) >= v_ini\M', '\1 >= v_ini and \1 < v_fim', 'g');
    v := replace(v, $a$'periodo_dias', d,$a$, $a$'periodo_dias', d, 'desde', (v_ini at time zone 'America/Sao_Paulo')::date, 'ate', ((v_fim - interval '1 second') at time zone 'America/Sao_Paulo')::date,$a$);
    perform core._trocar_funcao('public.painel_comercial(text,integer)'::regprocedure, v, '< v_fim');
  end if;

  -- Marketing
  if to_regprocedure('public.painel_marketing(text,integer)') is not null then
    v := pg_get_functiondef('public.painel_marketing(text,integer)'::regprocedure);
    v := replace(v, 'p_dias integer DEFAULT 7)', 'p_dias integer DEFAULT 7, p_de date DEFAULT NULL::date, p_ate date DEFAULT NULL::date)');
    v := replace(v, 'v_ini date; v_hoje date := mkt._hoje();', 'v_ini date; v_hoje date := mkt._hoje(); v_fim date;');
    v := replace(v, 'v_ini := v_hoje - (d - 1);', $a$v_ini := coalesce(p_de, v_hoje - (d - 1)); v_fim := coalesce(p_ate, v_hoje);
  if v_fim < v_ini then raise exception 'a data final é antes da inicial' using errcode = '22023'; end if;$a$);
    v := replace(v, 'm.dia >= v_ini', 'm.dia between v_ini and v_fim');
    v := replace(v, $a$'desde', v_ini, 'ate', v_hoje,$a$, $a$'desde', v_ini, 'ate', v_fim,$a$);
    perform core._trocar_funcao('public.painel_marketing(text,integer)'::regprocedure, v, 'between v_ini and v_fim');
  end if;

  -- Retorno das campanhas (atribuição)
  if to_regprocedure('public.painel_atribuicao(text,integer)') is not null then
    v := pg_get_functiondef('public.painel_atribuicao(text,integer)'::regprocedure);
    v := replace(v, 'p_dias integer DEFAULT 30)', 'p_dias integer DEFAULT 30, p_de date DEFAULT NULL::date, p_ate date DEFAULT NULL::date)');
    v := replace(v, 'v_ini := d - (n - 1);', $a$if p_ate is not null then d := least(p_ate, d); end if;
  v_ini := coalesce(p_de, d - (n - 1));
  if d < v_ini then raise exception 'a data final é antes da inicial' using errcode = '22023'; end if;$a$);
    perform core._trocar_funcao('public.painel_atribuicao(text,integer)'::regprocedure, v, 'coalesce\(p_de, d - \(n - 1\)\)');
  end if;

  -- Origem das vendas
  if to_regprocedure('public.painel_origem_vendas(text,integer,text)') is not null then
    v := pg_get_functiondef('public.painel_origem_vendas(text,integer,text)'::regprocedure);
    v := replace(v, 'p_origem text DEFAULT NULL::text)', 'p_origem text DEFAULT NULL::text, p_de date DEFAULT NULL::date, p_ate date DEFAULT NULL::date)');
    v := regexp_replace(v, '(v_ini date := [^;]+;)', '\1 v_fim date := coalesce(p_ate, atr._hoje());');
    v := replace(v, 'and dia >= v_ini;', 'and dia between v_ini and v_fim;');
    v := replace(v, $a$'desde', v_ini, 'ate', atr._hoje(),$a$, $a$'desde', v_ini, 'ate', v_fim,$a$);
    v := regexp_replace(v, '(begin\s+v_eu := painel._entrar)', $a$begin
  if p_de is not null then v_ini := p_de; end if;
  if v_fim < v_ini then raise exception 'a data final é antes da inicial' using errcode = '22023'; end if;
  v_eu := painel._entrar$a$);
    perform core._trocar_funcao('public.painel_origem_vendas(text,integer,text)'::regprocedure, v, 'between v_ini and v_fim');
  end if;

  -- Auditoria do atendimento
  if to_regprocedure('public.painel_auditoria_atendimento(integer,bigint)') is not null then
    v := pg_get_functiondef('public.painel_auditoria_atendimento(integer,bigint)'::regprocedure);
    v := replace(v, 'p_operadora bigint DEFAULT NULL::bigint)', 'p_operadora bigint DEFAULT NULL::bigint, p_de date DEFAULT NULL::date, p_ate date DEFAULT NULL::date)');
    v := regexp_replace(v, '(declare v_eu uuid; v_ini date := [^;]+;)', $a$\1 v_fim date := coalesce(p_ate, (now() at time zone 'America/Sao_Paulo')::date);$a$);
    v := replace(v, 'where c.dia >= v_ini;', 'where c.dia between v_ini and v_fim;');
    v := replace(v, 'where dia >= v_ini and erro is null', 'where dia between v_ini and v_fim and erro is null');
    v := replace(v, $a$'desde', v_ini,$a$, $a$'desde', v_ini, 'ate', v_fim,$a$);
    v := regexp_replace(v, '(begin\s+v_eu := painel._entrar)', $a$begin
  if p_de is not null then v_ini := p_de; end if;
  if v_fim < v_ini then raise exception 'a data final é antes da inicial' using errcode = '22023'; end if;
  v_eu := painel._entrar$a$);
    perform core._trocar_funcao('public.painel_auditoria_atendimento(integer,bigint)'::regprocedure, v, 'between v_ini and v_fim');
  end if;
end $$;
drop function core._trocar_funcao(regprocedure, text, text);

do $$ declare f text;
begin
  foreach f in array array['public.painel_comercial(text,integer,date,date)', 'public.painel_marketing(text,integer,date,date)',
      'public.painel_atribuicao(text,integer,date,date)', 'public.painel_origem_vendas(text,integer,text,date,date)',
      'public.painel_auditoria_atendimento(integer,bigint,date,date)'] loop
    if to_regprocedure(f) is null then continue; end if;
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('grant execute on function %s to authenticated', f); end if;
  end loop;
end $$;

-- 4. modelo de IA por nível de dificuldade. Quem escolhe é o Diego, na tela "Inteligência dos agentes".
--    rapido   = conversa simples, confirmações, resumos curtos
--    avancado = perguntas sobre os números, leitura de comprovantes
--    maximo   = investigar divergência ("buscar o erro"), ler extrato e fatura inteiros
--    Se o modelo escolhido não estiver liberado na conta, o agente tenta o próximo da lista (nunca fica sem responder).
insert into core.config (chave, valor) values
  ('ia.modelo.rapido', 'claude-sonnet-5-5'),
  ('ia.modelo.avancado', 'claude-opus-5-5'),
  ('ia.modelo.maximo', 'claude-fable-5-1'),
  ('ia.nivel.wa_conversa', 'avancado'),
  ('ia.nivel.wa_investigar', 'maximo'),
  ('ia.nivel.painel_aviso', 'maximo'),
  ('ia.nivel.fin_comprovante', 'avancado'),
  ('ia.nivel.fin_extrato', 'maximo')
on conflict (chave) do nothing;

create or replace function core.ia_modelos(p_tarefa text) returns text[]
language sql stable security definer set search_path = core, pg_catalog as $$
  -- modelo do nível escolhido primeiro; depois os outros, do mais forte ao mais simples, como reserva
  with n as (select coalesce(nullif(core.cfg('ia.nivel.' || p_tarefa, ''), ''), 'avancado') nivel),
  m as (select x.ordem + case when x.nivel = n.nivel then -10 else 0 end ordem, nullif(core.cfg('ia.modelo.' || x.nivel, ''), '') modelo
          from (values ('maximo', 1), ('avancado', 2), ('rapido', 3)) x(nivel, ordem), n),
  u as (select modelo, min(ordem) ordem from m where modelo is not null group by modelo)
  select coalesce(array_agg(modelo order by ordem), array['claude-sonnet-5-5']) from u
$$;
revoke all on function core.ia_modelos(text) from public;

-- tela: ver e escolher
create or replace function public.painel_ia() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('ia');
  if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão' using errcode = '42501'; end if;
  return jsonb_build_object(
    'pode_editar', painel._pode(v_eu, 'administrar'),
    'modelos', jsonb_build_object('rapido', core.cfg('ia.modelo.rapido', 'claude-sonnet-5-5'), 'avancado', core.cfg('ia.modelo.avancado', 'claude-opus-5-5'),
                                  'maximo', core.cfg('ia.modelo.maximo', 'claude-fable-5-1')),
    'tarefas', (select jsonb_agg(jsonb_build_object('id', t.id, 'nome', t.nome, 'ajuda', t.ajuda, 'nivel', core.cfg('ia.nivel.' || t.id, t.padrao),
                   'usado', (select c.modelo from core.custos c where c.agente_id = t.agente and c.modelo is not null order by c.em desc limit 1)) order by t.ordem)
                from (values
                  (1, 'wa_conversa', 'WhatsApp: perguntas e conversa', 'Perguntas sobre caixa, vendas, cobranças; resumos.', 'avancado', 'whatsapp'),
                  (2, 'wa_investigar', 'WhatsApp: investigar um aviso', 'Quando você comenta um aviso ou pede para achar o erro.', 'maximo', 'whatsapp'),
                  (3, 'painel_aviso', 'Painel: "Falar com o agente"', 'Respostas às suas mensagens nos avisos de Tudo para resolver e do Caixa.', 'maximo', 'whatsapp'),
                  (4, 'fin_comprovante', 'Financeiro: comprovantes', 'Leitura de comprovante, boleto e nota.', 'avancado', 'financeiro'),
                  (5, 'fin_extrato', 'Financeiro: extratos e faturas', 'Leitura de extrato do banco, Stone, Asaas e fatura de cartão inteiros.', 'maximo', 'financeiro')
                ) t(ordem, id, nome, ajuda, padrao, agente)));
end $$;

create or replace function public.painel_ia_salvar(p_modelos jsonb, p_niveis jsonb) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; k text; val text;
begin
  v_eu := painel._entrar('ia_salvar');
  perform painel._exigir(v_eu, 'administrar', null);
  for k, val in select key, value #>> '{}' from jsonb_each(coalesce(p_modelos, '{}')) loop
    if k not in ('rapido', 'avancado', 'maximo') then raise exception 'nível desconhecido: %', k using errcode = '22023'; end if;
    if val !~ '^claude-[a-z0-9.-]{3,60}$' then raise exception 'nome de modelo inválido: %', val using errcode = '22023'; end if;
    insert into core.config (chave, valor) values ('ia.modelo.' || k, val) on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  end loop;
  for k, val in select key, value #>> '{}' from jsonb_each(coalesce(p_niveis, '{}')) loop
    if k not in ('wa_conversa', 'wa_investigar', 'painel_aviso', 'fin_comprovante', 'fin_extrato') then raise exception 'tarefa desconhecida: %', k using errcode = '22023'; end if;
    if val not in ('rapido', 'avancado', 'maximo') then raise exception 'nível inválido: %', val using errcode = '22023'; end if;
    insert into core.config (chave, valor) values ('ia.nivel.' || k, val) on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  end loop;
  perform core.auditar(v_eu, null, 'ia_ajustada', 'core.config', 'ia', null, jsonb_build_object('modelos', p_modelos, 'niveis', p_niveis), 'escolha dos modelos de IA');
  return public.painel_ia();
end $$;
do $$ begin
  revoke all on function public.painel_ia() from public;
  revoke all on function public.painel_ia_salvar(jsonb, jsonb) from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.painel_ia() from anon'; execute 'revoke all on function public.painel_ia_salvar(jsonb, jsonb) from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.painel_ia() to authenticated'; execute 'grant execute on function public.painel_ia_salvar(jsonb, jsonb) to authenticated'; end if;
end $$;

-- 5. Extrato que chega já vira lançamento (pedido 08/11: "subi o extrato do mês, ele deveria já entender e atualizar")
--    Achado: o extrato era lido e guardado, mas ninguém chamava a conciliação e a classificação depois — por isso o
--    Financeiro por loja de novembro ficou zerado. Agora, a cada 10 minutos (e logo depois de cada extrato lançado):
--    1º casa com comprovantes já lançados (fin.conciliar), 2º classifica o resto pelas regras (fin.lancar_do_extrato).
--    O que não tiver regra vira pendência "sem classificação" na tela Pendências, para você escolher a categoria.
create or replace function fin.processar_extratos(p_ator text default 'agente_financeiro') returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare c record; r jsonb := '[]'::jsonb; a jsonb; b jsonb;
begin
  if not pg_try_advisory_xact_lock(hashtext('fin.processar_extratos')) then return jsonb_build_object('status', 'ocupado'); end if;
  for c in select distinct m.conta_id from fin.movimentos m where m.status = 'pendente'
      and not exists (select 1 from fin.pendencias p where p.movimento_id = m.id and p.status = 'aberta') loop
    a := fin.conciliar(c.conta_id, p_ator);
    b := fin.lancar_do_extrato(c.conta_id, p_ator);
    r := r || jsonb_build_array(jsonb_build_object('conta', c.conta_id, 'conciliados', a, 'lancados', b));
  end loop;
  if jsonb_array_length(r) > 0 then
    perform core.auditar(null, 'agente_financeiro', 'extratos_processados', 'fin.movimentos', null, null, r, 'extrato vira lançamento');
  end if;
  return jsonb_build_object('status', 'ok', 'contas', r);
end $$;
revoke all on function fin.processar_extratos(text) from public;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'fin-extratos';
    perform cron.schedule('fin-extratos', '*/10 * * * *', $c$select fin.processar_extratos('agente_financeiro')$c$);
  end if;
end $$;
