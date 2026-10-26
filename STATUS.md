# STATUS — Idealize AI

**Fase atual:** F — decisões do Diego aplicadas (v0.3.0); outubro de SV reprocessado e validado; falta só a fatura do cartão (R$ 4.165,55)
**Último estado validado:** 26/10/2026 ~14:40 — `fin` v0.3.0 · local 78 + 71 + 8 + 27 + concorrência · Supabase: validador independente sem falhas, saldo de abertura conferido
**Produção:** projeto novo dedicado; o Finance AI atual (Sistema ADM) segue intocado.
**Repositório:** github.com/bonfim551956/Agentes-Idealize

## Entregáveis concluídos
- [x] A — Diagnóstico (`docs/DIAGNOSTICO.md`)
- [x] B — Fundação `supabase/migrations/20261026090000_core_fundacao.sql`
- [x] C — Testes executados (`docs/evidencias/2026-10-26_fundacao_v0.1.0.txt`)
- [x] ADR 0001 — fundação no Postgres
- [x] C′ — aplicada no Supabase Idealize; smoke 10/10; advisor sem avisos (`docs/evidencias/2026-10-26_supabase_idealize.md`)
- [x] Migração 20261026113000 — search_path das funções de trigger
- [x] D1 — modelo financeiro (naturezas, contas, empresas, cartão/fatura, reembolso, rateio, transferências) — `20261026120000`
- [x] D2 — importação idempotente de extrato + conciliação automática (2 regras) e manual — `20261026120000`
- [x] D3 — DRE, caixa por conta/unidade/consolidado, previsto, pendências; fechamento com 3 papéis — `20261026120100`
- [x] E — 71 testes financeiros (12 cenários do §19) + validador independente pelo extrato
- [x] ADR 0002 — regras financeiras (`docs/adr/0002-regras-financeiras.md`)
- [x] Aplicado no Supabase Idealize; smoke 13/13 (`docs/evidencias/2026-10-26_supabase_financeiro.md`)
- [x] v0.2.1 — conciliação por código do comprovante e por CPF/CNPJ na descrição do banco (`20261026140000`)
- [x] v0.2.2 — correção E2E × FITID achada na homologação (`20261026141500`) + teste de regressão
- [x] Cadastro de produção (`supabase/seed/producao_cadastro.sql`) + regras de pessoas fora do Git
- [x] F (observação) — extrato Sicredi SV 01–26/10 + Finance AI: 205/205 e 104/104, validador independente ok
      (`docs/evidencias/2026-10-26_homologacao_sicredi_sv.md`)
- [x] v0.3.0 — decisões do Diego: estorno (líquido zero na DRE), pagamento de fatura de cartão com pendência até as
      compras, VT no fim do mês por regra com condição de data, reclassificação/regra/saldo só por pessoa e auditados
      (`20261026150000`, 27 testes)

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
1. Repositório público até o fim do projeto (decisão do Diego). Por isso dados pessoais ficam só em `dados_privados/`.
2. Correção de controle de acesso no sistema legado (crítico — ver documento interno)
3. Fatura do cartão Sicredi paga em 23/10 (R$ 4.165,55) — para lançar as compras na DRE
5. Extratos das outras contas/unidades para estender a homologação

## Defeitos encontrados e corrigidos pelos testes financeiros
- Pendências sem vínculo colidiam entre unidades (saldo divergente de uma unidade reaproveitava a de outra).
- Despesa reembolsada concorria com o próprio reembolso na conciliação (ficava ambígua).
- Movimento de mesmo valor que um comprovante fora da janela viraria lançamento novo (duplicaria a despesa).
- Perna de transferência sem extrato era rotulada como "comprovante sem pagamento".

## Próxima ação
Aplicar as decisões do Diego (regras e reclassificações, com auditoria) e reprocessar outubro de SV.
Depois: G — ligar o robô do WhatsApp ao `fin` em paralelo ao Finance AI (adaptador Z-API, só leitura do grupo),
painel de pendências e liberação gradual por unidade.

## Riscos
Ver `docs/DIAGNOSTICO.md` §4.

## Como rodar os testes
```bash
PGHOST=/caminho/socket PGPORT=5432 ./scripts/test.sh
```
