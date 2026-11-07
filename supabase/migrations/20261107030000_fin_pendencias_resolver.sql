-- =============================================================================
-- Idealize AI — pendências financeiras resolvidas de verdade pelo painel  · Migração 20261107030000
-- Pedido do Diego (07/11): a tela só deixava "marcar como resolvida"; ela precisa deixar RESOLVER.
--  1. Fatura do cartão: as compras do documento eram penduradas na fatura do MÊS DE CADA COMPRA (parcelas antigas
--     e compras de setembro viravam faturas de jan/fev/abr/set). Agora todas vão para a fatura do vencimento do
--     documento. A fatura Sicredi SV de outubro (R$ 4.165,55) é refeita: as 44 compras voltam para ela e a
--     pendência "fatura não bate" fecha sozinha (compras = pagamento).
--  2. painel_pendencia_decidir: a decisão dentro do card já corrige o lançamento:
--       • sem categoria → escolhe a categoria (opção "usar sempre para este fornecedor" cria a regra);
--       • possível duplicidade → "são diferentes" (encerra o grupo) ou "é repetida" (cancela este lançamento).
--  3. painel_pendencias traz o contexto para decidir: conta, fornecedor, os lançamentos parecidos e a conta da fatura.
-- =============================================================================

-- junta compras na fatura do vencimento (cria se preciso); faturas que ficarem vazias e sem pagamento somem
create or replace function fin._juntar_na_fatura(p_lancs uuid[], p_conta text, p_vencimento date) returns uuid
language plpgsql security definer set search_path = fin, pg_catalog as $$
declare v_fat uuid; l record; v_velhas uuid[] := '{}';
begin
  if p_vencimento is null or coalesce(cardinality(p_lancs), 0) = 0 then return null; end if;
  insert into fin.faturas_cartao (conta_id, competencia, vencimento, valor_total)
  values (p_conta, date_trunc('month', p_vencimento)::date, p_vencimento, 0)
  on conflict (conta_id, competencia) do nothing;
  select id into v_fat from fin.faturas_cartao where conta_id = p_conta and competencia = date_trunc('month', p_vencimento)::date for update;
  for l in select * from fin.lancamentos where id = any(p_lancs) and status <> 'cancelado' and fatura_id is distinct from v_fat for update loop
    if l.fatura_id is not null then
      update fin.faturas_cartao set valor_total = valor_total - l.valor where id = l.fatura_id;
      v_velhas := v_velhas || l.fatura_id;
    end if;
    update fin.lancamentos set fatura_id = v_fat where id = l.id;
    update fin.faturas_cartao set valor_total = valor_total + l.valor where id = v_fat;
  end loop;
  delete from fin.faturas_cartao f where f.id = any(v_velhas) and f.pagamento_id is null and f.valor_total = 0
    and not exists (select 1 from fin.lancamentos x where x.fatura_id = f.id);
  return v_fat;
end $$;
revoke all on function fin._juntar_na_fatura(uuid[], text, date) from public;

