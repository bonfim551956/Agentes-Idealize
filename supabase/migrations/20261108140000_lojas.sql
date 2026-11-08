-- =============================================================================
-- Idealize AI — Lojas: ativar, desativar e cadastrar loja nova pelo painel · Migração 20261108140000
-- Pedido do Diego (08/11): "deixar desativado para as outras lojas por enquanto; algo para ativar e desativar loja e,
-- na estrutura, adicionar novas lojas quando necessário".
--  • Loja desativada some do painel (seletor, telas, Tudo para resolver, página inicial), do relatório do dia e das
--    urgências do WhatsApp. Os agentes continuam lendo os dados dela (nada se perde e as conferências internas
--    continuam válidas); quando a loja é ativada de novo, tudo volta a aparecer, já em dia.
--  • Loja nova: nome + código da loja no ADM/Lab (ex.: saovicente) + código no RH 360 (ex.: SAOVICENTE). O painel
--    grava nos mapas de cada agente. Funil da Kommo, conta de anúncio e conta do banco continuam nas telas de cada um.
-- =============================================================================

create or replace function core.loja_ativa(p_unidade text) returns boolean
language sql stable security definer set search_path = core, pg_catalog as $$
  select p_unidade is null or coalesce((select u.ativo from core.unidades u where u.id = p_unidade), true)
$$;
grant execute on function core.loja_ativa(text) to public;

-- 1. página inicial: contagens só das lojas ativas
do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_inicio()'::regprocedure);
  if v !~ 'loja_ativa' then
    v := replace(v, 'al.agente_id = a.id and', 'al.agente_id = a.id and core.loja_ativa(al.unidade_id) and');
    if v !~ 'loja_ativa' then raise exception 'início não foi atualizado'; end if;
    execute v;
  end if;
end $$;

-- 2. urgências do WhatsApp: só das lojas ativas
do $$ declare v text;
begin
  v := pg_get_functiondef('wa.preparar_avisos()'::regprocedure);
  if v !~ 'loja_ativa' then
    v := replace(v, $a$a.status = 'aberto' and a.aberto_em > v_desde$a$, $a$a.status = 'aberto' and a.aberto_em > v_desde and core.loja_ativa(a.unidade_id)$a$);
    if (length(v) - length(replace(v, 'loja_ativa', ''))) / length('loja_ativa') <> 2 then raise exception 'urgências do WhatsApp não foram atualizadas'; end if;
    execute v;
  end if;
end $$;

-- 3. relatório do dia: só das lojas ativas
do $$ declare v text;
begin
  v := pg_get_functiondef('rel.gerar(date)'::regprocedure);
  if v !~ 'loja_ativa' then
    v := regexp_replace(v, 'from (cx|lab|mkt|cob|com|rh)\.alertas where ', 'from \1.alertas where core.loja_ativa(unidade_id) and ', 'g');
    v := replace(v, 'al.agente_id = a.id and', 'al.agente_id = a.id and core.loja_ativa(al.unidade_id) and');
    v := regexp_replace(v, 'from fin\.arquivos_faltando\(\) f(\s)', 'from fin.arquivos_faltando() f where core.loja_ativa(f.unidade_id)\1');
    if v !~ 'loja_ativa' then raise exception 'relatório não foi atualizado'; end if;
    execute v;
  end if;
end $$;

-- 4. fechamento do caixa: só das lojas ativas
do $$ declare v text;
begin
  v := pg_get_functiondef('cx.fechar_dias(integer)'::regprocedure);
  if v !~ 'loja_ativa' then
    v := replace(v, 'for d in select * from cx.dias x where x.dia >= v_ini loop', 'for d in select * from cx.dias x where x.dia >= v_ini and core.loja_ativa(x.unidade_id) loop');
    if v !~ 'loja_ativa' then raise exception 'fechamento do caixa não foi atualizado'; end if;
    execute v;
  end if;
end $$;

-- 5. tela das lojas
create or replace function public.painel_lojas() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('lojas');
  perform painel._exigir(v_eu, 'administrar', null);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'nome', u.nome, 'ativa', u.ativo, 'criada_em', u.criado_em,
      'codigo_adm', (select string_agg(o.origem, ', ' order by o.origem) from cx.unidades_origem o where o.unidade_id = u.id),
      'codigo_rh', (select string_agg(o.origem, ', ' order by o.origem) from rh.lojas_origem o where o.unidade_id = u.id),
      'funis', (select count(*) from com.funis f where f.unidade_id = u.id),
      'contas_anuncio', (select count(*) from mkt.contas c where c.unidade_id = u.id),
      'contas_banco', (select count(*) from fin.contas c where c.unidade_id = u.id and c.ativo),
      'pessoas', (select count(distinct pp.principal_id) from core.principal_papeis pp where pp.unidade_id = u.id
                    and (pp.valido_ate is null or pp.valido_ate > now()))) order by u.ativo desc, u.nome), '[]'::jsonb)
    from core.unidades u);
