-- =============================================================================
-- Idealize AI — Comercial: tempo MÉDIO de resposta por atendente  · Migração 20261027170000
-- Média contada só dentro do horário de atendimento (padrão 09:00–19:00, segunda a sábado; configurável), para
-- que a mensagem que chega de madrugada não infle a média. A mediana (tempo corrido) continua.
-- =============================================================================
insert into core.config (chave, valor) values
  ('com.horario_atendimento', '09:00-19:00'),
  ('com.dias_atendimento', '1,2,3,4,5,6')      -- 1 = segunda … 7 = domingo
on conflict (chave) do nothing;

-- minutos entre duas datas que caem dentro do horário de atendimento (fuso de São Paulo)
create or replace function com._minutos_uteis(p_ini timestamptz, p_fim timestamptz) returns numeric
language sql stable security definer set search_path = core, pg_catalog as $$
  with c as (select split_part(core.cfg('com.horario_atendimento', '09:00-19:00'), '-', 1)::time hi,
                    split_part(core.cfg('com.horario_atendimento', '09:00-19:00'), '-', 2)::time hf,
                    string_to_array(replace(core.cfg('com.dias_atendimento', '1,2,3,4,5,6'), ' ', ''), ',')::int[] dias),
       l as (select (p_ini at time zone 'America/Sao_Paulo') a, (p_fim at time zone 'America/Sao_Paulo') b)
  select coalesce(sum(greatest(0, extract(epoch from (least(l.b, d + c.hf) - greatest(l.a, d + c.hi))) / 60.0)), 0)
  from l, c, generate_series(date_trunc('day', l.a), date_trunc('day', l.b), interval '1 day') d
  where p_ini is not null and p_fim > p_ini and extract(isodow from d)::int = any(c.dias)
$$;
revoke all on function com._minutos_uteis(timestamptz, timestamptz) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function com._minutos_uteis(timestamptz, timestamptz) from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function com._minutos_uteis(timestamptz, timestamptz) to service_role';
  end if;
end $$;

create or replace function public.painel_comercial(p_unidade text default null, p_dias int default 7) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[]; g boolean; d int := least(greatest(coalesce(p_dias, 7), 1), 90); v_ini timestamptz;
  v_lim int := com._cfg_int('com.limite_resposta_min', 30);
begin
  v_eu := painel._entrar('comercial', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; g := false; end if;
  v_ini := now() - make_interval(days => d);
  return jsonb_build_object(
    'periodo_dias', d, 'limite_resposta_min', v_lim,
    'horario_atendimento', core.cfg('com.horario_atendimento', '09:00-19:00'), 'dias_atendimento', core.cfg('com.dias_atendimento', '1,2,3,4,5,6'),
    'sincronizacao', jsonb_build_object('ativa', core.cfg('com.sync.ativo', 'false') = 'true',
       'agente', (select status from core.agentes where id = 'comercial'),
       'ultima', (select jsonb_build_object('em', em, 'ate', ate, 'leads', leads, 'mensagens_novas', mensagens_novas)
                  from com.sincronizacoes order by em desc limit 1)),
    'lojas', (select coalesce(jsonb_agg(x order by x->>'nome'), '[]'::jsonb) from (
      select jsonb_build_object('id', coalesce(f.unidade_id, '_sem_loja'),
        'nome', coalesce((select nome from core.unidades where id = f.unidade_id), 'Funis sem loja definida'),
        'leads_novos', count(*) filter (where l.criado_em >= v_ini),
        'ganhos', count(*) filter (where e.tipo = 'ganha' and l.fechado_em >= v_ini),
        'perdidos', count(*) filter (where e.tipo = 'perdida' and l.fechado_em >= v_ini),
        'valor_ganho', coalesce(sum(l.valor) filter (where e.tipo = 'ganha' and l.fechado_em >= v_ini), 0),
        'em_aberto', count(*) filter (where e.tipo in ('entrada','aberta'))) x
      from com.leads l join com.funis f on f.id = l.funil_id join com.etapas e on e.funil_id = l.funil_id and e.id = l.etapa_id
      where not l.excluido and ((g and f.unidade_id is null) or f.unidade_id = any(un))
      group by f.unidade_id) q),
    'atendentes', (select coalesce(jsonb_agg(x order by (x->>'respondidas')::int desc), '[]'::jsonb) from (
      select jsonb_build_object('id', u.id, 'nome', u.nome,
        'respondidas', count(r.*),
        'mediana_min', round((percentile_cont(0.5) within group (order by r.minutos))::numeric, 1),
        'media_min', round((avg(com._minutos_uteis(r.cliente_em, r.resposta_em)) filter (where r.resposta_em is not null))::numeric, 1),
        'no_limite_pct', round(100.0 * count(*) filter (where r.minutos <= v_lim) / nullif(count(r.*), 0), 1),
        'ganhos', (select count(*) from com.leads l2 join com.etapas e2 on e2.funil_id = l2.funil_id and e2.id = l2.etapa_id
                   join com.funis f2 on f2.id = l2.funil_id
                   where l2.responsavel_id = u.id and e2.tipo = 'ganha' and l2.fechado_em >= v_ini and not l2.excluido
                     and ((g and f2.unidade_id is null) or f2.unidade_id = any(un)))) x
      from com.usuarios u
      join com.v_respostas r on r.usuario_id = u.id and r.cliente_em >= v_ini
      left join com.leads l on r.entidade_tipo = 'lead' and l.id = r.entidade_id
      left join com.funis f on f.id = l.funil_id
      where (g and f.unidade_id is null) or f.unidade_id = any(un)
      group by u.id, u.nome) q),
    'resposta_geral', (select jsonb_build_object('respondidas', count(*) filter (where r.resposta_em is not null),
        'mediana_min', round((percentile_cont(0.5) within group (order by r.minutos))::numeric, 1),
        'media_min', round((avg(com._minutos_uteis(r.cliente_em, r.resposta_em)) filter (where r.resposta_em is not null))::numeric, 1),
        'no_limite_pct', round(100.0 * count(*) filter (where r.minutos <= v_lim) / nullif(count(*) filter (where r.resposta_em is not null), 0), 1))
      from com.v_respostas r
      left join com.leads l on r.entidade_tipo = 'lead' and l.id = r.entidade_id
      left join com.funis f on f.id = l.funil_id
      where r.cliente_em >= v_ini and ((g and f.unidade_id is null) or f.unidade_id = any(un))),
    'alertas', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'referencia', a.referencia, 'unidade_id', a.unidade_id,
        'responsavel', (select nome from com.usuarios where id = a.responsavel_id), 'aberto_em', a.aberto_em,
        'detalhe', painel._mascarar(a.detalhe)) x
      from com.alertas a
      where a.status = 'aberto' and ((g and a.unidade_id is null) or a.unidade_id = any(un))
      order by case a.tipo when 'cliente_sem_resposta' then 0 when 'lead_sem_responsavel' then 1 when 'funil_sem_loja' then 2 else 3 end,
               a.aberto_em
      limit 300) q),
    'funis', case when g then (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'nome', f.nome, 'unidade_id', f.unidade_id)
        order by f.nome), '[]'::jsonb) from com.funis f) end);
end $$;