create or replace function public.painel_envio_confirmar(p_id uuid, p_conta text default null, p_categorias jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; e record; v_nome text; v_conta text; r jsonb; x jsonb; i int; v_l uuid; v_lancs uuid[] := '{}'; v_cat text;
  v_doc uuid; v_tipo_doc text; n_pend int := 0; v_ct record; v_fat uuid;
begin
  select * into e from fin.envios where id = p_id for update;
  if e.id is null then raise exception 'envio inexistente' using errcode = '22023'; end if;
  v_eu := painel._entrar('envio_confirmar', e.unidade_id);
  perform painel._exigir(v_eu, 'confirmar_documento', e.unidade_id);
  if e.status <> 'conferir' then raise exception 'envio não está para conferir (status=%)', e.status using errcode = '22023'; end if;
  if e.tipo = 'outro' then raise exception 'não é documento financeiro: descarte o envio' using errcode = '22023'; end if;
  if e.checagens->>'ok' = 'false' then
    raise exception 'as contas não fecham (%): corrija o arquivo e envie de novo, ou descarte', e.checagens->'avisos' using errcode = '22023';
  end if;
  select nome into v_nome from core.principais where id = v_eu;
  v_conta := coalesce(p_conta, e.conta_id);
  select * into v_ct from fin.contas where false;   -- deixa o registro definido (vazio) quando não há conta
  if v_conta is not null then
    select * into v_ct from fin.contas where id = v_conta and unidade_id = e.unidade_id and ativo;
    if v_ct.id is null then raise exception 'conta não é desta loja' using errcode = '22023'; end if;
  end if;

  if e.tipo = 'extrato' then
    if v_conta is null or v_ct.tipo = 'cartao_credito' then raise exception 'escolha a conta bancária do extrato' using errcode = '22023'; end if;
    r := fin.importar_extrato(v_conta, e.sha256, case when e.formato = 'ofx' then 'ofx' else 'ia' end, e.leitura->'linhas', 'pessoa:' || v_nome,
      (e.leitura->>'saldo_inicial')::numeric, (e.leitura->>'saldo_final')::numeric);

  elsif e.tipo = 'fatura' then
    if v_conta is null or v_ct.tipo <> 'cartao_credito' then raise exception 'escolha o cartão desta fatura' using errcode = '22023'; end if;
    i := 0;
    for x in select * from jsonb_array_elements(e.leitura->'compras') loop
      i := i + 1;
      if (x->>'valor')::numeric <= 0 then continue; end if;   -- pagamento/estorno da fatura: não é compra
      v_cat := coalesce(nullif(p_categorias->>(i::text), ''),
                        case when exists (select 1 from fin.categorias where id = x->>'categoria' and ativo) then x->>'categoria' end,
                        fin.categoria_por_regra(null, x->>'descricao', 'debito', (x->>'data')::date));
      if v_cat is not null and not exists (select 1 from fin.categorias where id = v_cat and ativo) then
        raise exception 'categoria % inexistente', v_cat using errcode = '22023';
      end if;
      v_l := fin.registrar_lancamento('despesa', 'saida', round((x->>'valor')::numeric, 2), e.unidade_id, (x->>'data')::date,
        'pessoa:' || v_nome, 'painel', v_conta, v_cat, left(x->>'descricao', 200), null,
        left(concat_ws(' ', x->>'descricao', nullif(x->>'parcela', '')), 300), null, 'pendente', null, null);
      v_lancs := v_lancs || v_l;
      if v_cat is null then
        perform fin.abrir_pendencia('sem_classificacao', e.unidade_id, null, v_l, jsonb_build_object('envio', e.id, 'descricao', left(x->>'descricao', 200)), false);
        n_pend := n_pend + 1;
      end if;
    end loop;
    -- todas as compras do documento vão para a fatura do vencimento dele (achado 07/11: separava pelo mês de cada compra)
    v_fat := fin._juntar_na_fatura(v_lancs, v_conta, coalesce(nullif(e.leitura->>'vencimento', '')::date, (select max((y->>'data')::date) from jsonb_array_elements(e.leitura->'compras') y) + 10));
    r := jsonb_build_object('compras', cardinality(v_lancs), 'sem_categoria', n_pend, 'fatura', v_fat);

  elsif e.tipo = 'stone' then
    r := cx.registrar_stone(e.unidade_id, e.leitura->'transacoes', e.sha256);

  else  -- comprovante / boleto / nota
    v_tipo_doc := case e.tipo when 'comprovante' then 'comprovante_pagamento' when 'boleto' then 'boleto' else 'documento_fiscal' end;
    insert into fin.documentos (tipo, sha256, storage_path, mime, origem, unidade_id, enviado_por, extraido, status)
    values (v_tipo_doc, e.sha256, 'fin-envios/' || e.caminho, e.mime, 'painel', e.unidade_id, e.enviado_por, e.leitura,
      case when e.tipo = 'nota' then 'revisao' else 'extraido' end)
    returning id into v_doc;
    if e.tipo in ('comprovante','boleto') then
      for x in select * from jsonb_array_elements(e.leitura->'itens') loop
        v_cat := fin.categoria_por_regra(fin.so_digitos(x->>'favorecido_doc'), x->>'favorecido', 'debito',
                   coalesce(nullif(x->>'data', '')::date, nullif(x->>'vencimento', '')::date));
        v_l := fin.registrar_lancamento('despesa', 'saida', round((x->>'valor')::numeric, 2), e.unidade_id,
          coalesce(nullif(x->>'data', '')::date, nullif(x->>'vencimento', '')::date), 'pessoa:' || v_nome, 'painel', null, v_cat,
          left(x->>'favorecido', 200), case when length(fin.so_digitos(x->>'favorecido_doc')) in (11, 14) then fin.so_digitos(x->>'favorecido_doc') end,
          left(coalesce(x->>'descricao', case when e.tipo = 'boleto' then 'Boleto' end), 300),
          coalesce(nullif(x->>'data', '')::date, nullif(x->>'vencimento', '')::date),
          case when e.tipo = 'boleto' then 'previsto' else 'pendente' end, left(nullif(x->>'id_transacao', ''), 100), v_doc);
        v_lancs := v_lancs || v_l;
        if v_cat is null then
          perform fin.abrir_pendencia('sem_classificacao', e.unidade_id, null, v_l, jsonb_build_object('envio', e.id, 'favorecido', left(x->>'favorecido', 200)), false);
          n_pend := n_pend + 1;
        end if;
      end loop;
    end if;
    r := jsonb_build_object('documento', v_doc, 'lancamentos', cardinality(v_lancs), 'sem_categoria', n_pend);
  end if;

  update fin.envios set status = 'lancado', conta_id = coalesce(v_conta, conta_id), resultado = r, decidido_por = v_eu, decidido_em = now(),
    motivo = null, atualizado_em = now() where id = e.id;
  perform core.auditar(v_eu, null, 'envio_confirmado', 'fin.envio', e.id::text, jsonb_build_object('status', 'conferir'),
    jsonb_build_object('status', 'lancado', 'tipo', e.tipo, 'resultado', r));
  return jsonb_build_object('status', 'lancado', 'resultado', r);
end $$;

-- conserto das faturas já lançadas: as compras de cada envio de fatura vão para a fatura do vencimento dele
do $$ declare e record; begin
  for e in select * from fin.envios where tipo = 'fatura' and status = 'lancado' and conta_id is not null loop
    perform fin._juntar_na_fatura(
      array(select id from fin.lancamentos where conta_id = e.conta_id and origem = 'painel' and natureza = 'despesa'
              and criado_em = e.decidido_em and status <> 'cancelado'),
      e.conta_id,
      coalesce(nullif(e.leitura->>'vencimento', '')::date, (select max((y->>'data')::date) from jsonb_array_elements(e.leitura->'compras') y) + 10));
  end loop;
end $$;

-- lançamentos "parecidos" (mesma conta, valor, data e fornecedor): base da decisão de duplicidade
create or replace function fin._parecidos(p_lancamento uuid) returns setof fin.lancamentos
language sql stable security definer set search_path = fin, pg_catalog as $$
  select x.* from fin.lancamentos l join fin.lancamentos x
    on x.conta_id is not distinct from l.conta_id and x.valor = l.valor and x.data_competencia = l.data_competencia
   and lower(coalesce(x.contraparte_nome, x.descricao, '')) = lower(coalesce(l.contraparte_nome, l.descricao, ''))
   and x.status <> 'cancelado' and x.unidade_id is not distinct from l.unidade_id
  where l.id = p_lancamento
  order by x.numero
$$;
revoke all on function fin._parecidos(uuid) from public;

create or replace function public.painel_pendencias(p_unidade text default null, p_tipo text default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; g boolean; un text[];
begin
  v_eu := painel._entrar('pendencias', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  g := painel._pode(v_eu, 'consultar'); un := painel._unidades(v_eu);
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'tipo', p.tipo, 'unidade_id', p.unidade_id, 'material', p.material, 'referencia', p.referencia,
      'detalhe', painel._mascarar(p.detalhe), 'criado_em', p.criado_em,
      'lancamento', case when l.id is not null then jsonb_build_object('numero', l.numero, 'valor', l.valor,
          'natureza', l.natureza, 'sentido', l.sentido, 'categoria_id', l.categoria_id, 'data_competencia', l.data_competencia,
          'descricao', painel._mascarar_texto(coalesce(l.descricao, l.contraparte_nome)),
          'fornecedor', painel._mascarar_texto(l.contraparte_nome),
          'conta', (select apelido from fin.contas where id = l.conta_id),
          'categoria', (select nome from fin.categorias where id = l.categoria_id)) end,
      'movimento', case when m.id is not null then jsonb_build_object('data', m.data, 'valor', m.valor, 'sentido', m.sentido,
          'conta_id', m.conta_id, 'descricao', painel._mascarar_texto(m.descricao)) end,
      'parecidos', case when p.tipo = 'duplicidade_suspeita' and l.id is not null then
          (select coalesce(jsonb_agg(jsonb_build_object('numero', x.numero, 'data', x.data_competencia, 'valor', x.valor,
              'fornecedor', painel._mascarar_texto(coalesce(x.contraparte_nome, x.descricao)),
              'categoria', (select nome from fin.categorias where id = x.categoria_id), 'este', x.id = l.id) order by x.numero), '[]'::jsonb)
             from fin._parecidos(l.id) x) end,
      'fatura', case when p.tipo = 'fatura_divergente' then
          (select jsonb_build_object('vencimento', f.vencimento, 'soma_compras', f.valor_total, 'status', f.status,
              'compras', (select count(*) from fin.lancamentos x where x.fatura_id = f.id and x.status <> 'cancelado'),
              'pago', (select valor from fin.lancamentos where id = f.pagamento_id))
             from fin.faturas_cartao f where f.id = nullif(p.detalhe->>'fatura', '')::uuid) end,
      'pode_tratar', painel._alcanca(v_eu, case when p.material then 'aceitar_pendencia_material' else 'tratar_pendencia' end, p.unidade_id),
      'pode_aceitar', painel._alcanca(v_eu, case when p.material then 'aceitar_pendencia_material' else 'tratar_pendencia' end, p.unidade_id)
    ) order by p.material desc, p.criado_em), '[]'::jsonb)
    from fin.pendencias p
    left join fin.lancamentos l on l.id = p.lancamento_id
    left join fin.movimentos m on m.id = p.movimento_id
    where p.status = 'aberta' and (g or p.unidade_id = any(un))
      and (p_unidade is null or p.unidade_id = p_unidade) and (p_tipo is null or p.tipo = p_tipo));
