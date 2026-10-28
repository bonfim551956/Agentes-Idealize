-- =============================================================================
-- Idealize AI — conferência da fatura sem o pagamento da fatura anterior  · Migração 20261028070000
-- Achado no 1º PDF real (28/10, fatura Sicredi final 3016): as compras somavam exatamente o total impresso
-- (R$ 4.165,55), mas a linha "Pagamento ..." da fatura anterior (-R$ 2.685,93) entrava na soma e a conferência
-- acusava "não fecha", impedindo a confirmação. Agora a linha de PAGAMENTO (valor negativo cuja descrição começa
-- com pagamento/pgto/pagto) fica fora da soma; estornos de compra continuam contando. Na confirmação ela já era
-- ignorada (não é compra). O validador usa a mesma função, então a regra vale igual para os dois.
-- =============================================================================
create or replace function fin._checar_leitura(p_tipo text, l jsonb) returns jsonb
language plpgsql immutable set search_path = pg_catalog as $$
declare n int; s numeric; ruins int; tol numeric := 0.05; esp numeric; ok boolean; av text[] := '{}'; pg numeric;
begin
  if p_tipo = 'extrato' then
    select count(*), coalesce(sum((x->>'valor')::numeric), 0),
           count(*) filter (where x->>'data' !~ '^\d{4}-\d{2}-\d{2}$' or coalesce((x->>'valor')::numeric, 0) = 0)
      into n, s, ruins from jsonb_array_elements(coalesce(l->'linhas', '[]')) x;
    if (l->>'saldo_inicial') is not null and (l->>'saldo_final') is not null then
      esp := (l->>'saldo_final')::numeric - (l->>'saldo_inicial')::numeric;
      ok := abs(s - esp) <= 0.01;
      if not ok then av := av || ('saldo inicial + movimentos não fecha com o saldo final (diferença de ' || round(s - esp, 2) || ')'); end if;
    else ok := null; av := av || 'extrato sem saldo inicial e final: não dá para conferir o fechamento'::text; end if;
  elsif p_tipo = 'fatura' then
    -- pagamento da fatura anterior não é compra desta fatura: fica fora da soma
    select count(*),
           coalesce(sum((x->>'valor')::numeric) filter (where not ((x->>'valor')::numeric < 0
                    and coalesce(x->>'descricao', '') ~* '^\s*(pagamento|pagto|pgto)')), 0),
           coalesce(sum((x->>'valor')::numeric) filter (where (x->>'valor')::numeric < 0
                    and coalesce(x->>'descricao', '') ~* '^\s*(pagamento|pagto|pgto)'), 0),
           count(*) filter (where x->>'data' !~ '^\d{4}-\d{2}-\d{2}$' or (x->>'valor') is null)
      into n, s, pg, ruins from jsonb_array_elements(coalesce(l->'compras', '[]')) x;
    esp := (l->>'total')::numeric;
    if esp is null then ok := null; av := av || 'fatura sem total: não dá para conferir'::text;
    else ok := abs(s - esp) <= tol;
      if not ok then av := av || ('soma das compras (' || round(s, 2) || ') não bate com o total da fatura (' || esp || ')'); end if;
    end if;
    if pg < 0 then av := av || ('pagamento da fatura anterior (' || round(-pg, 2) || ') não entra na soma'); end if;
  elsif p_tipo = 'stone' then
    select count(*), coalesce(sum((x->>'valor')::numeric), 0),
           count(*) filter (where x->>'data' !~ '^\d{4}-\d{2}-\d{2}$' or coalesce((x->>'valor')::numeric, 0) <= 0
                              or coalesce(x->>'forma', '') not in ('credito','debito','pix'))
      into n, s, ruins from jsonb_array_elements(coalesce(l->'transacoes', '[]')) x;
    esp := (l->>'total_bruto')::numeric;
    if esp is null then ok := null; av := av || 'relatório sem total bruto: não dá para conferir'::text;
    else ok := abs(s - esp) <= tol;
      if not ok then av := av || ('soma das vendas (' || round(s, 2) || ') não bate com o total do relatório (' || esp || ')'); end if;
    end if;
  elsif p_tipo in ('comprovante','boleto','nota') then
    select count(*), coalesce(sum((x->>'valor')::numeric), 0), count(*) filter (where coalesce((x->>'valor')::numeric, 0) <= 0)
      into n, s, ruins from jsonb_array_elements(coalesce(l->'itens', '[]')) x;
    ok := n > 0 and ruins = 0;
  else
    return jsonb_build_object('ok', false, 'itens', 0, 'avisos', jsonb_build_array('não reconheci como documento financeiro'));
  end if;
  if ruins > 0 then ok := false; av := av || (ruins || ' linha(s) sem data ou valor legível'); end if;
  if n = 0 then ok := false; av := av || 'nenhuma linha lida'::text; end if;
  return jsonb_build_object('ok', ok, 'itens', n, 'soma', round(s, 2), 'esperado', esp, 'avisos', to_jsonb(av));
end $$;

-- refaz a conferência das faturas que ainda estão para conferir (a leitura não muda; só a conta)
update fin.envios set checagens = fin._checar_leitura(tipo, leitura), atualizado_em = now()
 where status = 'conferir' and tipo = 'fatura' and checagens is distinct from fin._checar_leitura(tipo, leitura);
