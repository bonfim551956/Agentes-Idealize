# Evidência — aplicação no Supabase "Idealize" (upkxaovgutzgackexhax)

Data: 26/10/2026 ~08:20 (BRT) · Autorização: "PODE FAZER" do Diego, 26/10/2026 08:17

## Migrações aplicadas
| Nome no Supabase | Arquivo |
|---|---|
| core_fundacao | supabase/migrations/20261026090000_core_fundacao.sql |
| core_search_path_triggers | supabase/migrations/20261026113000_core_search_path_triggers.sql |

## Verificações executadas no banco real
- 17 tabelas no schema `core`, 21 funções.
- RLS ligado **e forçado** em 17/17 tabelas.
- `anon` e `authenticated`: sem USAGE no schema, 0 grants em tabelas, 0 funções executáveis.
- Schema `core` não está exposto na API REST.
- Cadeia de auditoria íntegra (`core.verificar_auditoria()` = null).
- Smoke test transacional (dados sintéticos, desfeito no fim): **10/10 PASS** —
  negação por escopo de unidade; idempotência; executor não valida a si mesmo; validador independente conclui;
  solicitante não aprova; duas aprovações liberam; lease vencido → incerta; UPDATE na auditoria bloqueado;
  cadeia íntegra após o teste; agente não altera a matriz.
- Após o teste: 0 tarefas, 0 unidades, 1 principal (o agente financeiro de base) — nenhum resíduo.
- Advisor de segurança: 0 WARN/ERROR. Restam 17 INFO "RLS sem políticas" — **intencional** (negar tudo; acesso só via funções com service_role).

## Observação
A sequência da auditoria é não transacional: testes desfeitos consomem números. A cadeia de hash continua íntegra (encadeia pelo hash anterior, não pela contiguidade do id).
