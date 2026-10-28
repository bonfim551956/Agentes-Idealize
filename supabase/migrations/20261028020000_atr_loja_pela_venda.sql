-- =============================================================================
-- Idealize AI — Atribuição: loja do lead pela VENDA quando o funil não tem loja  · Migração 20261028020000
-- Achado na 1ª carga (28/10): os funis da Kommo (pré-vendas) não têm loja definida → nenhum lead casava.
-- Agora: funil com loja → casa só com venda daquela loja (como antes); funil SEM loja → casa com a venda do mesmo
-- telefone em qualquer loja, e o lead passa a contar para a loja onde comprou. Lead sem loja que não comprou fica à
-- parte ("leads sem loja"). A campanha exata pela origem também vale para lead sem loja.
-- =============================================================================
create or replace function atr.recalcular() returns int
language plpgsql security definer set search_path = atr, mkt, core, pg_catalog as $$
declare v_jan int := atr._cfg_int('atr.janela_conversao_dias', 60); n int;
begin
  -- campanha exata: a origem do lead cita o id ou o nome da campanha da Meta
  update atr.leads l set campanha_id = (
    select c.id from mkt.campanhas c join mkt.contas ct on ct.id = c.conta_id
    where l.origem is not null and (l.origem like '%' || c.id || '%' or (length(c.nome) >= 6 and lower(l.origem) like '%' || lower(c.nome) || '%'))
      and (ct.unidade_id is null or l.unidade_id is null or ct.unidade_id = l.unidade_id)
    order by length(c.nome) desc limit 1);

  delete from atr.conversoes;
  insert into atr.conversoes (lead_id, venda_id, unidade_id, dia_lead, dia_venda, valor, nova)
  select distinct on (x.venda_id) x.lead_id, x.venda_id, x.unidade_id, x.dia_lead, x.dia_venda, x.valor, x.nova
  from (
    select distinct on (l.id) l.id lead_id, v.id venda_id, v.unidade_id, (l.criado_em at time zone 'America/Sao_Paulo')::date dia_lead,
           v.dia dia_venda, v.valor,
           not exists (select 1 from atr.vendas a where a.tel_hash = l.tel_hash and a.dia < (l.criado_em at time zone 'America/Sao_Paulo')::date) nova
    from atr.leads l
    join atr.vendas v on v.tel_hash = l.tel_hash and (l.unidade_id is null or v.unidade_id = l.unidade_id) and v.valor > 0
     and v.dia between (l.criado_em at time zone 'America/Sao_Paulo')::date and (l.criado_em at time zone 'America/Sao_Paulo')::date + v_jan
    where l.tel_hash is not null
    order by l.id, v.dia, v.id) x
  order by x.venda_id, x.dia_lead, x.lead_id;
  get diagnostics n = row_count;
  return n;
end $$;


create or replace function atr.validar_sincronizacao(p_tarefa uuid, p_validador text) returns text
language plpgsql security definer set search_path = atr, core, pg_catalog as $$
declare t record; s record; v_erros text[] := '{}'; n int; v_jan int := atr._cfg_int('atr.janela_conversao_dias', 60);
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  select * into s from atr.sincronizacoes where tarefa_id = p_tarefa order by em desc limit 1;
  if s.id is null then
    v_erros := v_erros || 'sincronização sem registro';
  else
    select count(*) into n from atr.vendas where sincronizacao_id = s.id;
    if n <> s.vendas then v_erros := v_erros || format('espelho tem %s vendas, registro diz %s', n, s.vendas); end if;
    -- toda conversão respeita as regras (mesmo código, mesma loja, dentro da janela, venda com valor)
    select count(*) into n from atr.conversoes c join atr.leads l on l.id = c.lead_id join atr.vendas v on v.id = c.venda_id
     where l.tel_hash is distinct from v.tel_hash or (l.unidade_id is not null and l.unidade_id <> v.unidade_id) or c.unidade_id is distinct from v.unidade_id or v.valor <= 0
        or v.dia < c.dia_lead or v.dia > c.dia_lead + v_jan or c.valor <> v.valor;
    if n > 0 then v_erros := v_erros || format('%s conversões fora das regras', n); end if;
    -- nenhum telefone em claro no espelho
    select count(*) into n from atr.leads where tel_hash !~ '^[0-9a-f]{64}$' or coalesce(origem, '') ~ '(^|[^0-9])[0-9]{10,13}([^0-9]|$)';
    if n > 0 then v_erros := v_erros || format('%s leads com possível telefone em claro', n); end if;
  end if;
  if array_length(v_erros, 1) is null then
    return core.registrar_validacao(p_tarefa, p_validador, true, null, jsonb_build_object('sincronizacao', s.id));
  end if;
  return core.registrar_validacao(p_tarefa, p_validador, false, array_to_string(v_erros, '; '),
    jsonb_build_object('sincronizacao', s.id, 'erros', to_jsonb(v_erros)));
