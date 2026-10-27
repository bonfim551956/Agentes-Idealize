# Evidência — Agente de Marketing / Meta Ads v0.1.0 (27/10/2026)

Autorização: "PODE FAZER" do Diego em 26/10/2026 23:01 (instalar desligado).

## Descoberta (conector Meta Ads, só leitura)
10 contas de anúncio visíveis (BM Óticas Idealize São Vicente, BM Visão Ideal Campinas, BM "Desativada" Campinas e uma
conta sem BM). Resultado principal das campanhas de venda: `onsite_conversion.messaging_conversation_started_7d`;
campanhas de vagas de emprego medem visitas à página. Pontos levados ao Diego: CA IDEALIZE SOROCABA e a conta
786176966179773 sem forma de pagamento; CA IDEALIZE SÃO VICENTE ainda não liberada no conector (a API normal lê).

## Local (Postgres 16)
- `scripts/test.sh`: 440 testes SQL PASS / 0 FAIL (inclui `tests/90_mkt.sql`), Deno meta-sync 8/8.
- Painel: 22/22 Playwright (inclui a página Marketing).

## Supabase Idealize (upkxaovgutzgackexhax)
- Migração `mkt_agente_meta` aplicada; 13 de 13 funções com md5 idêntico ao banco de teste.
- Travas: agente `pausado`, `mkt.sync.ativo = false`, 7 políticas proibidas (criar/alterar campanha, orçamento,
  pausar, ativar, criar anúncio, excluir), RLS forçada em todas as tabelas `mkt`, `anon` sem acesso ao painel.
- Edge function `meta-sync` v1 publicada: sem `MKT_WORKER_SECRET` responde 503; com segredo, "desligado" enquanto
  `mkt.sync.ativo` = false; sem `META_TOKENS`, "sem_credencial_da_meta".

## Para ligar (só com "PODE LIGAR O MARKETING")
1. Diego cria um usuário do sistema com `ads_read` em cada BM e salva os tokens em `META_TOKENS` (separados por vírgula).
2. `MKT_WORKER_SECRET` nos Secrets e `mkt_worker_secret` no Vault (mesmo valor).
3. Agendar de hora em hora; ativar agente `marketing` e `mkt.sync.ativo = true`. Primeira leitura: 30 dias.
