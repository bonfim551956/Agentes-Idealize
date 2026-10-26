# Evidência — Etapa F (homologação em modo observação) — Sicredi São Vicente, 01–26/10/2026

Autorização: Diego enviou o extrato e liberou o cadastro (26/10, 13:57). Nada foi aprovado nem fechado.
O Sistema ADM foi apenas lido. Detalhes com nomes/valores ficam em `dados_privados/` (fora do Git, LGPD).

## Execução
1. `scripts/ofx_to_json.py` converteu o OFX (205 linhas, FITID único por linha, valores em Decimal).
2. `supabase/seed/producao_cadastro.sql` + regras privadas: 5 unidades, 4 empresas, 1 conta, 70 regras.
3. Export somente leitura do Finance AI (104 lançamentos confirmados de SV) carregado como `pendente`, origem whatsapp.
4. `fin.conciliar` + `fin.lancar_do_extrato` no Supabase Idealize. Resultado idêntico ao ensaio local feito do zero.
5. `scripts/validar_homologacao.py` — validador independente (não usa o motor) — **todas as verificações passaram**.

## Números
| Verificação | Resultado |
|---|---|
| Movimentos do OFX com exatamente um par | 205/205 |
| Lançamentos do Finance AI com exatamente um par (mesmo valor, data ≤ 3 dias, mesmo CPF/CNPJ) | 104/104 |
| Comprovantes sem pagamento no banco | 0 |
| Saídas do banco sem comprovante | 2 |
| Regras de par usadas | documento 80 · código na descrição 10 · valor+data único 14 · regra de extrato 101 |
| Caixa da unidade = extrato | ok (entradas e saídas) |
| Consolidado exclui transferência entre unidades | ok |
| DRE + transferências = total do extrato | ok |
| Cadeia de auditoria | íntegra (326 eventos) |
| Advisor de segurança após carga real | 0 WARN/ERROR |

## Defeitos achados
- **Motor (corrigido, `20261026141500`)**: E2E do comprovante × FITID do banco eram tratados como IDs conflitantes;
  9/104 ficaram sem par. A trava anti-duplicidade segurou (nenhuma despesa em dobro). Teste de regressão adicionado.
- **Validador (corrigido)**: somava duas vezes os lançamentos sem categoria na prova da DRE. O motor estava certo.
- **Classificação do Finance AI**: 5 grupos de erro e 6 decisões pendentes — relatório privado entregue ao Diego.