end $$;


create or replace function public.painel_atribuicao(p_unidade text default null, p_dias int default 30) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[]; d date := atr._hoje(); n int := least(greatest(coalesce(p_dias, 30), 7), 120); v_ini date;
  v_jan int := atr._cfg_int('atr.janela_conversao_dias', 60);
begin
  v_eu := painel._entrar('atribuicao', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; end if;
  v_ini := d - (n - 1);

  drop table if exists _gasto;
  create temp table _gasto on commit drop as
    select ct.unidade_id, m.dia, m.campanha_id, sum(m.gasto) gasto, sum(m.conversas + m.leads) resultados_meta
    from mkt.metricas m join mkt.contas ct on ct.id = m.conta_id join mkt.campanhas c on c.id = m.campanha_id
    where m.dia between v_ini and d and not c.recrutamento and ct.unidade_id = any(un)
    group by ct.unidade_id, m.dia, m.campanha_id;
  drop table if exists _ld;
  create temp table _ld on commit drop as
    select l.id, coalesce(l.unidade_id, c.unidade_id) unidade_id, l.responsavel_id, (l.criado_em at time zone 'America/Sao_Paulo')::date dia, l.campanha_id, l.tel_hash is not null com_tel,
           c.valor, c.nova, c.venda_id is not null convertido
    from atr.leads l left join atr.conversoes c on c.lead_id = l.id
    where (l.criado_em at time zone 'America/Sao_Paulo')::date between v_ini and d and coalesce(l.unidade_id, c.unidade_id) = any(un);

  return jsonb_build_object(
    'desde', v_ini, 'ate', d, 'janela_conversao_dias', v_jan,
    'janela_aberta_desde', greatest(v_ini, d - v_jan),
    -- leads de funil sem loja definida e que (ainda) não compraram: não entram em nenhuma loja
    'leads_sem_loja', case when painel._pode(v_eu, 'consultar') then (select count(*) from atr.leads l
        where l.unidade_id is null and (l.criado_em at time zone 'America/Sao_Paulo')::date between v_ini and d
          and not exists (select 1 from atr.conversoes c where c.lead_id = l.id)) end,
    'sincronizacao', jsonb_build_object('ativa', core.cfg('atr.sync.ativo', 'false') = 'true',
       'agente', (select status from core.agentes where id = 'atribuicao'),
       'ultima', (select jsonb_build_object('em', em, 'leads', leads, 'leads_com_telefone', leads_com_telefone, 'vendas', vendas, 'conversoes', conversoes)
                  from atr.sincronizacoes order by em desc limit 1)),
    'lojas', (select coalesce(jsonb_agg(x order by x->>'unidade_id'), '[]'::jsonb) from (
      select jsonb_build_object('unidade_id', u.unidade_id,
        'investido', coalesce((select sum(gasto) from _gasto g where g.unidade_id = u.unidade_id), 0),
        'resultados_meta', coalesce((select sum(resultados_meta) from _gasto g where g.unidade_id = u.unidade_id), 0),
        'leads', (select count(*) from _ld l where l.unidade_id = u.unidade_id),
        'leads_com_telefone', (select count(*) from _ld l where l.unidade_id = u.unidade_id and l.com_tel),
        'compraram', (select count(*) from _ld l where l.unidade_id = u.unidade_id and l.convertido),
        'compraram_novos', (select count(*) from _ld l where l.unidade_id = u.unidade_id and l.convertido and l.nova),
        'faturamento', coalesce((select sum(valor) from _ld l where l.unidade_id = u.unidade_id and l.convertido), 0),
        'faturamento_novos', coalesce((select sum(valor) from _ld l where l.unidade_id = u.unidade_id and l.convertido and l.nova), 0)) x
      from (select distinct unidade_id from _gasto union select distinct unidade_id from _ld) u where u.unidade_id is not null) q),
    -- por atendente responsável na Kommo
    'atendentes', (select coalesce(jsonb_agg(x order by (x->>'faturamento')::numeric desc, (x->>'leads')::int desc), '[]'::jsonb) from (
      select jsonb_build_object('responsavel_id', l.responsavel_id,
        'nome', coalesce((select nome from com.usuarios u where u.id = l.responsavel_id), case when l.responsavel_id is null then null else 'Atendente ' || l.responsavel_id end),
        'unidades', (select jsonb_agg(distinct l2.unidade_id) from _ld l2 where l2.responsavel_id is not distinct from l.responsavel_id),
        'leads', count(*), 'compraram', count(*) filter (where l.convertido), 'compraram_novos', count(*) filter (where l.convertido and l.nova),
        'faturamento', coalesce(sum(l.valor) filter (where l.convertido), 0),
        'faturamento_novos', coalesce(sum(l.valor) filter (where l.convertido and l.nova), 0)) x
      from _ld l group by l.responsavel_id) q),
    -- por campanha: leads exatos + rateio dos leads sem origem pelo gasto da campanha no dia/loja
    'campanhas', (select coalesce(jsonb_agg(x order by (x->>'investido')::numeric desc), '[]'::jsonb) from (
      select jsonb_build_object('campanha_id', g.campanha_id, 'nome', (select nome from mkt.campanhas where id = g.campanha_id),
        'unidade_id', min(g.unidade_id), 'investido', sum(g.gasto),
        'leads', round(sum(coalesce(r.leads, 0))::numeric, 1), 'compraram', round(sum(coalesce(r.compraram, 0))::numeric, 1),
        'faturamento', round(sum(coalesce(r.faturamento, 0))::numeric, 2), 'faturamento_novos', round(sum(coalesce(r.faturamento_novos, 0))::numeric, 2),
        'exatos', sum(coalesce(r.exatos, 0))) x
      from _gasto g
      cross join lateral (select sum(g2.gasto) total from _gasto g2 where g2.unidade_id = g.unidade_id and g2.dia = g.dia) t
      left join lateral (
        select
          -- parcela estimada (leads sem campanha identificada, divididos pelo gasto do dia)
          coalesce(sum(case when l.campanha_id is null then 1 else 0 end), 0) * g.gasto / nullif(t.total, 0)
            + count(*) filter (where l.campanha_id = g.campanha_id) as leads,
          coalesce(sum(case when l.campanha_id is null and l.convertido then 1 else 0 end), 0) * g.gasto / nullif(t.total, 0)
            + count(*) filter (where l.campanha_id = g.campanha_id and l.convertido) as compraram,
          coalesce(sum(case when l.campanha_id is null and l.convertido then l.valor else 0 end), 0) * g.gasto / nullif(t.total, 0)
            + coalesce(sum(l.valor) filter (where l.campanha_id = g.campanha_id and l.convertido), 0) as faturamento,
          coalesce(sum(case when l.campanha_id is null and l.convertido and l.nova then l.valor else 0 end), 0) * g.gasto / nullif(t.total, 0)
            + coalesce(sum(l.valor) filter (where l.campanha_id = g.campanha_id and l.convertido and l.nova), 0) as faturamento_novos,
          count(*) filter (where l.campanha_id = g.campanha_id) as exatos
        from _ld l
        where l.unidade_id = g.unidade_id and l.dia = g.dia) r on true
      group by g.campanha_id having sum(g.gasto) > 0) q));
end $$;

