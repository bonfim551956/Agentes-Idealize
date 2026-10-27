# STATUS — Idealize AI

**Fase atual:** Demais agentes, um por vez (Laboratório → Comercial/Kommo → Marketing/Meta → Caixa → Cobranças/Asaas → RH). Laboratório, Comercial, Marketing, Caixa e Cobranças instalados e pausados; nada rodando. Falta RH.
**Último estado validado:** 26/10/2026 — v0.5.0 · 324 testes SQL + concorrência + 11 Deno + 10 unidade + 16 navegador, 0 falhas · Supabase: 41 funções idênticas às testadas, nada rodando
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
- [x] G (instalado, desligado) — canal WhatsApp: `20261026160000` + edge functions `fin-whatsapp-webhook` e `fin-worker`
      (37 testes SQL + 11 Deno, incluindo ponta a ponta com Postgres real) — `docs/evidencias/2026-10-26_etapa_g_whatsapp.md`
- [x] Painel administrativo (§4.1, §17, §21) — camada de acesso `20261026170000` aplicada (100 testes SQL), front em
      `painel/` (React; login + 2FA obrigatório), revisão de segurança independente tratada, ADR 0003 —
      `docs/evidencias/2026-10-26_painel_supabase.md`. Publicado pelo Diego na Vercel; login dele vinculado com 2FA.
- [x] Agente de Laboratório v0.1.0 (§5.3) — `20261027090000`, `lab-sync`, tela no painel; instalado PAUSADO e sem
      leitura do ADM — `docs/evidencias/2026-10-27_agente_laboratorio.md`
- [x] Agente Comercial/Kommo v0.1.0 — `20261027100000`, `kommo-sync` (só GET), tela no painel; instalado PAUSADO,
      sem leitura e sem agendamento — `docs/evidencias/2026-10-27_agente_comercial.md`
- [x] Agente de Marketing/Meta v0.1.0 — `20261027110000`, `meta-sync` (só GET, ads_read), tela no painel; instalado
      PAUSADO, sem leitura e sem agendamento — `docs/evidencias/2026-10-27_agente_marketing.md`
- [x] Agente de Caixa v0.1.0 — `20261027120000`, `caixa-sync` (ADM só leitura + Asaas só GET), visões no ADM
      (`docs/adm/caixa_leitura.sql`), tela no painel; instalado PAUSADO — `docs/evidencias/2026-10-27_agente_caixa.md`.
      Pendente: leitor do arquivo da Stone (aguardando arquivo de exemplo).
- [x] Agente de Cobranças v0.1.0 — `20261027130000`, `cobrancas-sync` (ADM só leitura + Asaas só GET), visão no ADM
      (`docs/adm/cobrancas_leitura.sql`), tela no painel; instalado PAUSADO — `docs/evidencias/2026-10-27_agente_cobrancas.md`

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
Abrir o painel quando o Diego decidir: login no Supabase Auth + cadastro público desligado → publicar na Vercel →
vincular o login (feito em 26/10: login do Diego vinculado, 2FA ativo). Ligar a Etapa G só com "PODE FAZER" do Diego, nesta ordem (checklist em `docs/evidencias/2026-10-26_etapa_g_whatsapp.md`):
segredos → apontar o webhook → agendar o worker → ativar agente → `fin.whatsapp.ativo=true` (com `responder=false`,
modo sombra, em paralelo ao Finance AI). Depois: painel de pendências e liberação gradual por unidade.

## Riscos
Ver `docs/DIAGNOSTICO.md` §4.

## Como rodar os testes
```bash
PGHOST=/caminho/socket PGPORT=5432 ./scripts/test.sh
```
