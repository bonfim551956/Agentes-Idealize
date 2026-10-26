# Evidência — Agente de Laboratório v0.1.0 (instalado, PAUSADO, sem leitura do ADM)

Data: 26–27/10/2026 · Decisão do Diego: seguir com os demais agentes, um por vez, todos desligados e só leitura;
Laboratório usa o kanban (ADM) como base e o portal WebPedidos da Braslab para conferir.

## Auditoria da fonte (só leitura, via MCP)
- Kanban = `public.os_cards` no Sistema ADM (≈ 6.500 OS). Etapas pelo código do kanban: 0 Pedido, 1 Aguardando lentes,
  2 Aguardando montagem, 3 Em montagem, 4 Avisado, 5 Entregue; a versão atual também usa 6 (não retirado), 7 (cancelado)
  e 8 (2 cartões, nome desconhecido). **Nomes a confirmar com o Diego** (`lab.etapas.confirmada = false`).
- A tabela tem nome, telefone, receita e valores do cliente: o agente NÃO lê esses campos (visão própria no ADM).

## Instalado no Supabase Idealize
- Migração `20261027090000_lab_agente.sql` (`lab_agente`): espelho sem dados pessoais, alertas que se resolvem sozinhos
  (prazo vencido, parado na etapa, avisado e não retirado, sem número do pedido no laboratório, refeito, etapa/loja
  desconhecida), validador independente, agendamento por janela de 15 min, `painel_lab` com escopo por unidade.
- 7 funções conferidas por md5 contra o banco de testes: idênticas.
- Edge function `lab-sync` (sem segredo → 503). Política: agente **proibido** de criar/alterar/cancelar pedido.
- Painel: nova tela "Laboratório".

## Estado conferido
agentes financeiro e laboratório = pausado · `lab.sync.ativo` = false · espelho vazio · fila vazia ·
funções `lab.*` não expostas · anon sem `painel_lab` · auditoria íntegra.

## Testes
362+ testes SQL (38 do laboratório), concorrência, 11 + 5 Deno, 17 de navegador — sem falhas.

## Para ligar (cada passo com PODE FAZER)
1. [feito 26/10] Etapas confirmadas; "Aguardando lentes" parado após 4 dias. Coluna 8 segue sem nome.
2. [feito 26/10, PODE FAZER] Visão sem dados pessoais + usuário só leitura criados no ADM, SEM senha (conferido: lê só a visão).
3. Segredos no Idealize: `ADM_LEITURA_DB_URL` e `LAB_WORKER_SECRET`; agendar o `lab-sync` (ex.: a cada 15 min).
4. Ativar o agente no painel e `lab.sync.ativo = true`.
5. Fase 2: conferência no portal WebPedidos da Braslab (navegador; precisa de login e de onde rodar o navegador).
