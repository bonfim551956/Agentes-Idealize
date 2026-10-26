-- =============================================================================
-- Idealize AI — conciliação por documento (homologação com extrato Sicredi real)
-- Migração 20261026140000 — v0.2.1
--
-- Achado da homologação: o Sicredi não traz o E2E do PIX no OFX, mas escreve na
-- descrição o código do comprovante (ex.: "PAGAMENTO PIX-CX769214 ...") e o
-- CPF/CNPJ do favorecido. Duas regras novas, mais fortes que valor+data:
--   R1b id_na_descricao       : documento_banco do comprovante aparece na descrição,
--                               mesmo valor e sentido, dentro da janela
--   R1c documento_contraparte : CPF/CNPJ do favorecido aparece na descrição como
--                               token isolado, mesmo valor e sentido, janela, e o
--                               par é único nos dois sentidos
-- Mesmo CPF/CNPJ + mesma data + valor diferente → pendência de divergência
-- (sem mudar status: a prova é mais fraca que um ID bancário).
-- =============================================================================

alter table fin.conciliacoes drop constraint conciliacoes_regra_check;
alter table fin.conciliacoes add constraint conciliacoes_regra_check
  check (regra in ('id_bancario','id_na_descricao','documento_contraparte','valor_data_unico','manual','extrato'));

create or replace function fin.doc_na_descricao(p_doc text, p_desc text) returns boolean
language sql immutable set search_path = pg_catalog as $$
  select p_doc is not null and length(p_doc) >= 6 and p_desc ~ ('(^|[^0-9A-Za-z])' || p_doc || '([^0-9A-Za-z]|$)')
$$;

create or replace function fin.conciliar(p_conta text, p_ator text) returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare m record; c record; v_conta record; v_jan int; n_id int := 0; n_desc int := 0; n_doc int := 0; n_val int := 0; n_amb int := 0;
  v_qtd int; v_lanc uuid; v_sent text;
