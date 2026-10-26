# ADR 0002 — Regras do agente financeiro: extrato como verdade, caixa ≠ DRE

Status: aceita · 26/10/2026

## Contexto
O Finance AI atual registra só "saídas" a partir de comprovantes do WhatsApp. O prompt (§9) exige separar
naturezas, não contar nada duas vezes, distinguir realizado de previsto e nunca forçar conciliação.

## Decisões
1. **O extrato bancário é a evidência do realizado.** Comprovante gera lançamento `pendente`; só a conciliação
   com um movimento do extrato o torna `conciliado` e o faz entrar no caixa.
2. **Natureza explícita**: receita, despesa, transferência interna, transferência entre unidades, reembolso,
   pagamento de fatura, ajuste. A categoria do plano de contas é separada da natureza.
3. **Duas visões, regras diferentes:**

   | Situação | DRE (competência) | Caixa da unidade | Caixa consolidado |
   |---|---|---|---|
   | Compra no cartão | conta na compra | não conta | não conta |
   | Pagamento da fatura | não conta | conta | conta |
   | Despesa paga pelo colaborador + reembolso | conta a despesa | conta o reembolso | conta o reembolso |
   | Transferência entre contas da unidade | não conta | não conta | não conta |
   | Transferência entre unidades | não conta | conta | não conta |
   | Rateio | redistribui entre unidades | não muda | não muda |
   | Previsto | não conta | não conta (visão própria) | não conta |
   | Contestado / pendente / cancelado | não conta | não conta | não conta |

4. **Conciliação automática só por duas regras testadas:** mesmo ID bancário (E2E/FITID) com mesmo valor; ou
   mesmo valor + sentido + janela de 3 dias **com par único nos dois sentidos**. Qualquer outra situação vira
   pendência humana. Valor nunca é alterado; conciliação manual exige soma exata.
5. **Importação idempotente:** arquivo pelo SHA-256; linha pelo ID do banco ou por data|valor|descrição|ordinal
   (dois PIX idênticos no mesmo dia continuam sendo dois).
6. **Fechamento em três papéis:** o agente prepara; um validador diferente recalcula pelo extrato
   (saldo inicial + movimentos = saldo final; conciliado = movimentado; caixa do pacote = caixa do extrato);
   só pessoa da diretoria aprova, preso ao hash do pacote. Competência aprovada fica travada.

## Consequências
- Lançamentos do WhatsApp continuam úteis (documento, contraparte, categoria), mas só viram realizado com extrato.
  Sem importar extratos, o caixa fica vazio — isso é intencional.
- O 2º lado de transferências entre unidades fica como pendência **não material** até o extrato da outra unidade.
- Caixa físico (dinheiro) não tem extrato: entra por lançamento `confirmado` e o validador registra aviso
  explícito de que não houve verificação independente.
