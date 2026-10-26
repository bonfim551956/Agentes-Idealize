-- =============================================================================
-- Idealize AI — decisões do Diego na homologação de out/2026 (v0.3.0)
--  1. R M Comércio = custos compartilhados → despesa de SV (categoria própria)
--  2. Débito "cartão de crédito loja" = pagamento de fatura (não é tarifa)
--  3. Boleto pago e devolvido = estorno (líquido zero na DRE)
--  5. CPF de colaborador = folha; pago no fim do mês = vale-transporte
--     (regra com condição: últimos 2 dias corridos OU últimos 2 dias úteis do mês)
-- Todas as correções de dados são humanas, com motivo, e ficam na auditoria.
-- =============================================================================

-- 1) estorno como natureza: entrada que desfaz uma saída (ou o contrário), ligada à original
alter table fin.lancamentos drop constraint lancamentos_natureza_check;
alter table fin.lancamentos add constraint lancamentos_natureza_check check (natureza in (
  'receita','despesa','transferencia_interna','transferencia_unidades','reembolso','pagamento_fatura','ajuste','estorno'));
alter table fin.lancamentos add constraint lancamentos_estorno_original check (natureza <> 'estorno' or original_id is not null);

insert into fin.categorias (id, nome, grupo, natureza) values
  ('custos_compartilhados','Custos compartilhados entre empresas do grupo','Intercompany','despesa')
on conflict (id) do nothing;

-- 2) condição de data nas regras de classificação
alter table fin.regras_classificacao add column ultimos_dias_uteis int check (ultimos_dias_uteis between 1 and 5);
comment on column fin.regras_classificacao.ultimos_dias_uteis is
  'Se preenchido, a regra só vale nos N últimos dias do mês (corridos ou úteis, o que for mais amplo). Ex.: VT = 2.';

create or replace function fin.no_fim_do_mes(d date, n int) returns boolean
language sql immutable set search_path = pg_catalog as $$
  select d > (date_trunc('month', d) + interval '1 month')::date - 1 - n            -- últimos n dias corridos
      or (extract(isodow from d) < 6 and
          (select count(*) from generate_series(d, ((date_trunc('month', d) + interval '1 month')::date - 1), interval '1 day') g
            where extract(isodow from g) < 6) <= n)                                  -- últimos n dias úteis (seg–sex)
$$;

create or replace function fin.lancar_do_extrato(p_conta text, p_ator text) returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare m record; r record; v_conta record; v_l uuid; n_cls int := 0; n_sem int := 0; v_dest record; v_par uuid;
begin
  select * into v_conta from fin.contas where id = p_conta;
  for m in select * from fin.movimentos where conta_id = p_conta and status = 'pendente'
            and not exists (select 1 from fin.pendencias p where p.movimento_id = fin.movimentos.id and p.status = 'aberta')
           order by data for update skip locked loop
    -- há lançamento de mesmo valor/sentido ainda sem conciliação perto da data? não cria outro: pede revisão
    if exists (select 1 from fin.lancamentos l
                where l.valor = m.valor and l.sentido = case m.sentido when 'credito' then 'entrada' else 'saida' end
                  and l.status in ('pendente','confirmado') and l.unidade_id = v_conta.unidade_id
                  and not exists (select 1 from fin.conciliacoes x where x.lancamento_id = l.id)
                  and not exists (select 1 from fin.lancamentos rb where rb.original_id = l.id and rb.status <> 'cancelado')
                  and abs(coalesce(l.data_caixa, l.data_competencia) - m.data) <= 31) then
      perform fin.abrir_pendencia('ambiguidade', v_conta.unidade_id, m.id, null,
        jsonb_build_object('motivo','existe lançamento de mesmo valor fora da janela de conciliação','valor', m.valor,'data', m.data));
      continue;
    end if;
    r := null;
    select * into r from fin.regras_classificacao
     where status = 'ativa' and m.descricao ilike '%' || padrao || '%' and (sentido is null or sentido = m.sentido)
       and (ultimos_dias_uteis is null or fin.no_fim_do_mes(m.data, ultimos_dias_uteis))
     order by prioridade, id limit 1;

    if r.natureza = 'transferencia_unidades' and r.unidade_destino is not null then
      -- só a perna desta conta é conhecida; a outra perna fica como pendência até o extrato da outra unidade
      v_l := gen_random_uuid();
      insert into fin.lancamentos (id, natureza, sentido, valor, unidade_id, conta_id, descricao, data_competencia, data_caixa,
        status, origem, par_id, criado_por)
      values (v_l, 'transferencia_unidades', case m.sentido when 'credito' then 'entrada' else 'saida' end, m.valor,
        v_conta.unidade_id, p_conta, m.descricao, m.data, m.data, 'conciliado', 'extrato', v_l, p_ator);
      perform fin.abrir_pendencia('transferencia_sem_par', v_conta.unidade_id, m.id, v_l,
        jsonb_build_object('unidade_contraparte', r.unidade_destino), false);
    elsif r.id is not null then
      insert into fin.lancamentos (natureza, sentido, valor, unidade_id, conta_id, categoria_id, descricao,
        data_competencia, data_caixa, status, origem, criado_por)
      values (r.natureza, case m.sentido when 'credito' then 'entrada' else 'saida' end, m.valor, v_conta.unidade_id,
        p_conta, r.categoria_id, m.descricao, m.data, m.data, 'conciliado', 'extrato', p_ator) returning id into v_l;
      n_cls := n_cls + 1;
    else
      insert into fin.lancamentos (natureza, sentido, valor, unidade_id, conta_id, descricao,
        data_competencia, data_caixa, status, origem, criado_por)
      values (case m.sentido when 'credito' then 'receita' else 'despesa' end,
        case m.sentido when 'credito' then 'entrada' else 'saida' end, m.valor, v_conta.unidade_id, p_conta,
        m.descricao, m.data, m.data, 'pendente', 'extrato', p_ator) returning id into v_l;
      perform fin.abrir_pendencia('sem_classificacao', v_conta.unidade_id, m.id, v_l, jsonb_build_object('descricao', m.descricao));
      n_sem := n_sem + 1;
    end if;
    insert into fin.conciliacoes (movimento_id, lancamento_id, valor, regra, confirmado_por) values (m.id, v_l, m.valor, 'extrato', p_ator);
    update fin.lancamentos set status = 'conciliado' where id = v_l and status <> 'conciliado';
    update fin.movimentos set status = 'conciliado' where id = m.id;
  end loop;
  return jsonb_build_object('classificados', n_cls, 'sem_classificacao', n_sem);