begin
  select * into v_conta from fin.contas where id = p_conta;
  v_jan := fin.cfg('fin.janela_conciliacao_dias', '3')::int;

  for m in select * from fin.movimentos where conta_id = p_conta and status = 'pendente' order by data, criado_em for update skip locked loop
    v_sent := case m.sentido when 'credito' then 'entrada' else 'saida' end;

    -- R1 id_bancario: mesmo ID (FITID/E2E)
    v_lanc := null;
    if m.documento_banco is not null then
      select id into v_lanc from fin.lancamentos l
       where l.documento_banco = m.documento_banco and l.valor = m.valor and l.sentido = v_sent
         and l.status in ('pendente','confirmado') and not exists (select 1 from fin.conciliacoes x where x.lancamento_id = l.id)
       limit 1;
      if v_lanc is not null then
        insert into fin.conciliacoes (movimento_id, lancamento_id, valor, regra, confirmado_por) values (m.id, v_lanc, m.valor, 'id_bancario', p_ator);
        update fin.lancamentos set status = 'conciliado', conta_id = coalesce(conta_id, p_conta), data_caixa = m.data where id = v_lanc;
        update fin.movimentos set status = 'conciliado' where id = m.id;
        n_id := n_id + 1; continue;
      end if;
    end if;

    -- R1b id_na_descricao: código do comprovante escrito pelo banco na descrição
    select min(l.id::text)::uuid, count(*) into v_lanc, v_qtd from fin.lancamentos l
     where fin.doc_na_descricao(l.documento_banco, m.descricao) and l.valor = m.valor and l.sentido = v_sent
       and l.status in ('pendente','confirmado') and not exists (select 1 from fin.conciliacoes x where x.lancamento_id = l.id)
       and (l.conta_id = p_conta or (l.conta_id is null and l.unidade_id = v_conta.unidade_id))
       and abs(coalesce(l.data_caixa, l.data_competencia) - m.data) <= v_jan;
    if v_qtd = 1 then
      insert into fin.conciliacoes (movimento_id, lancamento_id, valor, regra, confirmado_por) values (m.id, v_lanc, m.valor, 'id_na_descricao', p_ator);
      update fin.lancamentos set status = 'conciliado', conta_id = coalesce(conta_id, p_conta), data_caixa = m.data where id = v_lanc;
      update fin.movimentos set status = 'conciliado' where id = m.id;
      n_desc := n_desc + 1; continue;
    end if;

    -- R1c documento_contraparte: CPF/CNPJ do favorecido na descrição, par único nos dois sentidos
    select min(l.id::text)::uuid, count(*) into v_lanc, v_qtd from fin.lancamentos l join fin.contrapartes cp on cp.id = l.contraparte_id
     where fin.doc_na_descricao(cp.documento, m.descricao) and l.valor = m.valor and l.sentido = v_sent
       and l.status in ('pendente','confirmado') and not exists (select 1 from fin.conciliacoes x where x.lancamento_id = l.id)
       and (l.conta_id = p_conta or (l.conta_id is null and l.unidade_id = v_conta.unidade_id))
       and not exists (select 1 from fin.lancamentos rb where rb.original_id = l.id and rb.status <> 'cancelado')
       and abs(coalesce(l.data_caixa, l.data_competencia) - m.data) <= v_jan;
    if v_qtd = 1 and (select count(*) from fin.movimentos m2
                        where m2.conta_id = p_conta and m2.status = 'pendente' and m2.valor = m.valor and m2.sentido = m.sentido
                          and fin.doc_na_descricao((select cp.documento from fin.lancamentos l join fin.contrapartes cp on cp.id = l.contraparte_id where l.id = v_lanc), m2.descricao)
                          and abs(m2.data - (select coalesce(data_caixa, data_competencia) from fin.lancamentos where id = v_lanc)) <= v_jan) = 1 then
      insert into fin.conciliacoes (movimento_id, lancamento_id, valor, regra, confirmado_por) values (m.id, v_lanc, m.valor, 'documento_contraparte', p_ator);
      update fin.lancamentos set status = 'conciliado', conta_id = coalesce(conta_id, p_conta), data_caixa = m.data where id = v_lanc;
      update fin.movimentos set status = 'conciliado' where id = m.id;
      n_doc := n_doc + 1; continue;
    end if;

    -- R2 valor_data_unico
    select count(*), min(l.id::text)::uuid into v_qtd, v_lanc from fin.lancamentos l
     where l.valor = m.valor and l.sentido = v_sent
       and l.status in ('pendente','confirmado') and not exists (select 1 from fin.conciliacoes x where x.lancamento_id = l.id)
       and (l.conta_id = p_conta or (l.conta_id is null and l.unidade_id = v_conta.unidade_id))
       and not exists (select 1 from fin.lancamentos rb where rb.original_id = l.id and rb.status <> 'cancelado')
       and abs(coalesce(l.data_caixa, l.data_competencia) - m.data) <= v_jan
       and (l.documento_banco is null or m.documento_banco is null or fin.doc_na_descricao(l.documento_banco, m.descricao));
    if v_qtd = 1 then
      if (select count(*) from fin.movimentos m2 where m2.conta_id = p_conta and m2.status = 'pendente'
            and m2.valor = m.valor and m2.sentido = m.sentido
            and abs(m2.data - (select coalesce(data_caixa, data_competencia) from fin.lancamentos where id = v_lanc)) <= v_jan) = 1 then
        insert into fin.conciliacoes (movimento_id, lancamento_id, valor, regra, confirmado_por) values (m.id, v_lanc, m.valor, 'valor_data_unico', p_ator);
        update fin.lancamentos set status = 'conciliado', conta_id = coalesce(conta_id, p_conta), data_caixa = m.data where id = v_lanc;
        update fin.movimentos set status = 'conciliado' where id = m.id;
        n_val := n_val + 1; continue;
      end if;
    end if;
    if v_qtd >= 1 then
      perform fin.abrir_pendencia('ambiguidade', v_conta.unidade_id, m.id, null,
        jsonb_build_object('candidatos', v_qtd, 'valor', m.valor, 'data', m.data));
      n_amb := n_amb + 1;
    end if;
  end loop;

  -- ID bancário igual e valor diferente → divergência forte (lançamento contestado)
  for c in
    select mv.id mov, l.id lanc, mv.valor vm, l.valor vl from fin.movimentos mv join fin.lancamentos l
      on (l.documento_banco = mv.documento_banco or fin.doc_na_descricao(l.documento_banco, mv.descricao)) and l.valor <> mv.valor
     where mv.conta_id = p_conta and mv.status = 'pendente' and l.status in ('pendente','confirmado')
       and abs(coalesce(l.data_caixa, l.data_competencia) - mv.data) <= v_jan
  loop
    update fin.movimentos set status = 'divergente' where id = c.mov;
    update fin.lancamentos set status = 'contestado', motivo = 'valor do comprovante difere do extrato' where id = c.lanc;
    perform fin.abrir_pendencia('divergencia', v_conta.unidade_id, c.mov, c.lanc,
      jsonb_build_object('valor_extrato', c.vm, 'valor_lancamento', c.vl, 'prova', 'id'));
  end loop;

  -- mesmo CPF/CNPJ, mesma data, valor diferente, sem par exato → divergência a revisar (status não muda)
  for c in
    select mv.id mov, l.id lanc, mv.valor vm, l.valor vl from fin.movimentos mv
      join fin.lancamentos l on l.status in ('pendente','confirmado') and l.valor <> mv.valor
       and l.sentido = case mv.sentido when 'credito' then 'entrada' else 'saida' end
       and coalesce(l.data_caixa, l.data_competencia) = mv.data
      join fin.contrapartes cp on cp.id = l.contraparte_id and fin.doc_na_descricao(cp.documento, mv.descricao)
     where mv.conta_id = p_conta and mv.status = 'pendente'
       and not exists (select 1 from fin.conciliacoes x where x.lancamento_id = l.id)
  loop
    perform fin.abrir_pendencia('divergencia', v_conta.unidade_id, c.mov, c.lanc,
      jsonb_build_object('valor_extrato', c.vm, 'valor_lancamento', c.vl, 'prova', 'documento_contraparte'));
  end loop;

  return jsonb_build_object('por_id', n_id, 'por_id_na_descricao', n_desc, 'por_documento', n_doc,
                            'por_valor_data', n_val, 'ambiguos', n_amb);
end $$;

revoke all on function fin.doc_na_descricao(text, text) from public;
revoke all on function fin.conciliar(text, text) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function fin.doc_na_descricao(text, text) from anon, authenticated';
    execute 'revoke all on function fin.conciliar(text, text) from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function fin.doc_na_descricao(text, text) to service_role';
    execute 'grant execute on function fin.conciliar(text, text) to service_role';
  end if;
end $$;

-- categorias que o Finance AI usa e o plano não tinha
insert into fin.categorias (id, nome, grupo, natureza) values
  ('fornecedores_diversos','Fornecedores diversos','Custo do produto','despesa'),
  ('marketing_geral','Marketing (sem detalhe)','Marketing','despesa'),
  ('equipamentos','Equipamentos','Investimentos','despesa'),
  ('juridico','Jurídico','Administrativo','despesa'),
  ('reunioes','Reuniões e copa','Administrativo','despesa'),
  ('emprestimos','Parcelas de empréstimo','Financeiras','despesa'),
  ('repasse_intercompany','Repasses entre empresas do grupo','Intercompany','despesa'),
  ('recebimento_intercompany','Repasses recebidos do grupo','Intercompany','receita')
on conflict (id) do nothing;
