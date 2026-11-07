-- =============================================================================
-- Idealize AI — "lead parado" calibrado  · Migração 20261107050000
-- Pedido do Diego (07/11), junto com o Relatório do dia: o aviso de lead parado contava todo lead aberto sem
-- movimento há 3 dias (~4 mil avisos, quase todos de quem nunca respondeu) e escondia o que importa.
-- Agora: lead aberto em que o CLIENTE mandou a última mensagem e está sem resposta há mais de 7 dias
-- (de 30 min a 7 dias continua sendo "cliente sem resposta"). Os avisos antigos que não se encaixam são
-- encerrados na próxima leitura, como sempre ("situação deixou de existir").
-- =============================================================================
update core.config set valor = '7' where chave = 'com.lead_parado_dias' and valor = '3';

create or replace function com.recalcular_alertas() returns jsonb
language plpgsql security definer set search_path = com, core, pg_catalog as $$
declare v_lim int := com._cfg_int('com.limite_resposta_min', 30);
  v_par int := com._cfg_int('com.lead_parado_dias', 7); v_jan int := com._cfg_int('com.lead_parado_janela_dias', 60);
  n_ab int; n_res int;
begin
  drop table if exists _devidos;
  create temp table _devidos (tipo text, referencia text, unidade_id text, responsavel_id bigint, detalhe jsonb) on commit drop;

  insert into _devidos
  select 'cliente_sem_resposta', c.entidade_tipo || ':' || c.entidade_id, f.unidade_id, l.responsavel_id,
         jsonb_build_object('desde', c.ultima_em, 'minutos', floor(extract(epoch from now() - c.ultima_em) / 60), 'limite_min', v_lim)
  from com.v_conversas c
  left join com.leads l on c.entidade_tipo = 'lead' and l.id = c.entidade_id
  left join com.funis f on f.id = l.funil_id
  where c.ultimo_sentido = 'cliente' and c.ultima_em < now() - make_interval(mins => v_lim)
    and c.ultima_em > now() - interval '7 days'              -- conversa abandonada há mais de 7 dias não é "esperando"
    and coalesce(l.excluido, false) = false;

  insert into _devidos
  select 'lead_sem_responsavel', 'lead:' || l.id, f.unidade_id, null, jsonb_build_object('criado_em', l.criado_em)
  from com.leads l join com.funis f on f.id = l.funil_id join com.etapas e on e.funil_id = l.funil_id and e.id = l.etapa_id
  where e.tipo in ('entrada','aberta') and not l.excluido and coalesce(l.responsavel_id, 0) = 0;

  -- lead parado = o CLIENTE falou por último e ninguém respondeu há mais de N dias (calibrado em 07/11: antes contava
  -- qualquer lead aberto sem movimento, ~4 mil avisos de leads que nunca responderam; isso escondia o que importa)
  insert into _devidos
  select 'lead_parado', 'lead:' || l.id, f.unidade_id, l.responsavel_id,
         jsonb_build_object('etapa', e.nome, 'cliente_falou_em', c.ultima_em,
           'dias', floor(extract(epoch from now() - c.ultima_em) / 86400), 'limite_dias', v_par)
  from com.v_conversas c
  join com.leads l on c.entidade_tipo = 'lead' and l.id = c.entidade_id
  join com.funis f on f.id = l.funil_id join com.etapas e on e.funil_id = l.funil_id and e.id = l.etapa_id
  where e.tipo in ('entrada','aberta') and not l.excluido and c.ultimo_sentido = 'cliente'
    and c.ultima_em < now() - make_interval(days => v_par) and c.ultima_em > now() - make_interval(days => v_jan);

  insert into _devidos
  select 'funil_sem_loja', 'funil:' || f.id, null, null, jsonb_build_object('funil', f.nome)
  from com.funis f where f.unidade_id is null and exists (select 1 from com.leads l where l.funil_id = f.id and not l.excluido);

  insert into com.alertas (tipo, referencia, unidade_id, responsavel_id, detalhe)
  select tipo, referencia, unidade_id, responsavel_id, detalhe from _devidos
  on conflict (tipo, referencia) where status = 'aberto'
  do update set detalhe = excluded.detalhe, unidade_id = excluded.unidade_id, responsavel_id = excluded.responsavel_id;
  get diagnostics n_ab = row_count;

  update com.alertas a set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente_comercial: situação deixou de existir'
   where a.status = 'aberto' and not exists (select 1 from _devidos d where d.tipo = a.tipo and d.referencia = a.referencia);
  get diagnostics n_res = row_count;
  return jsonb_build_object('ativos', n_ab, 'resolvidos', n_res);
end $$;
