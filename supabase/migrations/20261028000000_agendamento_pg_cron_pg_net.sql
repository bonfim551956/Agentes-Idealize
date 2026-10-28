-- Agendamento dos agentes: pg_cron (relógio) + pg_net (chamada HTTP às funções).
-- A senha de cada agente sai do Vault na hora da chamada; nunca fica escrita no agendamento.
-- (Aplicado no Supabase Idealize em 28/10/2026 com "PODE LIGAR A ATRIBUIÇÃO"; no banco local de testes não existe.)
do $$ begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then create extension if not exists pg_cron; end if;
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then create extension if not exists pg_net; end if;
end $$;

create or replace function core.chamar_agente(p_funcao text, p_segredo_vault text, p_timeout_ms int default 300000) returns bigint
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_chave text; v_id bigint;
begin
  if p_funcao !~ '^[a-z0-9-]{2,60}$' then raise exception 'função inválida'; end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v_chave using p_segredo_vault;
  if v_chave is null then raise exception 'segredo % não está no Vault', p_segredo_vault; end if;
  execute 'select net.http_post(url := $1, headers := $2, body := ''{}''::jsonb, timeout_milliseconds := $3)' into v_id
    using 'https://upkxaovgutzgackexhax.supabase.co/functions/v1/' || p_funcao,
          jsonb_build_object('x-worker-key', v_chave, 'content-type', 'application/json'), p_timeout_ms;
  return v_id;
end $$;
revoke all on function core.chamar_agente(text, text, int) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function core.chamar_agente(text, text, int) from anon, authenticated';
  end if;
end $$;