end $$;

-- 3) DRE: estorno abate a natureza/categoria da original (inclusive rateio, proporcionalmente)
create or replace view fin.v_dre as
with base as (
  select l.id ref, l.unidade_id, date_trunc('month', l.data_competencia)::date competencia, l.natureza, l.categoria_id,
         l.valor, l.valor base_valor
  from fin.lancamentos l
  where l.natureza in ('receita','despesa') and l.status in ('confirmado','conciliado') and not l.estimado
  union all
  select o.id, o.unidade_id, date_trunc('month', e.data_competencia)::date, o.natureza, o.categoria_id,
         -e.valor, o.valor
  from fin.lancamentos e join fin.lancamentos o on o.id = e.original_id
  where e.natureza = 'estorno' and e.status in ('confirmado','conciliado') and o.status in ('confirmado','conciliado')
)
select coalesce(ri.unidade_id, b.unidade_id) unidade_id, b.competencia, b.natureza, b.categoria_id,
       sum(coalesce(round(ri.valor * b.valor / b.base_valor, 2), b.valor)) valor, bool_or(ri.rateio_id is not null) tem_rateio
from base b
left join fin.rateios r on r.lancamento_id = b.ref
left join fin.rateio_itens ri on ri.rateio_id = r.id
group by 1,2,3,4;

-- 4) correções humanas (auditadas pelo trigger de lançamentos + registro explícito do motivo)
create or replace function fin._exigir_pessoa(p_ator uuid) returns void
language plpgsql stable security definer set search_path = core, pg_catalog as $$
begin
  if not exists (select 1 from core.principais where id = p_ator and tipo = 'usuario' and ativo) then
    raise exception 'correção financeira é feita por pessoa autorizada' using errcode = '42501';
  end if;
end $$;

-- muda categoria (e natureza receita/despesa, ou perna única de transferência entre unidades → receita/despesa)
create or replace function fin.reclassificar(p_lancamento uuid, p_categoria text, p_ator uuid, p_motivo text) returns void
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare l record; c record;
begin
  perform fin._exigir_pessoa(p_ator);
  if coalesce(p_motivo,'') = '' then raise exception 'reclassificação exige motivo'; end if;
  select * into l from fin.lancamentos where id = p_lancamento for update;
  select * into c from fin.categorias where id = p_categoria and ativo;
  if c is null then raise exception 'categoria % inexistente', p_categoria; end if;
  if l.status = 'cancelado' then raise exception 'lançamento cancelado não é reclassificado'; end if;
  if (c.natureza = 'receita' and l.sentido <> 'entrada') or (c.natureza = 'despesa' and l.sentido <> 'saida') then
    raise exception 'categoria % (%) incompatível com o sentido %', p_categoria, c.natureza, l.sentido;
  end if;
  if l.natureza in ('receita','despesa') or (l.natureza = 'transferencia_unidades' and l.par_id = l.id) then
    update fin.lancamentos set natureza = c.natureza, categoria_id = p_categoria, par_id = null,
      motivo = 'reclassificado: ' || p_motivo where id = p_lancamento;
  else
    raise exception 'natureza % não é reclassificada por categoria', l.natureza;
  end if;
  update fin.pendencias set status = 'resolvida', resolvido_por = p_ator, resolucao = p_motivo, resolvido_em = now()
   where lancamento_id = p_lancamento and status = 'aberta' and tipo in ('sem_classificacao','transferencia_sem_par');
  perform core.auditar(p_ator, null, 'reclassificacao', 'fin.lancamento', p_lancamento::text,
    jsonb_build_object('natureza', l.natureza, 'categoria', l.categoria_id),
    jsonb_build_object('natureza', c.natureza, 'categoria', p_categoria), p_motivo);
