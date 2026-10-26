-- =============================================================================
-- Idealize AI — Agente Financeiro: fechamento mensal, endurecimento e plano de contas
-- Migração 20261026120100 — v0.2.0 (continuação de 20261026120000)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 11. Fechamento mensal: preparar (agente) → validar (independente) → aprovar (diretoria)
-- ---------------------------------------------------------------------------
create or replace function fin._checar_pendencias_periodo(p_unidade text, p_ini date, p_fim date) returns void
language plpgsql security definer set search_path = fin, pg_catalog as $$
declare r record;
begin
  -- comprovante registrado sem confirmação bancária
  for r in select l.* from fin.lancamentos l left join fin.contas c on c.id = l.conta_id
            where l.unidade_id = p_unidade and l.status = 'pendente' and l.origem <> 'extrato'
              and coalesce(l.data_caixa, l.data_competencia) between p_ini and p_fim
              and coalesce(c.tipo, '') <> 'cartao_credito' loop
    if r.natureza in ('transferencia_interna','transferencia_unidades') then
      -- perna de transferência sem confirmação no extrato da conta: dinheiro pode não ter chegado
      perform fin.abrir_pendencia('transferencia_sem_par', p_unidade, null, r.id,
        jsonb_build_object('numero', r.numero, 'valor', r.valor, 'conta', r.conta_id, 'motivo','perna sem confirmação no extrato'));
    else
      perform fin.abrir_pendencia('comprovante_sem_pagamento', p_unidade, null, r.id,
        jsonb_build_object('numero', r.numero, 'valor', r.valor));
    end if;
  end loop;
  -- despesa paga (conciliada) sem nenhum documento: não bloqueia, mas aparece
  for r in select l.* from fin.lancamentos l
            where l.unidade_id = p_unidade and l.natureza = 'despesa' and l.status = 'conciliado'
              and l.data_caixa between p_ini and p_fim
              and not exists (select 1 from fin.lancamento_documentos d where d.lancamento_id = l.id) loop
    perform fin.abrir_pendencia('sem_comprovante', p_unidade, null, r.id, jsonb_build_object('numero', r.numero), false);
  end loop;
  -- movimento do extrato ainda não conciliado
  for r in select m.* from fin.movimentos m join fin.contas c on c.id = m.conta_id
            where c.unidade_id = p_unidade and m.status in ('pendente','divergente') and m.data between p_ini and p_fim loop
    if not exists (select 1 from fin.pendencias where movimento_id = r.id and status = 'aberta') then
      perform fin.abrir_pendencia('divergencia', p_unidade, r.id, null, jsonb_build_object('motivo','movimento não conciliado'));
    end if;
  end loop;
end $$;

create or replace function fin.preparar_fechamento(p_unidade text, p_competencia date, p_preparado_por text) returns uuid
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare v_ini date := date_trunc('month', p_competencia)::date; v_fim date; v_pac jsonb; v_pend int; v_id uuid; v_ver int;
begin
  v_fim := (v_ini + interval '1 month - 1 day')::date;
  if exists (select 1 from fin.fechamentos where coalesce(unidade_id,'*') = coalesce(p_unidade,'*') and competencia = v_ini and status = 'aprovado') then
    raise exception 'competência já aprovada; reabertura exige decisão da diretoria';
  end if;
  perform fin._checar_pendencias_periodo(p_unidade, v_ini, v_fim);
  select count(*) into v_pend from fin.pendencias p
   where p.status = 'aberta' and p.material and p.unidade_id = p_unidade
     and coalesce((select coalesce(l.data_caixa, l.data_competencia) from fin.lancamentos l where l.id = p.lancamento_id),
                  (select m.data from fin.movimentos m where m.id = p.movimento_id), v_fim) between v_ini and v_fim;

  v_pac := jsonb_build_object(
    'unidade', p_unidade, 'competencia', v_ini,
    'dre', coalesce((select jsonb_agg(jsonb_build_object('natureza', natureza, 'categoria', categoria_id, 'valor', valor) order by natureza, categoria_id)
                       from fin.v_dre where unidade_id = p_unidade and competencia = v_ini), '[]'),
    'receitas', coalesce((select sum(valor) from fin.v_dre where unidade_id = p_unidade and competencia = v_ini and natureza = 'receita'), 0),
    'despesas', coalesce((select sum(valor) from fin.v_dre where unidade_id = p_unidade and competencia = v_ini and natureza = 'despesa'), 0),
    'caixa_entradas', coalesce((select sum(entradas) from fin.v_caixa_unidade where unidade_id = p_unidade and data between v_ini and v_fim), 0),
    'caixa_saidas', coalesce((select sum(saidas) from fin.v_caixa_unidade where unidade_id = p_unidade and data between v_ini and v_fim), 0),
    'previsto', coalesce((select jsonb_agg(to_jsonb(p)) from fin.v_previsto p where unidade_id = p_unidade and data between v_ini and v_fim), '[]'),
    'pendencias_materiais', v_pend,
    'pendencias', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'material', material, 'detalhe', detalhe))
                              from fin.pendencias where status = 'aberta' and unidade_id = p_unidade), '[]'));

  select coalesce(max(versao),0) + 1 into v_ver from fin.fechamentos where coalesce(unidade_id,'*') = coalesce(p_unidade,'*') and competencia = v_ini;
  update fin.fechamentos set status = 'reaberto' where coalesce(unidade_id,'*') = coalesce(p_unidade,'*') and competencia = v_ini
     and status in ('preparado','bloqueado','validado');
  insert into fin.fechamentos (unidade_id, competencia, status, pacote, pacote_hash, pendencias_materiais, preparado_por, versao)
  values (p_unidade, v_ini, case when v_pend > 0 then 'bloqueado' else 'preparado' end, v_pac,
          encode(sha256(convert_to(v_pac::text,'UTF8')),'hex'), v_pend, p_preparado_por, v_ver)
  returning id into v_id;
  perform core.auditar(null, p_preparado_por, 'fechamento_preparado', 'fin.fechamento', v_id::text, null,
    jsonb_build_object('unidade', p_unidade, 'competencia', v_ini, 'pendencias_materiais', v_pend));
  return v_id;
