-- =============================================================================
-- Sistema ADM — visão de LEITURA do crediário para o agente de Cobranças da Idealize AI.
-- Só aplicar com "PODE FAZER" do Diego. Não altera nenhuma tabela existente.
-- Entrega parcela, valor, vencimento, situação e o número da OS (para a loja achar o cliente no próprio sistema).
-- Nenhum nome, CPF, telefone, CEP ou vendedor. Usa o usuário só leitura idealize_ai_leitor.
-- =============================================================================
create schema if not exists idealize_ai;
revoke all on schema idealize_ai from public;

create or replace view idealize_ai.crediario_parcelas with (security_barrier = true) as
select p.id, p.crediario_id, p.unidade, p.financeira, p.numero, c.num_parcelas, p.valor, p.dt_vencimento, p.dt_pagamento,
       p.status, c.os, coalesce(c.os_fake, false) as os_fake, c.status as carne_status, coalesce(c.renegociado, false) as renegociado,
       c.dt_compra, c.valor_crediario, c.valor_entrada, coalesce(c.entrada_paga, false) as entrada_paga, c.dt_entrada
from public.crediario_parcelas p
left join public.crediario c on c.id = p.crediario_id;

grant usage on schema idealize_ai to idealize_ai_leitor;
grant select on idealize_ai.crediario_parcelas to idealize_ai_leitor;
revoke all on idealize_ai.crediario_parcelas from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on idealize_ai.crediario_parcelas from anon, authenticated';
  end if;
end $$;
