-- =============================================================================
-- Idealize AI — Multicrediário: carnê anterior ao ADM  · Migração 20261107100000
-- Primeira rodada real (07/11): 21 parcelas recebidas apareceram como "carnê não está no ADM", mas eram de vendas feitas
-- antes de o crediário passar a ser lançado no ADM (São Vicente: desde 25/08/2026). Agora "parcela_sem_carne" só vale
-- para venda que o robô viu aprovada no Multicrediário a partir dessa data (multi.adm_inicio). As regras da conferência (tolerância, unidades, início no ADM)
-- passam a ser editáveis na própria tela Multicrediário (painel_multi_ajustes / painel_multi_ajustes_salvar).
-- =============================================================================
insert into core.config (chave, valor) values ('multi.adm_inicio', '2026-08-25') on conflict (chave) do nothing;

create or replace function multi.conferir() returns jsonb
language plpgsql security definer set search_path = multi, core, pg_catalog as $$
declare n_ab int; n_res int; v_un text[] := string_to_array(regexp_replace(core.cfg('multi.unidades_adm', 'saovicente'), '\s', '', 'g'), ',');
  v_ini date; v_fim date;
begin
  -- período já lido pelo robô: do 1º dia com venda até a véspera da última leitura do relatório Operação
  select min(dia) into v_ini from multi.capturas where relatorio = 'operacao_detalhe';
  select max(capturado_em)::date - 1 into v_fim from multi.capturas where relatorio = 'operacao';
  drop table if exists _dev;
  create temp table _dev (tipo text, chave text, dia date, descricao text, detalhe jsonb) on commit drop;

  insert into _dev
  select case when situacao = 'ok' then null else situacao end, 'venda:' || venda, dia,
    case situacao
      when 'venda_sem_adm' then format('Venda %s aprovada no Multicrediário (R$ %s financiado) sem crediário Multicrédito no ADM', venda, multi._brl(garantido))
      when 'valor_com_entrada' then format('OS %s: o ADM tem R$ %s, mas o financiado é R$ %s (o ADM somou a entrada de R$ %s)', os, multi._brl(valor_adm), multi._brl(garantido), multi._brl(entrada))
      when 'centavos' then format('OS %s: diferença de centavos (ADM R$ %s × Multicrediário R$ %s)', os, multi._brl(valor_adm), multi._brl(garantido))
      else format('OS %s: valor diferente (ADM R$ %s × Multicrediário R$ %s)', os, multi._brl(valor_adm), multi._brl(garantido)) end,
    jsonb_build_object('venda', venda, 'os', os, 'adm', valor_adm, 'multi', garantido, 'total', total, 'entrada', entrada, 'cpf_fim', cpf_fim)
  from multi.v_conferencia where situacao <> 'ok';
  delete from _dev where tipo is null;

  insert into _dev
  select 'sem_os', 'venda:' || venda, dia, format('Venda %s (R$ %s) está no ADM sem número de OS', venda, multi._brl(garantido)),
    jsonb_build_object('venda', venda, 'multi', garantido)
  from multi.v_conferencia where ids is not null and sem_os;

  insert into _dev
  select 'data_diferente', 'venda:' || venda, dia, format('OS %s: venda em %s no Multicrediário, lançada no ADM em %s', os, to_char(dia, 'DD/MM'), to_char(dt_adm, 'DD/MM')),
    jsonb_build_object('venda', venda, 'os', os, 'dia_multi', dia, 'dia_adm', dt_adm)
  from multi.v_conferencia where ids is not null and dt_adm <> dia;

  -- crediário Multicrédito no ADM sem venda aprovada no Multicrediário (só no período já lido pelo robô)
  if v_ini is not null then
    insert into _dev
    select 'adm_sem_venda', 'adm:' || a.crediario_id, a.dt_compra,
      format('OS %s: crediário Multicrédito de R$ %s no ADM sem venda aprovada no Multicrediário', coalesce(a.os, '(sem OS)'), multi._brl(a.valor_crediario)),
      jsonb_build_object('os', a.os, 'adm', a.valor_crediario)
    from multi.adm_vendas a
    where a.unidade = any(v_un) and coalesce(a.status, '') <> 'cancelado' and a.dt_compra between v_ini and v_fim
      and not exists (select 1 from multi.v_operacoes o where o.tipo = 1 and o.cpf_hash = a.cpf_hash and o.dia between a.dt_compra - 7 and a.dt_compra + 3);
  end if;

  -- parcela recebida no Multicrediário × baixa no ADM
  insert into _dev
  select case when c.ids is null then 'parcela_sem_carne' else 'parcela_sem_baixa' end, 'parcela:' || r.venda || ':' || r.parcela, r.dia,
    case when c.ids is null then format('Parcela %s da venda %s (R$ %s) recebida no Multicrediário em %s, mas o carnê não está no ADM', r.parcela, r.venda, multi._brl(r.valor), to_char(r.dia, 'DD/MM'))
         else format('Parcela %s da OS %s (R$ %s) recebida no Multicrediário em %s e sem baixa no ADM', r.parcela, c.os, multi._brl(r.valor), to_char(r.dia, 'DD/MM')) end,
    jsonb_build_object('venda', r.venda, 'parcela', r.parcela, 'valor', r.valor, 'os', c.os)
  from multi.v_recebidas r
  left join lateral (select array_agg(v.crediario_id) ids, string_agg(coalesce(v.os, '(sem OS)'), ' + ') os from multi.adm_vendas v
                      where v.cpf_hash = r.cpf_hash and v.unidade = any(v_un)) c on true
  where r.dia is not null and r.dia <= current_date
    -- sem carnê no ADM só conta se a venda foi aprovada depois que o crediário passou a ser lançado no ADM
    and (c.ids is not null or exists (select 1 from multi.v_operacoes o where o.tipo = 1 and o.venda = r.venda
           and o.dia >= coalesce(nullif(core.cfg('multi.adm_inicio', ''), '')::date, '2026-08-25'::date)))
    and not exists (select 1 from multi.adm_parcelas p where p.crediario_id = any(coalesce(c.ids, '{}')) and p.numero = r.parcela and p.dt_pagamento is not null);

  -- documento obrigatório faltando ou não aprovado (a partir do dia seguinte à venda)
  insert into _dev
  select 'documento_pendente', 'doc:' || d.venda || ':' || d.documento, d.dia,
    format('Venda %s: documento obrigatório "%s" %s', d.venda, d.documento, case when coalesce(d.quantidade, 0) = 0 then 'não foi enviado' else 'ainda não foi aprovado (' || lower(d.situacao) || ')' end),
    jsonb_build_object('venda', d.venda, 'documento', d.documento, 'quantidade', d.quantidade, 'situacao', d.situacao)
  from multi.v_documentos d
  where d.obrigatorio and (coalesce(d.quantidade, 0) = 0 or d.situacao <> 'POSITIVADO') and d.dia < current_date;

  insert into multi.achados (tipo, chave, dia, descricao, detalhe)
  select distinct on (tipo, chave) tipo, chave, dia, descricao, detalhe from _dev
  on conflict (tipo, chave) where status = 'aberto' do update set descricao = excluded.descricao, detalhe = excluded.detalhe, dia = excluded.dia;
  get diagnostics n_ab = row_count;
  update multi.achados a set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente: situação deixou de existir'
   where a.status = 'aberto' and not exists (select 1 from _dev d where d.tipo = a.tipo and d.chave = a.chave);
  get diagnostics n_res = row_count;
  return jsonb_build_object('avisos', n_ab, 'fechados', n_res,
    'vendas', (select count(*) from multi.v_conferencia), 'vendas_ok', (select count(*) from multi.v_conferencia where situacao = 'ok'));
