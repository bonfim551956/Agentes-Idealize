-- =============================================================================
-- Idealize AI — Tudo para resolver num lugar só + caixa refeito a cada arquivo  · Migração 20261107180000
-- Pedido do Diego (07/11): "quero que ele rode sempre que eu subir algum arquivo e todo arquivo que deveria ser
-- conferido ou alerta de erro deveria ficar em um lugar só".
--  1. Ao lançar um extrato pelo painel, a conferência do caixa roda na hora (a Stone já fazia isso).
--  2. public.painel_central(): arquivos para conferir ou com erro de leitura, avisos do Caixa, Cobranças,
--     Multicrediário, pendências financeiras e incidentes — cada item com a tela onde se resolve.
-- =============================================================================

-- 1. extrato lançado → caixa refeito na hora
do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_envio_confirmar(uuid,text,jsonb)'::regprocedure);
  if v !~ 'cx\.recalcular' then
    v := replace(v, $a$      (e.leitura->>'saldo_inicial')::numeric, (e.leitura->>'saldo_final')::numeric);
$a$, $a$      (e.leitura->>'saldo_inicial')::numeric, (e.leitura->>'saldo_final')::numeric);
    -- o extrato novo pode resolver (ou revelar) Pix do caixa: confere de novo na hora
    if to_regprocedure('cx.recalcular()') is not null then r := r || jsonb_build_object('caixa', cx.recalcular()); end if;
$a$);
    if v !~ 'cx\.recalcular' then raise exception 'confirmação do envio não foi atualizada'; end if;
    execute v;
  end if;
end $$;