end $$;

-- transforma um lançamento em estorno de outro (sentido oposto, valor até o saldo não estornado)
create or replace function fin.marcar_estorno(p_lancamento uuid, p_original uuid, p_ator uuid, p_motivo text) returns void
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare l record; o record; v_ja numeric;
begin
  perform fin._exigir_pessoa(p_ator);
  if coalesce(p_motivo,'') = '' then raise exception 'estorno exige motivo'; end if;
  select * into l from fin.lancamentos where id = p_lancamento for update;
  select * into o from fin.lancamentos where id = p_original;
  if o is null or o.natureza not in ('receita','despesa') or o.status = 'cancelado' then
    raise exception 'original precisa ser receita/despesa ativa';
  end if;
  if l.sentido = o.sentido then raise exception 'estorno tem sentido oposto ao da original'; end if;
  if l.natureza not in ('receita','despesa') then raise exception 'só receita/despesa vira estorno'; end if;
  select coalesce(sum(valor),0) into v_ja from fin.lancamentos where original_id = p_original and natureza = 'estorno' and status <> 'cancelado';
  if v_ja + l.valor > o.valor then raise exception 'estornos (%) excedem a original (%)', v_ja + l.valor, o.valor; end if;
  update fin.lancamentos set natureza = 'estorno', categoria_id = null, original_id = p_original,
    motivo = 'estorno: ' || p_motivo where id = p_lancamento;
  update fin.pendencias set status = 'resolvida', resolvido_por = p_ator, resolucao = p_motivo, resolvido_em = now()
   where lancamento_id = p_lancamento and status = 'aberta';
  perform core.auditar(p_ator, null, 'estorno', 'fin.lancamento', p_lancamento::text, null,
    jsonb_build_object('original', p_original, 'valor', l.valor), p_motivo);
end $$;

-- transforma uma saída em pagamento de fatura do cartão; as compras da fatura ainda precisam ser lançadas
create or replace function fin.marcar_pagamento_fatura(p_lancamento uuid, p_conta_cartao text, p_competencia date,
  p_vencimento date, p_ator uuid, p_motivo text) returns uuid
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare l record; v_fat uuid; f record;
begin
  perform fin._exigir_pessoa(p_ator);
  if coalesce(p_motivo,'') = '' then raise exception 'exige motivo'; end if;
  if (select tipo from fin.contas where id = p_conta_cartao) is distinct from 'cartao_credito' then
    raise exception 'conta % não é cartão de crédito', p_conta_cartao;
  end if;
  select * into l from fin.lancamentos where id = p_lancamento for update;
  if l.sentido <> 'saida' or l.natureza not in ('despesa','pagamento_fatura') then raise exception 'só saída vira pagamento de fatura'; end if;
  insert into fin.faturas_cartao (conta_id, competencia, vencimento, valor_total)
  values (p_conta_cartao, date_trunc('month', p_competencia)::date, p_vencimento, 0)
  on conflict (conta_id, competencia) do nothing;
  select * into f from fin.faturas_cartao where conta_id = p_conta_cartao and competencia = date_trunc('month', p_competencia)::date for update;
  update fin.lancamentos set natureza = 'pagamento_fatura', categoria_id = null, motivo = 'fatura do cartão: ' || p_motivo
   where id = p_lancamento;
  update fin.faturas_cartao set pagamento_id = p_lancamento,
    status = case when f.valor_total = l.valor then 'paga' else 'divergente' end where id = f.id;
  if f.valor_total <> l.valor then
    perform fin.abrir_pendencia('fatura_divergente', l.unidade_id, null, p_lancamento,
      jsonb_build_object('fatura', f.id, 'soma_compras', f.valor_total, 'pago', l.valor,
                         'acao', 'lançar as compras da fatura no cartão para a DRE'));
  end if;
  perform core.auditar(p_ator, null, 'pagamento_fatura', 'fin.lancamento', p_lancamento::text,
    jsonb_build_object('natureza', l.natureza, 'categoria', l.categoria_id), jsonb_build_object('fatura', f.id), p_motivo);
  return f.id;
