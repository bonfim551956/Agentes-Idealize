# ADR 0001 — Fundação (orquestrador, fila, autorização, auditoria) dentro do Postgres

Status: aceita · 26/10/2026

## Contexto
O Finance AI já roda em Supabase (Postgres 17 + edge functions + pg_cron) e concentra a lógica financeira em funções SQL transacionais. O volume esperado é de dezenas a centenas de operações por hora, não milhares por segundo. Há um único mantenedor técnico.

## Alternativas
1. **Postgres (schema `core`) + edge functions/pg_cron como workers** — mesmo stack já em produção, transações ACID entre fila, autorização e auditoria, `FOR UPDATE SKIP LOCKED` para concorrência, zero serviço novo para operar.
2. Fila dedicada (Redis/BullMQ, SQS) + serviço Node no Cloud Run — mais vazão, mas separa estado da fila do estado do negócio (exige outbox/2PC), mais custo e mais coisa para monitorar.
3. Orquestrador de workflows (Temporal, Inngest) — ótima durabilidade, porém novo fornecedor, curva de aprendizado e custo.

## Decisão
Opção 1. A garantia mais importante do prompt — "não repetir escrita às cegas; verificar antes" — fica mais simples quando a tarefa, a execução, a aprovação e a auditoria mudam na **mesma transação**.

## Consequências
- Agentes interagem com a plataforma **somente** por funções `core.*` (service_role). O schema não é exposto ao PostgREST.
- Lease vencido nunca é reexecutado: vira `incerta` e exige reconciliação humana.
- A auditoria usa lock consultivo para encadear o hash: serializa as **inserções na auditoria** (não a fila). Medido: 4 workers × 200 tarefas sem duplicidade e com cadeia íntegra. Se um dia o volume exigir, troca-se por encadeamento assíncrono em lote.
- Workers 24/7 = pg_cron disparando edge functions (já é o padrão do Finance AI). A sessão do Claude Code não executa nada em produção.
- Migração para outro banco/fila continua possível: a interface é o conjunto de funções `core.*`.
