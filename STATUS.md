# STATUS — Idealize AI

**Fase atual:** C′ concluída — fundação aplicada e validada no Supabase "Idealize" (`upkxaovgutzgackexhax`)
**Último estado validado:** 26/10/2026 — fundação `core` v0.1.0, 78/78 testes + concorrência, PostgreSQL 16 local isolado
**Produção:** projeto novo dedicado; o Finance AI atual (Sistema ADM) segue intocado.
**Repositório:** github.com/bonfim551956/Agentes-Idealize

## Entregáveis concluídos
- [x] A — Diagnóstico (`docs/DIAGNOSTICO.md`)
- [x] B — Fundação `supabase/migrations/20261026090000_core_fundacao.sql`
- [x] C — Testes executados (`docs/evidencias/2026-10-26_fundacao_v0.1.0.txt`)
- [x] ADR 0001 — fundação no Postgres
- [x] C′ — aplicada no Supabase Idealize; smoke 10/10; advisor sem avisos (`docs/evidencias/2026-10-26_supabase_idealize.md`)
- [x] Migração 20261026113000 — search_path das funções de trigger

## O que a fundação garante (cada item tem teste executado)
| Garantia | Testes |
|---|---|
| Negação por padrão; escopo por unidade; unidade/principal inativos negados | 7 |
| Só pessoa com papel admin altera a matriz; agente nunca; políticas versionadas e nunca apagadas | 4 |
| Idempotência por chave; proibidas ficam registradas como rejeitadas | 7 |
| Aprovação: nunca do solicitante, nunca de agente, dentro da alçada, presa ao hash da operação, 2 pessoas, expira e é revalidada | 10 |
| Sucesso vai para validação; executor não valida a si mesmo; rejeição bloqueia | 6 |
| Lease vencido / timeout após escrita → `incerta` + incidente; reconciliação só humana com evidência | 7 |
| Retentativa só para erro seguro, com backoff; esgotou → falhou + incidente | 4 |
| Prioridade e dependências na fila; permissão revalidada na hora de executar | 4 |
| Modo seguro (kill switch) com exceção para monitoramento | 2 |
| Limite de custo por agente; estimado ≠ confirmado; incidentes agrupados que escalam | 7 |
| Auditoria append-only, cadeia de hash, adulteração detectada | 7 |
| anon/authenticated sem acesso; RLS forçado; search_path fixo; injeção no payload é só dado | 6 |
| 4 workers × 200 tarefas: 0 duplicadas, cadeia íntegra | concorrência |

## Defeito encontrado e corrigido pelos testes
- Cadeia de hash da auditoria quebrava sob concorrência (id sorteado antes do lock). Corrigido: id atribuído dentro do trigger, sob lock, sequência sem lacunas.

## Bloqueios / decisões pendentes (dono: Diego)
1. Tornar o repositório Agentes-Idealize **privado** (hoje está público)
2. Correção de controle de acesso no sistema legado (crítico — ver documento interno)
3. Entradas via importação de extrato

## Próxima ação
D1 — modelo financeiro completo (natureza do lançamento, contas, transferências, rateios, cartão×fatura), desenhado em *expand/contract* sobre o `finance` atual, com o robô de WhatsApp registrando tarefas no `core`.

## Riscos
Ver `docs/DIAGNOSTICO.md` §4.

## Como rodar os testes
```bash
PGHOST=/caminho/socket PGPORT=5432 ./scripts/test.sh
```
