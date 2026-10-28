-- =============================================================================
-- Idealize AI — dois acertos achados na 1ª verificação do Supervisor  · Migração 20261028050000
-- 1. Agente Financeiro tem DOIS trabalhos (canal do WhatsApp e leitura dos arquivos enviados pelo painel). O Supervisor
--    olhava só o WhatsApp e acusava "ligado pela metade" com a leitura de arquivos ligada. Agora a chave do agente pode
--    listar várias (separadas por vírgula): basta uma estar ligada.
-- 2. Atribuição: cada rodada criava uma tarefa nova mesmo com outra esperando na fila, e sempre sobrava uma para o dia
--    seguinte ("fila parada"). Agora, se já há tarefa esperando, a rodada usa essa.
-- =============================================================================
create or replace view sup.v_saude as
  select a.id agente_id, a.nome, a.status, a.atualizado_em agente_atualizado_em,
         coalesce((select bool_or(core.cfg(btrim(k), 'false') = 'true') from unnest(string_to_array(l.chave_ativo, ',')) k), false) sync_ativo,
         l.max_minutos limite_min,
         u.em ultima_leitura,
         case when u.em is null then null else floor(extract(epoch from now() - u.em) / 60)::int end minutos_desde,
         coalesce(al.abertos, 0) alertas_abertos,
         (select count(*)::int from core.tarefas t where t.agente_id = a.id and t.status in ('falhou','incerta','bloqueada')
           and t.atualizado_em > now() - interval '24 hours') problemas_24h,
         (select t.status from core.tarefas t where t.agente_id = a.id order by t.criado_em desc limit 1) ultima_tarefa
  from core.agentes a
  left join sup.limites l on l.agente_id = a.id
  left join sup.v_ultimas u on u.agente_id = a.id
  left join sup.v_alertas al on al.agente_id = a.id
  where a.status <> 'desativado';

update sup.limites set chave_ativo = 'fin.whatsapp.ativo,fin.envios.ativo'
 where agente_id = 'financeiro' and chave_ativo = 'fin.whatsapp.ativo';

create or replace function atr.agendar_sincronizacao() returns uuid
language plpgsql security definer set search_path = atr, core, pg_catalog as $$
declare v_p uuid; v_t uuid;
begin
  if core.cfg('atr.sync.ativo', 'false') <> 'true' then return null; end if;
  -- já tem leitura esperando ou em andamento: usa essa (não acumula fila)
  select id into v_t from core.tarefas
   where agente_id = 'atribuicao' and tipo = 'atr_sincronizacao' and status in ('pronta','executando','validando','aguardando_aprovacao')
   order by criado_em limit 1;
  if v_t is not null then return v_t; end if;
  select id into v_p from core.principais where agente_id = 'atribuicao';
  return core.criar_tarefa(v_p, 'atribuicao', 'atr_sincronizacao', 'atr.cruzamento', 'sincronizar', null,
    jsonb_build_object('origem', 'kommo+adm'), 'atr:sync:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDDHH24MI'), null, 6);
end $$;
