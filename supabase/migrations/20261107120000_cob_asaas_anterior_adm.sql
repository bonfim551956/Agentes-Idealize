-- =============================================================================
-- Idealize AI — Cobranças: cobrança do Asaas de carnê anterior ao ADM  · Migração 20261107120000
-- Pedido do Diego (07/11, PODE FAZER). O crediário passou a ser lançado no ADM em 25/08/2026; cobranças do Asaas de
-- carnês vendidos antes disso não têm parcela no ADM e enchiam a lista de "cobrança ativa sem parcela" (261 de 283).
-- Agora a cobrança só vira esse aviso quando o parcelamento dela (ou ela mesma, se avulsa) começa a vencer depois de
-- cob.adm_inicio + 30 dias. As antigas continuam contadas à parte (painel_cob_regras) e a data se altera pela tela Cobranças.
-- =============================================================================
insert into core.config (chave, valor) values ('cob.adm_inicio', '2026-08-25') on conflict (chave) do nothing;

-- cobrança do Asaas que pertence a carnê vendido antes do ADM (1º vencimento do parcelamento até adm_inicio + 30 dias)
create or replace function cob._anterior_adm(p_parcelamento text, p_vencimento date) returns boolean
language sql stable set search_path = cob, core, pg_catalog as $$
  select coalesce((select min(a.vencimento) from cob.asaas a where p_parcelamento is not null and a.parcelamento = p_parcelamento), p_vencimento)
         < coalesce(nullif(core.cfg('cob.adm_inicio', ''), '')::date, date '2026-08-25') + 30
$$;

create or replace function cob.recalcular() returns jsonb
language plpgsql security definer set search_path = cob, core, pg_catalog as $$
declare d date := cob._hoje(); v_car int := cob._cfg_num('cob.carencia_dias', 1)::int;
  v_tv numeric := cob._cfg_num('cob.tolerancia_valor', 0.10); v_fv int := cob._cfg_num('cob.folga_vencimento_dias', 5)::int;
  v_ant int := cob._cfg_num('cob.boleto_antecedencia_dias', 15)::int;
  p record; v_a text; n_v int; n_ab int; n_res int;
begin
  -- vínculo parcela ↔ cobrança: mesma loja, mesmo valor, vencimento próximo; um para um, o vencimento mais perto primeiro
  delete from cob.vinculos;
  for p in select pa.* from cob.parcelas pa where pa.financeira = 'asaas' and pa.status_adm in ('aberto','pago')
           order by pa.vencimento, pa.id loop
    select a.id into v_a from cob.asaas a
     where a.unidade_id = p.unidade_id and abs(a.valor - p.valor) <= v_tv and abs(a.vencimento - p.vencimento) <= v_fv
       and not exists (select 1 from cob.vinculos v where v.asaas_id = a.id)
     order by abs(a.vencimento - p.vencimento), (a.status in ('RECEIVED','CONFIRMED','RECEIVED_IN_CASH')) = (p.status_adm = 'pago') desc, a.id
     limit 1;
    if found then insert into cob.vinculos values (p.id, v_a); end if;
  end loop;
  select count(*) into n_v from cob.vinculos;

  drop table if exists _devidos;
  create temp table _devidos (tipo text, referencia text, unidade_id text, detalhe jsonb) on commit drop;

  -- carnê com parcela vencida em aberto (e que o Asaas não mostra como paga)
  insert into _devidos
  select 'parcela_vencida', 'carne:' || c.id, c.unidade_id,
         jsonb_build_object('os', c.os, 'os_provisoria', c.os_provisoria, 'financeira', c.financeira, 'parcelas', count(*),
                            'valor', sum(pa.valor), 'dias', max(d - pa.vencimento), 'vencimento_mais_antigo', min(pa.vencimento))
  from cob.parcelas pa join cob.carnes c on c.id = pa.carne_id
  where pa.status_adm = 'aberto' and pa.vencimento < d - v_car and coalesce(c.status_adm, '') <> 'cancelado'
    and not exists (select 1 from cob.vinculos v join cob.asaas a on a.id = v.asaas_id
                    where v.parcela_id = pa.id and a.status in ('RECEIVED','CONFIRMED','RECEIVED_IN_CASH'))
  group by c.id, c.unidade_id, c.os, c.os_provisoria, c.financeira;

  -- pago no Asaas e ainda em aberto no ADM
  insert into _devidos
  select 'pago_sem_baixa', 'parcela:' || pa.id, pa.unidade_id,
         jsonb_build_object('os', c.os, 'numero', pa.numero, 'total', pa.total, 'valor', pa.valor, 'vencimento', pa.vencimento,
                            'pago_em', a.pagamento)
  from cob.parcelas pa join cob.carnes c on c.id = pa.carne_id join cob.vinculos v on v.parcela_id = pa.id join cob.asaas a on a.id = v.asaas_id
  where pa.status_adm = 'aberto' and a.status in ('RECEIVED','CONFIRMED','RECEIVED_IN_CASH');

  -- baixado no ADM, mas a cobrança do Asaas continua em aberto
  insert into _devidos
  select 'baixa_sem_pagamento', 'parcela:' || pa.id, pa.unidade_id,
         jsonb_build_object('os', c.os, 'numero', pa.numero, 'total', pa.total, 'valor', pa.valor, 'baixado_em', pa.pagamento,
                            'status_asaas', a.status)
  from cob.parcelas pa join cob.carnes c on c.id = pa.carne_id join cob.vinculos v on v.parcela_id = pa.id join cob.asaas a on a.id = v.asaas_id
  where pa.status_adm = 'pago' and a.status in ('PENDING','OVERDUE');

  -- cobrança ativa no Asaas sem parcela em aberto no ADM (cancelada, renegociada ou nunca lançada): cliente pode pagar à toa
  insert into _devidos
  select 'cobranca_sem_parcela', 'asaas:' || a.id, a.unidade_id,
         jsonb_build_object('valor', a.valor, 'vencimento', a.vencimento, 'status_asaas', a.status)
  from cob.asaas a
  where a.status in ('PENDING','OVERDUE') and not exists (select 1 from cob.vinculos v where v.asaas_id = a.id)
    and exists (select 1 from cob.cobertura_asaas co where co.unidade_id = a.unidade_id)
    and not cob._anterior_adm(a.parcelamento, a.vencimento);   -- carnê de antes do ADM: fica só na contagem à parte

  -- parcela do Asaas vencendo logo e sem cobrança emitida
  insert into _devidos
  select 'parcela_sem_cobranca', 'parcela:' || pa.id, pa.unidade_id,
         jsonb_build_object('os', c.os, 'numero', pa.numero, 'total', pa.total, 'valor', pa.valor, 'vencimento', pa.vencimento)
  from cob.parcelas pa join cob.carnes c on c.id = pa.carne_id
  where pa.financeira = 'asaas' and pa.status_adm = 'aberto' and pa.vencimento <= d + v_ant
    and coalesce(c.status_adm, '') <> 'cancelado'
    and not exists (select 1 from cob.vinculos v where v.parcela_id = pa.id)
    and exists (select 1 from cob.cobertura_asaas co where co.unidade_id = pa.unidade_id);

  -- entrada combinada e não paga
  insert into _devidos
  select 'entrada_pendente', 'carne:' || c.id, c.unidade_id,
         jsonb_build_object('os', c.os, 'financeira', c.financeira, 'valor', c.valor_entrada, 'combinada_para', c.dt_entrada)
  from cob.carnes c
  where not c.entrada_paga and coalesce(c.valor_entrada, 0) > 0 and c.dt_entrada < d - v_car and coalesce(c.status_adm, '') <> 'cancelado';

  insert into cob.alertas (tipo, referencia, unidade_id, detalhe)
  select tipo, referencia, unidade_id, detalhe from _devidos
  on conflict (tipo, referencia) where status = 'aberto'
  do update set detalhe = excluded.detalhe, unidade_id = excluded.unidade_id;
  get diagnostics n_ab = row_count;

  update cob.alertas a set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente_cobrancas: situação deixou de existir'
   where a.status = 'aberto' and not exists (select 1 from _devidos x where x.tipo = a.tipo and x.referencia = a.referencia);
  get diagnostics n_res = row_count;
  return jsonb_build_object('vinculos', n_v, 'ativos', n_ab, 'resolvidos', n_res);