end $$;

create or replace function public.painel_loja_salvar(p_id text, p_nome text, p_ativa boolean, p_codigo_adm text, p_codigo_rh text, p_motivo text)
returns jsonb language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_antes jsonb; v_nova boolean; v_adm text := lower(btrim(coalesce(p_codigo_adm, ''))); v_rh text := upper(btrim(coalesce(p_codigo_rh, '')));
begin
  v_eu := painel._entrar('loja_salvar', p_id);
  perform painel._exigir(v_eu, 'administrar', null);
  if p_id is null or p_id !~ '^[a-z][a-z0-9_]{2,30}$' then raise exception 'código da loja inválido (use letras minúsculas, números e _, ex.: santos)' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_nome, ''))) < 3 then raise exception 'informe o nome da loja' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'informe o motivo' using errcode = '22023'; end if;
  if v_adm <> '' and v_adm !~ '^[a-z0-9_]{2,40}$' then raise exception 'código no ADM inválido (ex.: saovicente)' using errcode = '22023'; end if;
  if v_rh <> '' and v_rh !~ '^[A-Z0-9_]{2,40}$' then raise exception 'código no RH 360 inválido (ex.: SAOVICENTE)' using errcode = '22023'; end if;
  if v_adm <> '' and exists (select 1 from cx.unidades_origem o where o.origem = v_adm and o.unidade_id <> p_id) then
    raise exception 'o código % do ADM já é de outra loja', v_adm using errcode = '23505'; end if;
  if v_rh <> '' and exists (select 1 from rh.lojas_origem o where o.origem = v_rh and o.unidade_id <> p_id) then
    raise exception 'o código % do RH 360 já é de outra loja', v_rh using errcode = '23505'; end if;
  if not coalesce(p_ativa, true) and not exists (select 1 from core.unidades u where u.ativo and u.id <> p_id and u.id <> 'administrativo') then
    raise exception 'pelo menos uma loja precisa ficar ativa' using errcode = '22023'; end if;

  select to_jsonb(u) into v_antes from core.unidades u where u.id = p_id;
  v_nova := v_antes is null;
  insert into core.unidades (id, nome, ativo) values (p_id, btrim(p_nome), coalesce(p_ativa, true))
  on conflict (id) do update set nome = excluded.nome, ativo = excluded.ativo;

  -- código da loja nos sistemas: o mesmo no ADM, Lab, cobranças e atribuição; o do RH 360 à parte
  if v_adm <> '' then
    insert into cx.unidades_origem (origem, unidade_id) values (v_adm, p_id) on conflict (origem) do nothing;
    insert into cob.unidades_origem (origem, unidade_id) values (v_adm, p_id) on conflict (origem) do nothing;
    insert into lab.unidades_origem (origem, unidade_id) values (v_adm, p_id) on conflict (origem) do nothing;
    insert into atr.unidades_origem (origem, unidade_id) values (v_adm, p_id) on conflict (origem) do nothing;
  end if;
  if v_rh <> '' then insert into rh.lojas_origem (origem, unidade_id) values (v_rh, p_id) on conflict (origem) do nothing; end if;

  perform core.auditar(v_eu, null, case when v_nova then 'loja_criada' when coalesce(p_ativa, true) <> (v_antes->>'ativo')::boolean
      then case when p_ativa then 'loja_ativada' else 'loja_desativada' end else 'loja_alterada' end,
    'core.unidades', p_id, v_antes, jsonb_build_object('nome', btrim(p_nome), 'ativo', coalesce(p_ativa, true), 'codigo_adm', nullif(v_adm, ''), 'codigo_rh', nullif(v_rh, '')),
    btrim(p_motivo));
  perform cx.fechar_dias(90);
  return public.painel_lojas();
end $$;

do $$ begin
  revoke all on function public.painel_lojas() from public;
  revoke all on function public.painel_loja_salvar(text, text, boolean, text, text, text) from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.painel_lojas() from anon';
    execute 'revoke all on function public.painel_loja_salvar(text, text, boolean, text, text, text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.painel_lojas() to authenticated';
    execute 'grant execute on function public.painel_loja_salvar(text, text, boolean, text, text, text) to authenticated';
  end if;
end $$;