end $$;

-- compras lançadas depois no cartão atualizam o status da fatura já paga
create or replace function fin._reconferir_fatura() returns trigger
language plpgsql set search_path = fin, pg_catalog as $$
declare f record; v_pag numeric;
begin
  select * into f from fin.faturas_cartao where id = new.id;
  if f.pagamento_id is not null then
    select valor into v_pag from fin.lancamentos where id = f.pagamento_id;
    if f.valor_total = v_pag and f.status = 'divergente' then
      update fin.faturas_cartao set status = 'paga' where id = f.id;
      update fin.pendencias set status = 'resolvida', resolucao = 'compras da fatura conferem com o pagamento', resolvido_em = now()
       where tipo = 'fatura_divergente' and lancamento_id = f.pagamento_id and status = 'aberta';
    end if;
  end if;
  return null;
end $$;
create trigger faturas_reconferir after update of valor_total on fin.faturas_cartao
  for each row execute function fin._reconferir_fatura();

-- saldo de abertura confirmado por pessoa (o validador passa a conferir a abertura)
create or replace function fin.confirmar_saldo_inicial(p_importacao uuid, p_saldo numeric, p_ator uuid, p_motivo text) returns void
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare i record;
begin
  perform fin._exigir_pessoa(p_ator);
  select * into i from fin.importacoes where id = p_importacao for update;
  update fin.importacoes set saldo_inicial = p_saldo where id = p_importacao;
  perform core.auditar(p_ator, null, 'saldo_inicial_confirmado', 'fin.importacao', p_importacao::text,
    jsonb_build_object('saldo_inicial', i.saldo_inicial), jsonb_build_object('saldo_inicial', p_saldo), p_motivo);
  if i.saldo_final is not null and p_saldo + coalesce((select sum(case sentido when 'credito' then valor else -valor end)
        from fin.movimentos where importacao_id = p_importacao), 0) <> i.saldo_final then
    perform fin.abrir_pendencia('saldo_divergente', (select unidade_id from fin.contas where id = i.conta_id), null, null,
      jsonb_build_object('importacao', p_importacao, 'saldo_inicial', p_saldo, 'saldo_final', i.saldo_final));
  end if;
end $$;

-- versão nova de regra de classificação (a anterior fica inativa, nada é apagado)
create or replace function fin.definir_regra(p_padrao text, p_sentido text, p_natureza text, p_categoria text,
  p_prioridade int, p_ator uuid, p_motivo text, p_unidade_destino text default null, p_ultimos_dias_uteis int default null)
returns bigint
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare v_ver int; v_id bigint;
begin
  perform fin._exigir_pessoa(p_ator);
  select coalesce(max(versao),0) + 1 into v_ver from fin.regras_classificacao
   where padrao = p_padrao and sentido is not distinct from p_sentido and ultimos_dias_uteis is not distinct from p_ultimos_dias_uteis;
  update fin.regras_classificacao set status = 'inativa'
   where padrao = p_padrao and sentido is not distinct from p_sentido and ultimos_dias_uteis is not distinct from p_ultimos_dias_uteis
     and status = 'ativa';
  insert into fin.regras_classificacao (padrao, sentido, natureza, categoria_id, unidade_destino, prioridade, status, origem,
    responsavel, versao, ultimos_dias_uteis)
  values (p_padrao, p_sentido, p_natureza, p_categoria, p_unidade_destino, p_prioridade, 'ativa', 'manual', p_motivo, v_ver,
    p_ultimos_dias_uteis) returning id into v_id;
  perform core.auditar(p_ator, null, 'regra_definida', 'fin.regra', v_id::text, null,
    jsonb_build_object('padrao_hash', md5(p_padrao), 'natureza', p_natureza, 'categoria', p_categoria, 'versao', v_ver,
                       'ultimos_dias_uteis', p_ultimos_dias_uteis), p_motivo);
  return v_id;
end $$;

do $$ declare f text; begin
  foreach f in array array['fin.no_fim_do_mes(date,int)','fin.lancar_do_extrato(text,text)','fin._exigir_pessoa(uuid)',
    'fin.reclassificar(uuid,text,uuid,text)','fin.marcar_estorno(uuid,uuid,uuid,text)',
    'fin.marcar_pagamento_fatura(uuid,text,date,date,uuid,text)','fin.confirmar_saldo_inicial(uuid,numeric,uuid,text)',
    'fin.definir_regra(text,text,text,text,int,uuid,text,text,int)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon, authenticated', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('grant execute on function %s to service_role', f); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'service_role') then execute 'grant select on fin.v_dre to service_role'; end if;
  revoke all on fin.v_dre from public;
end $$;
