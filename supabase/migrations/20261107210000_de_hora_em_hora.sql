-- =============================================================================
-- Idealize AI — Conferências de hora em hora (8h às 20h)  · Migração 20261107210000
-- Pedido do Diego (07/11, PODE FAZER): "todas as aplicações devem rodar de hora em hora".
-- Caixa, Cobranças/Asaas, Multicrediário (conferência) e Atribuição passam a rodar de hora em hora das 8h às 20h
-- (Brasília = UTC-3 → 11h a 23h UTC). A chave de cada rodada passa a ser por hora (antes: blocos de 8 h e 12 h).
-- Continuam como estavam: arquivos (5 min), Kommo e Laboratório (15 min), Meta e Supervisor (hora em hora),
-- RH e Relatório do dia (1× ao dia).
-- =============================================================================
do $$ declare v text;
begin
  v := pg_get_functiondef('cx.agendar_sincronizacao()'::regprocedure);
  v := replace(v, $a$to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDD') || ':' || (h / 8)$a$, $a$to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDDHH24')$a$);
  if v !~ 'YYYYMMDDHH24' then raise exception 'agendamento do caixa não foi atualizado'; end if;
  execute v;
  v := pg_get_functiondef('cob.agendar_sincronizacao()'::regprocedure);
  v := replace(v, $a$to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDD') || ':' || (h / 12)$a$, $a$to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDDHH24')$a$);
  if v !~ 'YYYYMMDDHH24' then raise exception 'agendamento das cobranças não foi atualizado'; end if;
  execute v;
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.alter_job((select jobid from cron.job where jobname = 'cx-sync'), schedule := '20 11-23 * * *');
    perform cron.alter_job((select jobid from cron.job where jobname = 'cob-sync'), schedule := '40 11-23 * * *');
    perform cron.alter_job((select jobid from cron.job where jobname = 'multi-sync'), schedule := '45 11-23 * * *');
    perform cron.alter_job((select jobid from cron.job where jobname = 'atr-sync'), schedule := '0 11-23 * * *');
  end if;
end $$;
