-- =============================================================================
-- Idealize AI — Multicrediário: documento enviado  · Migração 20261107110000
-- Conferido em 07/11 no Multicrediário (Foto/Documentos): a "Proposta Simplificada" continua ATIVO mesmo um mês depois
-- da venda, com o arquivo enviado. Então ATIVO com quantidade > 0 = enviado. Vira aviso: documento obrigatório com
-- quantidade 0 (não enviado) ou em situação diferente de POSITIVADO/ATIVO (ex.: recusado).
-- Também: public.multi_docs_fila(dias) = vendas aprovadas que o robô deve abrir em Foto/Documentos (cliente por cliente).
-- =============================================================================
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
    format('Venda %s: documento obrigatório "%s" %s', d.venda, d.documento, case when coalesce(d.quantidade, 0) = 0 then 'não foi enviado' else 'está como ' || lower(d.situacao) || ' no Multicrediário' end),
    jsonb_build_object('venda', d.venda, 'documento', d.documento, 'quantidade', d.quantidade, 'situacao', d.situacao)
  from multi.v_documentos d
  where d.obrigatorio and (coalesce(d.quantidade, 0) = 0 or upper(coalesce(d.situacao, '')) not in ('POSITIVADO', 'ATIVO')) and d.dia < current_date;

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

revoke all on function multi.conferir() from public;

-- vendas aprovadas dos últimos N dias cujos documentos o robô ainda precisa ler (nunca lidos, ou com pendência e lidos há
-- mais de 12 h). Só a chave de serviço (robô) chama; o CPF sai daqui só para a busca no próprio Multicrediário.
create or replace function public.multi_docs_fila(p_dias int default 30, p_limite int default 80)
returns table (cpf text, venda text, dia date)
language sql stable security definer set search_path = multi, pg_catalog as $$
  with v as (
    select distinct on (l->>k.venda) regexp_replace(l->>k.cpf, '\D', '', 'g') cpf, l->>k.venda venda, c.dia
      from multi.capturas c
      cross join lateral (select multi._col(c.cabecalho, 'Nº Venda') venda, multi._col(c.cabecalho, 'CPF') cpf) k
      cross join lateral jsonb_array_elements(c.linhas) l
     where c.relatorio = 'operacao_detalhe' and c.referencia like 'Tipo=1&%' and k.cpf is not null
       and c.dia >= current_date - least(greatest(coalesce(p_dias, 30), 1), 90)
     order by l->>k.venda, c.dia)
  select v.cpf, v.venda, v.dia from v
   where length(v.cpf) in (11, 14)
     and not exists (select 1 from multi.capturas d where d.relatorio = 'documentos' and d.referencia = v.cpf || '|' || v.venda
                       and (d.capturado_em > now() - interval '12 hours'
                            or not exists (select 1 from multi.v_documentos x where x.venda = v.venda and x.capturado_em = d.capturado_em and x.obrigatorio
                                             and (coalesce(x.quantidade, 0) = 0 or x.situacao not in ('POSITIVADO', 'ATIVO')))))
   order by v.dia desc
   limit least(greatest(coalesce(p_limite, 80), 1), 200)
$$;
do $$ begin
  revoke all on function public.multi_docs_fila(int, int) from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on function public.multi_docs_fila(int,int) from anon, authenticated'; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then execute 'grant execute on function public.multi_docs_fila(int,int) to service_role'; end if;
end $$;

select multi.conferir();
