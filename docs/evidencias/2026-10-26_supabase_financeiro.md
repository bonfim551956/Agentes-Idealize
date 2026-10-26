# Evidência — schema fin no Supabase "Idealize" (upkxaovgutzgackexhax)

Data: 26/10/2026 ~08:45 (BRT) · Autorização: "PODE FAZER" (08:17) + "PODEMOS SEGUIR" (08:34)

## Migrações aplicadas
| Nome no Supabase | Arquivo |
|---|---|
| fin_modelo_financeiro | supabase/migrations/20261026120000_fin_modelo_financeiro.sql |
| fin_fechamento | supabase/migrations/20261026120100_fin_fechamento.sql |
| fin_indices_caminho_quente | supabase/migrations/20261026124500_fin_indices_caminho_quente.sql |

## Verificações no banco real
- 17 tabelas em `fin`; RLS ligado e forçado em todas as 34 tabelas de `core` + `fin`.
- `anon`/`authenticated` sem USAGE em `fin`.
- 39 categorias do plano de contas carregadas; nenhuma unidade/conta real ainda (aguardando confirmação).
- Smoke transacional, desfeito no fim: **13/13 PASS** — importação + idempotência por arquivo; conciliação por
  ID bancário; valor divergente fica contestado sem alterar valor; cartão na DRE uma vez e fatura só no caixa;
  transferência interna fora do caixa da unidade; fechamento bloqueado com pendência; validação independente ok
  após resolver; gerente não aprova; diretoria aprova; competência travada; cadeia de auditoria íntegra;
  sem acesso público.
- Após o teste: 0 lançamentos, 0 movimentos, 0 unidades — sem resíduo.
- Advisor de segurança: 0 WARN/ERROR (34 INFO "RLS sem políticas", intencional).
- Advisor de desempenho: só INFO; índices criados para as FKs do caminho quente.

## Local
`docs/evidencias/2026-10-26_financeiro_v0.2.0_local.txt` — 78/78 core, 71/71 financeiro, concorrência ok.
