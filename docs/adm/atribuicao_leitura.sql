-- =============================================================================
-- Sistema ADM — visão de LEITURA das vendas para o agente de Atribuição da Idealize AI.
-- Só aplicar com "PODE FAZER" do Diego. Não altera nenhuma tabela existente.
-- Entrega id da OS, loja, data, tipo, valor e os DÍGITOS do telefone. O telefone só é usado em memória pela função
-- de leitura para gerar um código irreversível (HMAC com segredo da plataforma); o número nunca é gravado na Idealize AI.
-- Sem nome, CPF, receita ou vendedor. Usa o usuário só leitura idealize_ai_leitor.
-- =============================================================================
create schema if not exists idealize_ai;
revoke all on schema idealize_ai from public;

create or replace view idealize_ai.vendas_atribuicao with (security_barrier = true) as
select c.id, c.unidade, c.dt_venda, coalesce(c.tipo, '') as tipo, c.valor_venda,
       regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g') as telefone_digitos
from public.os_cards c
where c.cancelado_em is null and c.dt_venda is not null;

grant usage on schema idealize_ai to idealize_ai_leitor;
grant select on idealize_ai.vendas_atribuicao to idealize_ai_leitor;
revoke all on idealize_ai.vendas_atribuicao from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on idealize_ai.vendas_atribuicao from anon, authenticated';
  end if;
end $$;
