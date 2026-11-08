-- =============================================================================
-- Idealize AI — Caixa: dinheiro depositado e Multicrediário contam como achados · Migração 20261108120000
-- Pedido do Diego (08/11): "já subi o extrato que constam os depósitos, ele já deveria ter feito o fechamento do caixa e
-- dado OK". Achado: a conferência por dia só olhava o casamento com extrato/Stone/Asaas. O dinheiro já casado com o
-- depósito do extrato e o Multicrediário já casado venda a venda apareciam como "faltando" — e nenhum dia ficava OK.
-- Agora um pagamento conta como achado quando: casou com extrato/Stone/Asaas, OU é dinheiro de um dia cujo depósito foi
-- achado no extrato, OU é Multicrediário casado venda a venda.
-- =============================================================================

create or replace function cx.pagamento_achado(p_id bigint, p_forma text, p_unidade text, p_dia date) returns boolean
language sql stable security definer set search_path = cx, pg_catalog as $$
  select exists (select 1 from cx.casamentos c where c.pagamento_id = p_id)
      or (p_forma = 'dinheiro' and exists (select 1 from cx.depositos_casados d where d.unidade_id = p_unidade and d.dia = p_dia))
      or (p_forma = 'crediario' and exists (select 1 from cx.multi_casamentos m where m.unidade_id = p_unidade and p_id = any(m.pagamentos)))
$$;
revoke all on function cx.pagamento_achado(bigint, text, text, date) from public;

do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_caixa(text,integer,date,date)'::regprocedure);
  if v !~ 'pagamento_achado' then
    v := replace(v, $a$filter (where exists (select 1 from cx.casamentos c where c.pagamento_id = pg.id))$a$,
                    $a$filter (where cx.pagamento_achado(pg.id, pg.forma, pg.unidade_id, pg.dia))$a$);
    v := replace(v, $a$filter (where not exists (select 1 from cx.casamentos c where c.pagamento_id = pg.id))$a$,
                    $a$filter (where not cx.pagamento_achado(pg.id, pg.forma, pg.unidade_id, pg.dia))$a$);
    if (length(v) - length(replace(v, 'pagamento_achado', ''))) / length('pagamento_achado') <> 2 then
      raise exception 'painel_caixa não foi atualizada';
    end if;
    execute v;
  end if;
end $$;

-- O arquivo da Stone de novembro não cobre outubro: a cobertura passa a ter início e fim. Dia antes do primeiro arquivo
-- fica "aguardando arquivo", e não "faltando".
do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_caixa(text,integer,date,date)'::regprocedure);
  if v !~ '''desde'', \(select min\(m.data\)' then
    v := replace(v, $a$'ate', (select max(m.data) from fin.movimentos m where m.conta_id in (select id from fin.contas where unidade_id = c.unidade_id and tipo = 'corrente'))) x$a$,
      $a$'desde', (select min(m.data) from fin.movimentos m where m.conta_id in (select id from fin.contas where unidade_id = c.unidade_id and tipo = 'corrente')),
         'ate', (select max(m.data) from fin.movimentos m where m.conta_id in (select id from fin.contas where unidade_id = c.unidade_id and tipo = 'corrente'))) x$a$);
    v := replace(v, $a$'fonte', co.fonte, 'ate', co.ate)$a$,
      $a$'fonte', co.fonte, 'ate', co.ate, 'desde', (select min(r.dia) from cx.recebimentos r where r.fonte = co.fonte and r.unidade_id = co.unidade_id))$a$);
    if v !~ '''desde'', \(select min\(m.data\)' or v !~ '''desde'', \(select min\(r.dia\)' then raise exception 'cobertura do caixa não foi atualizada'; end if;
    execute v;
  end if;
end $$;