end $$;

-- categorias para escolher na pendência
create or replace function public.painel_categorias(p_natureza text default 'despesa') returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('categorias');
  if not painel._pode_algum(v_eu, 'tratar_pendencia') then raise exception 'sem permissão para tratar pendências' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'grupo', grupo) order by grupo, nome), '[]'::jsonb)
            from fin.categorias where ativo and natureza = coalesce(p_natureza, 'despesa'));
end $$;

-- decisão dentro da pendência: corrige o lançamento e encerra a pendência (com auditoria)
--   p_decisao: 'categoria' (sem_classificacao; p_categoria; p_lembrar cria a regra para o fornecedor)
--              'diferentes' (duplicidade_suspeita: não é cobrança repetida; encerra o grupo)
--              'repetida'   (duplicidade_suspeita: cancela o lançamento desta pendência)
create or replace function public.painel_pendencia_decidir(p_pendencia bigint, p_decisao text, p_categoria text default null,
  p_lembrar boolean default false, p_texto text default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; p record; l record; v_nome text; v_txt text; v_padrao text; v_regra bigint; n int := 0; x record; c record;
begin
  v_eu := painel._entrar('pendencia_decidir', p_pendencia::text);
  select * into p from fin.pendencias where id = p_pendencia for update;
  if p.id is null then raise exception 'pendência inexistente' using errcode = '42501'; end if;
  if p.status <> 'aberta' then raise exception 'pendência não está aberta (status=%)', p.status using errcode = '22023'; end if;
  perform painel._exigir(v_eu, 'tratar_pendencia', p.unidade_id);
  if p.material then perform painel._exigir(v_eu, 'aceitar_pendencia_material', p.unidade_id); end if;
  select nome into v_nome from core.principais where id = v_eu;
  select * into l from fin.lancamentos where id = p.lancamento_id;
  if l.id is null then raise exception 'esta pendência não tem lançamento para corrigir: use resolver ou aceitar' using errcode = '22023'; end if;
  v_txt := nullif(btrim(coalesce(p_texto, '')), '');

  if p_decisao = 'categoria' then
    if p.tipo <> 'sem_classificacao' then raise exception 'escolher categoria é só para lançamento sem categoria' using errcode = '22023'; end if;
    select * into c from fin.categorias where id = p_categoria and ativo;
    if c.id is null then raise exception 'escolha uma categoria' using errcode = '22023'; end if;
    perform fin.reclassificar(l.id, p_categoria, v_eu, coalesce(v_txt, 'categoria escolhida no painel: ' || c.nome));
    n := 1;
    if coalesce(p_lembrar, false) then
      v_padrao := lower(btrim(regexp_replace(coalesce(l.contraparte_nome, l.descricao, ''), '\s+\d{1,2}/\d{1,2}\s*$', '')));
      if length(v_padrao) < 4 then raise exception 'nome do fornecedor curto demais para virar regra' using errcode = '22023'; end if;
      v_regra := fin.definir_regra(v_padrao, case when l.sentido = 'entrada' then 'credito' else 'debito' end, c.natureza, p_categoria,
        50, v_eu, 'definida no painel ao resolver a pendência ' || p.id);
      -- a mesma regra já resolve as outras pendências abertas do mesmo fornecedor
      for x in select q.id, q.lancamento_id from fin.pendencias q join fin.lancamentos y on y.id = q.lancamento_id
               where q.status = 'aberta' and q.tipo = 'sem_classificacao' and q.id <> p.id and y.status <> 'cancelado'
                 and y.sentido = l.sentido and lower(coalesce(y.contraparte_nome, y.descricao, '')) like '%' || v_padrao || '%' loop
        perform fin.reclassificar(x.lancamento_id, p_categoria, v_eu, 'regra do fornecedor (' || c.nome || ')');
        n := n + 1;
      end loop;
    end if;
    perform core.auditar(v_eu, null, 'pendencia_decidida', 'fin.pendencia', p.id::text, jsonb_build_object('tipo', p.tipo),
      jsonb_build_object('decisao', 'categoria', 'categoria', p_categoria, 'regra', v_regra, 'resolvidas', n, 'canal', 'painel'), v_txt);
    return jsonb_build_object('resolvidas', n, 'regra', v_regra);

  elsif p_decisao = 'diferentes' then
    if p.tipo <> 'duplicidade_suspeita' then raise exception 'decisão só vale para possível duplicidade' using errcode = '22023'; end if;
    v_txt := coalesce(v_txt, 'não é cobrança repetida: são cobranças diferentes (decidido no painel)');
    for x in select q.id from fin.pendencias q
             where q.status = 'aberta' and q.tipo = 'duplicidade_suspeita'
               and q.lancamento_id in (select id from fin._parecidos(l.id)) loop
      update fin.pendencias set status = 'aceita', resolvido_por = v_eu, resolucao = v_txt, resolvido_em = now() where id = x.id;
      n := n + 1;
    end loop;
    perform core.auditar(v_eu, null, 'pendencia_decidida', 'fin.pendencia', p.id::text, jsonb_build_object('tipo', p.tipo),
      jsonb_build_object('decisao', 'diferentes', 'encerradas', n, 'canal', 'painel'), v_txt);
    return jsonb_build_object('resolvidas', n);

  elsif p_decisao = 'repetida' then
    if p.tipo <> 'duplicidade_suspeita' then raise exception 'decisão só vale para possível duplicidade' using errcode = '22023'; end if;
    v_txt := coalesce(v_txt, 'cobrança repetida: lançamento nº ' || l.numero || ' cancelado (decidido no painel)');
    perform fin.cancelar_lancamento(l.id, v_txt, 'pessoa:' || v_nome);
    update fin.pendencias set status = 'resolvida', resolvido_por = v_eu, resolucao = v_txt, resolvido_em = now()
     where lancamento_id = l.id and status = 'aberta';
    perform core.auditar(v_eu, null, 'pendencia_decidida', 'fin.pendencia', p.id::text, jsonb_build_object('tipo', p.tipo, 'lancamento', l.numero),
      jsonb_build_object('decisao', 'repetida', 'cancelado', l.numero, 'canal', 'painel'), v_txt);
    return jsonb_build_object('resolvidas', 1, 'cancelado', l.numero);
  end if;
  raise exception 'decisão inválida' using errcode = '22023';
end $$;

do $$ begin
  revoke all on function public.painel_pendencia_decidir(bigint, text, text, boolean, text) from public;
  revoke all on function public.painel_categorias(text) from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.painel_pendencia_decidir(bigint, text, text, boolean, text) from anon';
    execute 'revoke all on function public.painel_categorias(text) from anon';
    execute 'revoke all on function fin._juntar_na_fatura(uuid[], text, date) from anon, authenticated';
    execute 'revoke all on function fin._parecidos(uuid) from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.painel_pendencia_decidir(bigint, text, text, boolean, text) to authenticated';
    execute 'grant execute on function public.painel_categorias(text) to authenticated';
  end if;
end $$;