end $$;

-- regras da conferência, para a tela (quem pode consultar vê; quem administra altera)
create or replace function multi._ajustes() returns jsonb language sql stable set search_path = core, pg_catalog as $$
  select jsonb_build_object(
    'unidades', core.cfg('multi.unidades_adm', 'saovicente'),
    'tolerancia', coalesce(nullif(core.cfg('multi.tolerancia', ''), '')::numeric, 0.01),
    'adm_inicio', coalesce(nullif(core.cfg('multi.adm_inicio', ''), '')::date, '2026-08-25'::date))
$$;

create or replace function public.painel_multi_ajustes() returns jsonb
language plpgsql security definer set search_path = multi, core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('multi_ajustes');
  if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão' using errcode = '42501'; end if;
  return multi._ajustes() || jsonb_build_object('pode_editar', painel._pode(v_eu, 'administrar'));
end $$;

create or replace function public.painel_multi_ajustes_salvar(p_tolerancia numeric, p_adm_inicio date, p_unidades text, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = multi, core, pg_catalog as $$
declare v_eu uuid; v_antes jsonb := multi._ajustes(); v_un text;
begin
  v_eu := painel._entrar('multi_ajustes_salvar');
  perform painel._exigir(v_eu, 'administrar');
  if p_tolerancia is null or p_tolerancia < 0 or p_tolerancia > 5 then raise exception 'tolerância: de R$ 0,00 a R$ 5,00' using errcode = '22023'; end if;
  if p_adm_inicio is null or p_adm_inicio < date '2020-01-01' or p_adm_inicio > current_date then raise exception 'data de início inválida' using errcode = '22023'; end if;
  v_un := array_to_string(array(select distinct lower(btrim(e)) from unnest(string_to_array(coalesce(p_unidades, ''), ',')) e where lower(btrim(e)) ~ '^[a-z0-9_]{2,40}$'), ',');
  if v_un = '' then raise exception 'informe ao menos uma unidade do ADM (ex.: saovicente)' using errcode = '22023'; end if;
  insert into core.config (chave, valor) values ('multi.tolerancia', round(p_tolerancia, 2)::text), ('multi.adm_inicio', p_adm_inicio::text), ('multi.unidades_adm', v_un)
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  perform core.auditar(v_eu, null, 'multi_ajustes_alterados', 'core.config', 'multi', v_antes, multi._ajustes(), nullif(btrim(coalesce(p_motivo, '')), ''));
  perform multi.conferir();
  return multi._ajustes();
end $$;

do $$ declare f text; begin
  foreach f in array array['multi.conferir()', 'multi._ajustes()', 'public.painel_multi_ajustes()', 'public.painel_multi_ajustes_salvar(numeric,date,text,text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', f); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.painel_multi_ajustes() to authenticated';
    execute 'grant execute on function public.painel_multi_ajustes_salvar(numeric,date,text,text) to authenticated';
  end if;
end $$;

select multi.conferir();
