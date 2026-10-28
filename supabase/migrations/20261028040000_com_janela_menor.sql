-- =============================================================================
-- Idealize AI — Comercial: leitura da Kommo em pedaços menores  · Migração 20261028040000
-- Achado ao ligar (28/10): mais de 5 mil mensagens em 3 dias; a leitura parava no limite de páginas.
-- Agora o tamanho de cada pedaço vem da configuração (com.sync.janela_horas, 12 h) e o histórico inicial é de 7 dias
-- (suficiente para os alertas e para o tempo médio). O resto do comportamento é o mesmo.
-- Em produção o pedaço foi ajustado depois para 6 h (core.config com.sync.janela_horas): 12 h noturnas já trouxeram 2.540 mensagens.
-- =============================================================================
insert into core.config (chave, valor) values ('com.sync.janela_horas', '12')
on conflict (chave) do nothing;
update core.config set valor = '7', atualizado_em = now()
 where chave = 'com.sync.primeira_janela_dias' and not exists (select 1 from com.sincronizacoes);

create or replace function com.proxima_janela() returns jsonb
language sql stable security definer set search_path = com, core, pg_catalog as $$
  with ult as (select max(ate) ate from com.sincronizacoes),
  d as (select coalesce((select ate from ult) - interval '10 minutes',
                        now() - make_interval(days => com._cfg_int('com.sync.primeira_janela_dias', 30))) desde,
               make_interval(hours => least(greatest(com._cfg_int('com.sync.janela_horas', 72), 1), 72)) passo)
  select jsonb_build_object('desde', floor(extract(epoch from d.desde))::bigint,
                            'ate', floor(extract(epoch from least(now(), d.desde + d.passo)))::bigint)
  from d
$$;