end $$;

-- Validador independente: recalcula pelo EXTRATO, sem usar o pacote do agente.
--  (a) saldo inicial do banco + créditos − débitos = saldo final do banco (por importação)
--  (b) para cada conta: Σ movimentos conciliados = Σ valores conciliados nos lançamentos
--  (c) caixa do pacote = caixa recalculado direto dos movimentos (exclui só transferências internas)
create or replace function fin.validar_fechamento(p_fechamento uuid, p_validador text) returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare f record; v_ini date; v_fim date; v_erros jsonb := '[]'; v_avisos jsonb := '[]'; r record; v_ent numeric; v_sai numeric;
begin
  select * into f from fin.fechamentos where id = p_fechamento for update;
  if f.status not in ('preparado','bloqueado') then raise exception 'fechamento não está para validar (status=%)', f.status; end if;
  if p_validador = f.preparado_por then raise exception 'quem preparou não valida' using errcode = '42501'; end if;
  v_ini := f.competencia; v_fim := (v_ini + interval '1 month - 1 day')::date;

  for r in select i.* from fin.importacoes i join fin.contas c on c.id = i.conta_id
            where c.unidade_id = f.unidade_id and i.periodo_inicio <= v_fim and i.periodo_fim >= v_ini
              and i.saldo_inicial is not null and i.saldo_final is not null loop
    if r.saldo_inicial + coalesce((select sum(case sentido when 'credito' then valor else -valor end)
                                     from fin.movimentos where importacao_id = r.id), 0) <> r.saldo_final then
      v_erros := v_erros || jsonb_build_object('regra','saldo_extrato','importacao', r.id);
    end if;
  end loop;

  for r in select c.id conta,
                  coalesce((select sum(m.valor) from fin.movimentos m where m.conta_id = c.id and m.status = 'conciliado'
                              and m.data between v_ini and v_fim), 0) mov,
                  coalesce((select sum(x.valor) from fin.conciliacoes x join fin.movimentos m on m.id = x.movimento_id
                              where m.conta_id = c.id and m.data between v_ini and v_fim), 0) conc
             from fin.contas c where c.unidade_id = f.unidade_id loop
    if r.mov <> r.conc then
      v_erros := v_erros || jsonb_build_object('regra','conciliacao_parcial','conta', r.conta, 'movimentos', r.mov, 'conciliado', r.conc);
    end if;
  end loop;

  select coalesce(sum(case when m.sentido='credito' then m.valor end),0), coalesce(sum(case when m.sentido='debito' then m.valor end),0)
    into v_ent, v_sai
    from fin.movimentos m join fin.contas c on c.id = m.conta_id
   where c.unidade_id = f.unidade_id and c.tipo <> 'cartao_credito' and m.data between v_ini and v_fim and m.status = 'conciliado'
     and not exists (select 1 from fin.conciliacoes x join fin.lancamentos l on l.id = x.lancamento_id
                      where x.movimento_id = m.id and l.natureza = 'transferencia_interna');
  -- caixa físico não tem extrato: soma à parte e registra que não há verificação independente
  if exists (select 1 from fin.contas where unidade_id = f.unidade_id and tipo = 'caixa') then
    select v_ent + coalesce(sum(case when l.sentido='entrada' then l.valor end),0), v_sai + coalesce(sum(case when l.sentido='saida' then l.valor end),0)
      into v_ent, v_sai from fin.lancamentos l join fin.contas c on c.id = l.conta_id
     where c.unidade_id = f.unidade_id and c.tipo = 'caixa' and l.status = 'confirmado' and l.data_caixa between v_ini and v_fim
       and l.natureza <> 'transferencia_interna';
    v_avisos := v_avisos || jsonb_build_object('aviso','caixa físico sem extrato: conferido só pelos lançamentos');
  end if;
  if v_ent <> (f.pacote->>'caixa_entradas')::numeric or v_sai <> (f.pacote->>'caixa_saidas')::numeric then
    v_erros := v_erros || jsonb_build_object('regra','caixa_recalculado','extrato_entradas', v_ent, 'extrato_saidas', v_sai,
      'pacote_entradas', f.pacote->'caixa_entradas', 'pacote_saidas', f.pacote->'caixa_saidas');
  end if;
  if f.pacote_hash <> encode(sha256(convert_to(f.pacote::text,'UTF8')),'hex') then
    v_erros := v_erros || jsonb_build_object('regra','pacote_alterado');
  end if;

  update fin.fechamentos set validacao = jsonb_build_object('erros', v_erros, 'avisos', v_avisos, 'em', now(), 'validador', p_validador),
    validado_por = p_validador,
    status = case when jsonb_array_length(v_erros) = 0 and f.pendencias_materiais = 0 then 'validado' else 'bloqueado' end
   where id = p_fechamento;
  perform core.auditar(null, p_validador, 'fechamento_validado', 'fin.fechamento', p_fechamento::text, null,
    jsonb_build_object('erros', v_erros));
  return jsonb_build_object('ok', jsonb_array_length(v_erros) = 0 and f.pendencias_materiais = 0, 'erros', v_erros,
                            'pendencias_materiais', f.pendencias_materiais);
