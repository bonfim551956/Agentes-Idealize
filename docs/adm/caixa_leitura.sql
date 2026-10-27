-- =============================================================================
-- Sistema ADM — visões de LEITURA do fechamento de caixa para o agente de Caixa da Idealize AI.
-- Só aplicar com "PODE FAZER" do Diego. Não altera nenhuma tabela existente.
-- Entregam só loja, dia, forma de pagamento e valor: nenhum cliente, OS, CPF, telefone ou vendedor.
-- Usa o mesmo usuário só leitura do laboratório (idealize_ai_leitor).
-- =============================================================================
create schema if not exists idealize_ai;
revoke all on schema idealize_ai from public;

-- Cada valor recebido no fechamento, um por linha (sem cliente/OS): vendas (forma1/pago1, forma2/pago2, extras)
-- e entregas (saldo: forma/valor, forma2/valor2). O agente casa cada valor com o extrato (banco, Asaas, Stone).
create or replace view idealize_ai.caixa_pagamentos with (security_barrier = true) as
select f.unidade, f.data, x.origem, lower(btrim(coalesce(x.forma, ''))) as forma, n.valor
from public.fechamento_caixa f
cross join lateral (
  select 'venda' as origem, e->>'forma1' as forma, e->>'pago1' as valor
  from jsonb_array_elements(case when jsonb_typeof(f.vendas) = 'array' then f.vendas else '[]' end) e
  union all
  select 'venda', e->>'forma2', e->>'pago2' from jsonb_array_elements(case when jsonb_typeof(f.vendas) = 'array' then f.vendas else '[]' end) e
  union all
  select 'venda', x->>'forma', x->>'valor'
  from jsonb_array_elements(case when jsonb_typeof(f.vendas) = 'array' then f.vendas else '[]' end) e,
       jsonb_array_elements(case when jsonb_typeof(e->'extras') = 'array' then e->'extras' else '[]' end) x
  union all
  select 'entrega', e->>'forma', e->>'valor' from jsonb_array_elements(case when jsonb_typeof(f.entregas) = 'array' then f.entregas else '[]' end) e
  union all
  select 'entrega', e->>'forma2', e->>'valor2' from jsonb_array_elements(case when jsonb_typeof(f.entregas) = 'array' then f.entregas else '[]' end) e
) x
cross join lateral (select case when x.valor ~ '^-?[0-9]{1,9}(\.[0-9]+)?$' then x.valor::numeric end as valor) n
where n.valor <> 0;

create or replace view idealize_ai.caixa_dias with (security_barrier = true) as
select f.unidade, f.data, f.status, f.caixa, f.dinheiro_gaveta, f.deposito_valor, f.deposito_data, f.updated_at
from public.fechamento_caixa f;

grant usage on schema idealize_ai to idealize_ai_leitor;
grant select on idealize_ai.caixa_pagamentos, idealize_ai.caixa_dias to idealize_ai_leitor;
revoke all on idealize_ai.caixa_pagamentos, idealize_ai.caixa_dias from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on idealize_ai.caixa_pagamentos, idealize_ai.caixa_dias from anon, authenticated';
  end if;
end $$;