end $$;


-- regras e contagem das cobranças antigas, para a tela Cobranças
create or replace function public.painel_cob_regras() returns jsonb
language plpgsql security definer set search_path = cob, core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('cob_regras');
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  return jsonb_build_object(
    'adm_inicio', coalesce(nullif(core.cfg('cob.adm_inicio', ''), '')::date, date '2026-08-25'),
    'pode_editar', painel._pode(v_eu, 'administrar'),
    'anteriores', (select jsonb_build_object('cobrancas', count(*), 'vencidas', count(*) filter (where a.status = 'OVERDUE'),
                     'valor_vencido', coalesce(sum(a.valor) filter (where a.status = 'OVERDUE'), 0), 'valor_a_vencer', coalesce(sum(a.valor) filter (where a.status = 'PENDING'), 0))
                   from cob.asaas a
                   where a.status in ('PENDING','OVERDUE') and a.unidade_id = any(painel._unidades(v_eu))
                     and not exists (select 1 from cob.vinculos v where v.asaas_id = a.id) and cob._anterior_adm(a.parcelamento, a.vencimento)));
end $$;

create or replace function public.painel_cob_regras_salvar(p_adm_inicio date, p_motivo text default null) returns jsonb
language plpgsql security definer set search_path = cob, core, pg_catalog as $$
declare v_eu uuid; v_antes text := core.cfg('cob.adm_inicio', '2026-08-25');
begin
  v_eu := painel._entrar('cob_regras_salvar');
  perform painel._exigir(v_eu, 'administrar');
  if p_adm_inicio is null or p_adm_inicio < date '2020-01-01' or p_adm_inicio > cob._hoje() then raise exception 'data de início inválida' using errcode = '22023'; end if;
  insert into core.config (chave, valor) values ('cob.adm_inicio', p_adm_inicio::text)
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  perform core.auditar(v_eu, null, 'cob_regras_alteradas', 'core.config', 'cob.adm_inicio', jsonb_build_object('adm_inicio', v_antes),
    jsonb_build_object('adm_inicio', p_adm_inicio), nullif(btrim(coalesce(p_motivo, '')), ''));
  perform cob.recalcular();
  return public.painel_cob_regras();
end $$;

do $$ declare f text; begin
  foreach f in array array['cob._anterior_adm(text,date)', 'cob.recalcular()', 'public.painel_cob_regras()', 'public.painel_cob_regras_salvar(date,text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', f); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.painel_cob_regras() to authenticated';
    execute 'grant execute on function public.painel_cob_regras_salvar(date,text) to authenticated';
  end if;
end $$;

select cob.recalcular();