end $$;

-- Aprovação: pessoa da diretoria, diferente de quem preparou, presa ao hash do pacote que viu
create or replace function fin.decidir_fechamento(p_fechamento uuid, p_aprovador uuid, p_aprovar boolean,
  p_hash_visto text, p_motivo text default null) returns text
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare f record;
begin
  select * into f from fin.fechamentos where id = p_fechamento for update;
  if not exists (select 1 from core.principais pr join core.principal_papeis pp on pp.principal_id = pr.id
                  where pr.id = p_aprovador and pr.tipo = 'usuario' and pr.ativo and pp.papel_id = 'diretoria'
                    and (pp.unidade_id is null or pp.unidade_id = f.unidade_id) and (pp.valido_ate is null or pp.valido_ate > now())) then
    raise exception 'somente a diretoria decide o fechamento' using errcode = '42501';
  end if;
  if p_hash_visto is distinct from f.pacote_hash then
    raise exception 'o pacote mudou desde que foi visto; reabra e revise' using errcode = '42501';
  end if;
  if p_aprovar and f.status <> 'validado' then
    raise exception 'só fechamento validado e sem pendências materiais pode ser aprovado (status=%)', f.status;
  end if;
  if not p_aprovar and coalesce(p_motivo,'') = '' then raise exception 'rejeição exige motivo'; end if;
  update fin.fechamentos set status = case when p_aprovar then 'aprovado' else 'rejeitado' end,
    aprovado_por = p_aprovador, decisao_motivo = p_motivo, decidido_em = now() where id = p_fechamento;
  perform core.auditar(p_aprovador, null, case when p_aprovar then 'fechamento_aprovado' else 'fechamento_rejeitado' end,
    'fin.fechamento', p_fechamento::text, null, jsonb_build_object('hash', p_hash_visto), p_motivo);
  return case when p_aprovar then 'aprovado' else 'rejeitado' end;
end $$;

