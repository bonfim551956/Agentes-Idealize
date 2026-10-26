-- =============================================================================
-- PROPOSTA — NÃO APLICADA. Roda no projeto "Sistema ADM" (não no Idealize) e só com "PODE FAZER" do Diego.
-- Dá ao agente de Laboratório acesso SÓ DE LEITURA ao kanban, por uma visão SEM dados pessoais
-- (sem cliente, telefone, receita, valores ou pagamentos). Não altera nenhuma tabela existente.
-- =============================================================================
create schema if not exists idealize_ai;
revoke all on schema idealize_ai from public;

create or replace view idealize_ai.lab_os with (security_barrier = true) as
select c.id, c.unidade, c.os, c.ped, c.tipo, c.lab, c.col, c.dt_venda, c.prazo,
       coalesce(c.urgente, false)                                   as urgente,
       coalesce(c.refeito, false)                                   as refeito,
       c.cancelado_em is not null                                   as cancelado,
       c.nao_ret_em is not null                                     as nao_retirado,
       coalesce(c.saldo, false) and not coalesce(c.saldo_pago, false) as saldo_aberto,
       c.ts,
       (select max((h->>'at')::bigint)
          from jsonb_array_elements(case when jsonb_typeof(c.history) = 'array' then c.history else '[]'::jsonb end) h
         where h->>'to' = c.col::text and (h->>'at') ~ '^[0-9]+$')    as entrou_etapa_ms
from public.os_cards c;

-- Usuário próprio, só leitura, só esta visão. A senha é gerada na hora e vai direto para o segredo
-- ADM_LEITURA_DB_URL das funções do projeto Idealize (nunca no Git, nunca no chat).
-- create role idealize_ai_leitor login password '<gerar>' connection limit 3;
-- alter role idealize_ai_leitor set default_transaction_read_only = on;
-- alter role idealize_ai_leitor set statement_timeout = '15s';
-- grant usage on schema idealize_ai to idealize_ai_leitor;
-- grant select on idealize_ai.lab_os to idealize_ai_leitor;
-- (anon/authenticated do ADM não recebem nada: a visão não é exposta pela API)
revoke all on idealize_ai.lab_os from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on idealize_ai.lab_os from anon, authenticated';
  end if;
end $$;