-- 2. central
create or replace function public.painel_central(p_unidade text default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[];
  brl constant text := 'FM999G999G990D00';
begin
  v_eu := painel._entrar('central', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; end if;

  drop table if exists _it;
  create temp table _it (area text, tipo text, gravidade int, unidade_id text, dia date, titulo text, texto text, link text, desde timestamptz) on commit drop;

  -- arquivos enviados: para conferir ou com erro de leitura
  insert into _it
  select 'Arquivos', case when e.status = 'erro' then 'Erro na leitura' else 'Para conferir e lançar' end, case when e.status = 'erro' then 1 else 2 end,
         e.unidade_id, (e.criado_em at time zone 'America/Sao_Paulo')::date, e.nome_arquivo,
         case when e.status = 'erro' then coalesce('Não foi possível ler: ' || nullif(e.motivo, ''), 'Não foi possível ler o arquivo. Envie de novo.')
              else concat_ws(' ', coalesce(e.tipo, e.tipo_declarado), '·', (e.checagens->>'itens') || ' linha(s) lida(s).',
                             (select string_agg(a, ' ') from jsonb_array_elements_text(coalesce(e.checagens->'avisos', '[]')) a)) end,
         '/enviar', e.criado_em
    from fin.envios e where e.status in ('conferir', 'erro') and e.unidade_id = any(un);

  -- caixa
  if to_regclass('cx.alertas') is not null then
    insert into _it
    select 'Caixa',
           case a.tipo when 'nao_encontrado' then 'Lançado no caixa e não achado' when 'sem_registro_no_caixa' then 'Entrou e não está no caixa'
             when 'multi_divergente' then 'Multicrediário × caixa' when 'caixa_nao_fechado' then 'Caixa não fechado'
             when 'caixa_inconsistente' then 'Total do caixa não bate' when 'dinheiro_sem_deposito' then 'Dinheiro sem depósito'
             when 'extrato_atrasado' then 'Extrato atrasado' else a.tipo end,
           case when a.tipo in ('nao_encontrado','sem_registro_no_caixa','multi_divergente','caixa_nao_fechado') then 1 else 2 end,
           a.unidade_id, a.dia,
           coalesce(to_char(a.dia, 'DD/MM') || ' (' || coalesce(a.detalhe->>'dia_semana', '') || ')', 'Loja'),
           case a.tipo
             when 'nao_encontrado' then format('%s: %s valor(es) somando R$ %s não achados no %s.', a.detalhe->>'rotulo', a.detalhe->>'quantidade',
               to_char((a.detalhe->>'valor')::numeric, brl), case a.detalhe->>'fonte' when 'banco' then 'extrato do banco' else coalesce(a.detalhe->>'fonte', 'extrato') end)
             when 'sem_registro_no_caixa' then format('%s de R$ %s entrou e não está em nenhum fechamento%s.', a.detalhe->>'rotulo',
               to_char((a.detalhe->>'valor')::numeric, brl), case when (a.detalhe->>'loja_fechada')::boolean then ' (loja fechada nesse dia)' else '' end)
             when 'multi_divergente' then format('Multicrediário R$ %s × caixa R$ %s.', to_char((a.detalhe->>'multi_vendas')::numeric, brl),
               to_char((a.detalhe->>'caixa_vendas')::numeric, brl))
             when 'caixa_inconsistente' then format('Total R$ %s × soma das formas R$ %s.', to_char((a.detalhe->>'caixa')::numeric, brl),
               to_char((a.detalhe->>'soma_formas')::numeric, brl))
             when 'dinheiro_sem_deposito' then format('R$ %s em dinheiro sem depósito registrado.', to_char((a.detalhe->>'dinheiro')::numeric, brl))
             when 'extrato_atrasado' then format('Último dia lido do %s: %s.', a.detalhe->>'fonte', coalesce(to_char((a.detalhe->>'ultimo_dia')::date, 'DD/MM'), 'nenhum'))
             else 'Sem fechamento de caixa registrado neste dia.' end,
           '/caixa', a.aberto_em
      from cx.alertas a where a.status = 'aberto' and (a.unidade_id is null or a.unidade_id = any(un));
  end if;

  -- cobranças (Asaas × ADM)
  if to_regclass('cob.alertas') is not null then
    insert into _it
    select 'Cobranças',
           case a.tipo when 'cobranca_sem_parcela' then 'Cobrança ativa sem parcela' when 'pago_sem_baixa' then 'Pago no Asaas, falta baixar'
             when 'baixa_sem_pagamento' then 'Baixado sem pagamento' when 'parcela_vencida' then 'Parcela em atraso'
             when 'entrada_pendente' then 'Entrada não paga' when 'parcela_sem_cobranca' then 'Parcela sem boleto' else a.tipo end,
           case when a.tipo in ('pago_sem_baixa','baixa_sem_pagamento','cobranca_sem_parcela') then 1 else 3 end,
           a.unidade_id, coalesce((a.detalhe->>'vencimento')::date, (a.detalhe->>'vencimento_mais_antigo')::date),
           coalesce('OS ' || nullif(a.detalhe->>'os', ''), 'Cobrança'),
           coalesce('R$ ' || to_char((a.detalhe->>'valor')::numeric, brl), '') ||
             case when a.detalhe ? 'dias' then ' · ' || (a.detalhe->>'dias') || ' dias de atraso' else '' end,
           '/cobrancas', a.aberto_em
      from cob.alertas a where a.status = 'aberto' and (a.unidade_id is null or a.unidade_id = any(un));
  end if;

  -- Multicrediário × ADM
  if to_regclass('multi.achados') is not null then
    insert into _it
    select 'Multicrediário', a.tipo, case when a.tipo in ('venda_sem_adm','adm_sem_venda','valor_diferente','documento_pendente','parcela_sem_baixa') then 1 else 3 end,
           'sao_vicente', a.dia, coalesce(to_char(a.dia, 'DD/MM'), 'Multicrediário'), a.descricao, '/multicrediario', a.aberto_em
      from multi.achados a where a.status = 'aberto' and 'sao_vicente' = any(un);
  end if;

  -- pendências financeiras
  insert into _it
  select 'Financeiro', p.tipo, case when p.material then 1 else 3 end, p.unidade_id, (p.criado_em at time zone 'America/Sao_Paulo')::date,
         'Pendência financeira', coalesce(p.detalhe->>'descricao', p.detalhe->>'favorecido', p.referencia, p.tipo), '/pendencias', p.criado_em
    from fin.pendencias p where p.status = 'aberta' and (p.unidade_id is null or p.unidade_id = any(un));

  -- incidentes da plataforma (só quem vê a rede toda)
  if painel._pode(v_eu, 'consultar') then
    insert into _it
    select 'Plataforma', 'Incidente ' || i.severidade, case when i.severidade in ('critica','alta') then 1 else 3 end, null,
           (i.ultima_em at time zone 'America/Sao_Paulo')::date, i.titulo, coalesce(i.agente_id, ''), '/incidentes', i.primeira_em
      from core.incidentes i where i.status <> 'resolvido';
  end if;

  return jsonb_build_object(
    'total', (select count(*) from _it), 'urgentes', (select count(*) from _it where gravidade = 1),
    'areas', (select coalesce(jsonb_agg(jsonb_build_object('area', area, 'itens', n, 'urgentes', u, 'link', l) order by u desc, n desc), '[]'::jsonb)
                from (select area, count(*) n, count(*) filter (where gravidade = 1) u, min(link) l from _it group by area) q),
    'itens', (select coalesce(jsonb_agg(jsonb_build_object('area', area, 'tipo', tipo, 'gravidade', gravidade, 'unidade_id', unidade_id, 'dia', dia,
                'titulo', titulo, 'texto', texto, 'link', link, 'desde', desde) order by gravidade, dia desc nulls last, area), '[]'::jsonb)
                from (select * from _it order by gravidade, dia desc nulls last limit 400) x));
end $$;

do $$ begin
  revoke all on function public.painel_central(text) from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on function public.painel_central(text) from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'grant execute on function public.painel_central(text) to authenticated'; end if;
end $$;