-- Competência aprovada fica travada: nada novo entra nem muda nela
create or replace function fin._travar_competencia() returns trigger
language plpgsql set search_path = fin, pg_catalog as $$
begin
  if exists (select 1 from fin.fechamentos f where f.status = 'aprovado'
              and f.unidade_id = new.unidade_id and f.competencia = date_trunc('month', new.data_competencia)::date) then
    raise exception 'competência %/% da unidade % está fechada', extract(month from new.data_competencia),
      extract(year from new.data_competencia), new.unidade_id using errcode = '42501';
  end if;
  return new;
end $$;
create trigger lancamentos_competencia_fechada before insert or update on fin.lancamentos
  for each row execute function fin._travar_competencia();

-- ---------------------------------------------------------------------------
-- 12. Endurecimento (mesmo padrão do core)
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'fin' loop
    execute format('alter table fin.%I enable row level security', r.tablename);
    execute format('alter table fin.%I force row level security', r.tablename);
  end loop;
end $$;
revoke all on all tables in schema fin from public;
revoke all on all sequences in schema fin from public;
revoke all on all functions in schema fin from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema fin from anon, authenticated';
    execute 'revoke all on all tables in schema fin from anon, authenticated';
    execute 'revoke all on all functions in schema fin from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema fin to service_role';
    execute 'grant execute on all functions in schema fin to service_role';
    execute 'grant select on all tables in schema fin to service_role';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 13. Dados de base: plano de contas e parâmetros (sem unidades/contas reais —
--     estas entram em migração própria, depois de confirmadas pelo Diego)
-- ---------------------------------------------------------------------------
insert into core.config (chave, valor) values ('fin.janela_conciliacao_dias', '3');

insert into fin.categorias (id, nome, grupo, natureza) values
  ('vendas_cartao','Vendas no cartão','Receitas','receita'),
  ('vendas_pix','Vendas PIX','Receitas','receita'),
  ('vendas_dinheiro','Vendas em dinheiro','Receitas','receita'),
  ('vendas_crediario','Vendas crediário (Asaas/Multicrédito)','Receitas','receita'),
  ('outras_receitas','Outras receitas','Receitas','receita'),
  ('laboratorio','Laboratórios','Custo do produto','despesa'),
  ('armacoes','Armações','Custo do produto','despesa'),
  ('lentes_contato','Lentes de contato','Custo do produto','despesa'),
  ('suprimentos','Suprimentos','Custo do produto','despesa'),
  ('folha','Folha de pagamento','Pessoal','despesa'),
  ('pro_labore','Pró-labore','Pessoal','despesa'),
  ('prestadores','Prestadores de serviço','Pessoal','despesa'),
  ('premios','Prêmios e comissões','Pessoal','despesa'),
  ('beneficios','VT e benefícios','Pessoal','despesa'),
  ('exames','Exames ocupacionais','Pessoal','despesa'),
  ('rescisoes','Rescisões','Pessoal','despesa'),
  ('trafego_pago','Tráfego pago','Marketing','despesa'),
  ('google_ads','Google Ads','Marketing','despesa'),
  ('influenciadoras','Influenciadoras','Marketing','despesa'),
  ('producao_conteudo','Videomaker e artes','Marketing','despesa'),
  ('indique_ganhe','Indique e ganhe','Marketing','despesa'),
  ('grafica','Material gráfico','Marketing','despesa'),
  ('aluguel','Aluguel','Ocupação','despesa'),
  ('agua_luz_telefone','Água, luz e telefone','Ocupação','despesa'),
  ('limpeza','Limpeza','Ocupação','despesa'),
  ('manutencao','Manutenção e reformas','Ocupação','despesa'),
  ('iptu','IPTU','Ocupação','despesa'),
  ('sistemas','Sistemas de gestão','Sistemas e TI','despesa'),
  ('ia','Ferramentas de IA','Sistemas e TI','despesa'),
  ('seguranca','Segurança','Sistemas e TI','despesa'),
  ('tarifas','Tarifas bancárias','Financeiras','despesa'),
  ('juros_iof','Juros e IOF','Financeiras','despesa'),
  ('impostos','Impostos','Impostos e encargos','despesa'),
  ('fgts','FGTS','Impostos e encargos','despesa'),
  ('contabilidade','Contabilidade','Administrativo','despesa'),
  ('correios','Correios','Administrativo','despesa'),
  ('deslocamento','Deslocamento','Administrativo','despesa'),
  ('devolucoes','Devoluções a clientes','Administrativo','despesa'),
  ('outras_despesas','Outras despesas','Administrativo','despesa');
