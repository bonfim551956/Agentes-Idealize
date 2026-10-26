# Evidência — Etapa G: canal WhatsApp do agente financeiro (instalado DESLIGADO)

Data: 26/10/2026 · Projeto Supabase Idealize · Decisão do Diego: "fazer a etapa G, porém deixar desligada a princípio".

## O que foi instalado
- Migração `20261026160000_fin_whatsapp.sql` (aplicada): grupos por unidade, registro de mensagens, idempotência por
  `whatsapp:zapi:<messageId>`, tarefa no core, extração aplicada pelo banco em transação única, validador independente,
  pendência `revisao_extracao` quando a confiança da leitura é baixa, bucket privado `fin-documentos`.
- Edge function `fin-whatsapp-webhook` (v1, `verify_jwt=false`, autenticação própria por segredo na URL).
- Edge function `fin-worker` (v1, `verify_jwt=false`, autenticação própria por cabeçalho `x-worker-key`).
- Cadastro (fora do Git, `dados_privados/canal_whatsapp.sql`): 4 grupos, 3 pessoas, política de registro de comprovante.

## Travas verificadas no Supabase (26/10/2026)
| Trava | Estado |
|---|---|
| `fin.whatsapp.ativo` | `false` → `fin.receber_whatsapp` responde `{"status":"desligado"}` e não grava nada |
| `fin.whatsapp.responder` | `false` (modo sombra: nunca responde no grupo) |
| Agente `financeiro` no core | `pausado` (fila não é reivindicada) |
| Segredos `FIN_WEBHOOK_SECRET` / `FIN_WORKER_SECRET` / `ANTHROPIC_API_KEY` | não configurados → funções respondem 503 |
| Agendamento do worker | inexistente (sem `pg_cron`/`pg_net`) |
| Webhook no Z-API / repasse do ADM | não alterados |
| Mensagens gravadas | 0 |
| Auditoria | cadeia íntegra |

Obs.: a chamada HTTP às funções publicadas não pôde ser feita deste ambiente (rede bloqueada); o comportamento 503/401
sem segredo está coberto pelos testes de unidade do handler.

## Testes
221 testes SQL (0 falhas), concorrência 4×200 (0 duplicadas), 11 testes Deno (unidade + ponta a ponta com Postgres
real e Z-API/Claude simulados).

## O que NÃO foi validado
- Recebimento real do Z-API (formato do payload em produção) e download real da mídia.
- Chamada real à API do Claude com comprovantes reais.

## Para ligar (cada passo exige "PODE FAZER")
1. Configurar os 3 segredos nas edge functions.
2. Apontar o webhook "Ao receber" (Z-API ou repasse a partir do ADM) para `fin-whatsapp-webhook?s=<segredo>`.
3. Agendar o `fin-worker` (ex.: a cada minuto) com o cabeçalho `x-worker-key`.
4. Ativar o agente `financeiro` no core.
5. `fin.whatsapp.ativo = true`, mantendo `responder = false` (sombra), e comparar com o Finance AI por alguns dias.
Para desligar a qualquer momento: `fin.whatsapp.ativo = false` ou pausar o agente (ou o kill switch `plataforma_pausada`).
