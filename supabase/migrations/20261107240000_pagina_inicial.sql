-- =============================================================================
-- Idealize AI — Página inicial dos agentes  · Migração 20261107240000
-- Pedido do Diego (07/11): levar o quadro "o que cada agente fez" para a página inicial, mostrando o que o agente
-- está fazendo agora, as tarefas dele e o que tem pendente.
-- public.painel_inicio(): por agente — operando agora (tarefa executando/validando), na fila, esperando alguém
-- (aprovação, bloqueada, incerta), última rodada, rodadas e falhas em 24 h, novidades, em aberto e últimas tarefas.
-- Só leitura.
-- =============================================================================
create or replace function public.painel_inicio() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; desde timestamptz := now() - interval '24 hours';
begin
  v_eu := painel._entrar('inicio');
  if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão' using errcode = '42501'; end if;
  return jsonb_build_object('agora', now(), 'agentes', (select coalesce(jsonb_agg(x order by x->>'ordem', x->>'nome'), '[]'::jsonb) from (
    select jsonb_build_object('id', a.id, 'nome', a.nome, 'status', a.status, 'descricao', a.descricao,
      'ordem', case when a.id = 'supervisor' then '9' when (select count(*) from core.tarefas t where t.agente_id = a.id and t.status in ('executando','validando')) > 0 then '0' else '5' end,
      'operando', (select jsonb_agg(jsonb_build_object('tipo', t.tipo, 'operacao', t.operacao, 'status', t.status, 'desde', t.atualizado_em, 'unidade_id', t.unidade_id) order by t.atualizado_em)
                     from core.tarefas t where t.agente_id = a.id and t.status in ('executando','validando')),
      'fila', (select count(*) from core.tarefas t where t.agente_id = a.id and t.status in ('pendente','pronta')),
      'esperando', (select count(*) from core.tarefas t where t.agente_id = a.id and t.status in ('aguardando_aprovacao','bloqueada','incerta')),
      'ultima', greatest((select max(t.atualizado_em) from core.tarefas t where t.agente_id = a.id),
                         (select max(s.em) from intel.sincronizacoes s where s.agente_id = a.id)),
      'ultima_status', (select t.status from core.tarefas t where t.agente_id = a.id order by t.criado_em desc limit 1),
      'rodadas', (select count(*) from core.tarefas t where t.agente_id = a.id and t.criado_em > desde)
                 + case when exists (select 1 from core.tarefas t where t.agente_id = a.id and t.criado_em > desde) then 0
                        else (select count(*) from intel.sincronizacoes s where s.agente_id = a.id and s.em > desde) end,
      'falhas', (select count(*) from core.tarefas t where t.agente_id = a.id and t.status in ('falhou','incerta') and t.atualizado_em > desde),
      'novos', case a.id
         when 'radar' then (select count(*) from intel.noticias where criado_em > desde)
         when 'concorrentes' then (select count(*) from intel.anuncios where primeiro_visto > desde)
         when 'conteudo_ideias' then (select count(*) from cont.ideias where criado_em > desde)
         when 'conteudo_avaliador' then (select count(*) from cont.ideias where avaliada_em > desde)
         when 'conteudo_roteirista' then (select count(*) from cont.roteiros where atualizado_em > desde and status = 'pronto')
         when 'financeiro' then (select count(*) from fin.envios where criado_em > desde)
         when 'supervisor' then (select count(*) from sup.achados where status = 'aberto')
         when 'multicrediario' then (select count(*) from multi.achados where aberto_em > desde)
         when 'auditor_atendimento' then (select count(*) from aud.avaliacoes where avaliado_em > desde)
         else (select count(*) from rel.v_alertas al where al.agente_id = a.id and al.aberto_em > desde) end,
      'abertos', case a.id
         when 'radar' then 0
         when 'concorrentes' then (select count(*) from intel.ideias where status = 'sugerida')
         when 'conteudo_ideias' then 0
         when 'conteudo_avaliador' then (select count(*) from cont.ideias where avaliada_em > desde and status = 'aprovada')
         when 'conteudo_roteirista' then (select count(*) from cont.roteiros where status = 'pronto')
         when 'financeiro' then (select count(*) from fin.pendencias where status = 'aberta')
         when 'supervisor' then (select count(*) from sup.achados where status = 'aberto')
         when 'multicrediario' then (select count(*) from multi.achados where status = 'aberto')
         when 'auditor_atendimento' then (select count(*) from aud.conversas c where not exists (select 1 from aud.avaliacoes v where v.lead_id = c.lead_id))
         else (select count(*) from rel.v_alertas al where al.agente_id = a.id and al.status = 'aberto') end,
      'rotulo_novos', case a.id when 'radar' then 'notícias novas' when 'concorrentes' then 'anúncios novos'
         when 'conteudo_ideias' then 'ideias novas' when 'conteudo_avaliador' then 'ideias avaliadas' when 'conteudo_roteirista' then 'roteiros escritos'
         when 'financeiro' then 'arquivos recebidos' when 'supervisor' then 'achados abertos' when 'auditor_atendimento' then 'conversas avaliadas' else 'avisos novos' end,
      'rotulo_abertos', case a.id when 'concorrentes' then 'ideias para aprovar' when 'financeiro' then 'pendências abertas'
         when 'conteudo_avaliador' then 'aprovadas para roteiro' when 'conteudo_roteirista' then 'roteiros para você aprovar'
         when 'auditor_atendimento' then 'conversas esperando avaliação'
         when 'radar' then '' when 'conteudo_ideias' then '' else 'em aberto' end,
      'tarefas', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'tipo', t.tipo, 'operacao', t.operacao, 'status', t.status,
                    'unidade_id', t.unidade_id, 'em', t.atualizado_em, 'motivo', left(t.motivo, 160)) order by t.criado_em desc), '[]'::jsonb)
                  from (select * from core.tarefas t where t.agente_id = a.id order by t.criado_em desc limit 5) t)) x
    from core.agentes a where a.status <> 'desativado') q));
end $$;

do $$ begin
  revoke all on function public.painel_inicio() from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on function public.painel_inicio() from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'grant execute on function public.painel_inicio() to authenticated'; end if;
end $$;
