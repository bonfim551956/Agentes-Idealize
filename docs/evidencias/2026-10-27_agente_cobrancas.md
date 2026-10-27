# Evidência — Agente de Cobranças v0.1.0 (27/10/2026)

Autorização: "PODE FAZER" do Diego em 26/10/2026 23:43 (instalar desligado + visão de leitura no ADM).

## Descoberta (ADM, só leitura)
- `crediario` (184 carnês: 104 Asaas, 80 Multicrédito) e `crediario_parcelas` (1.164). Sem id do Asaas no ADM:
  o cruzamento é por loja + valor (±R$ 0,10) + vencimento (±5 dias), um para um.
- Carteira em aberto ≈ R$ 148 mil (a vencer) e ≈ R$ 4,4 mil vencidos em 26/10/2026.

## Sistema ADM
- Visão `idealize_ai.crediario_parcelas` (1.164 linhas; sem nome/CPF/telefone/CEP/vendedor) criada via SQL;
  `idealize_ai_leitor` lê só a visão, `anon` sem acesso. Nenhuma tabela alterada.

## Local
- `scripts/test.sh`: 506 testes SQL PASS / 0 FAIL (inclui `tests/97_cob.sql`), Deno cobrancas-sync 5/5. Painel 24/24.

## Supabase Idealize
- Migração `cob_agente_cobrancas` aplicada; 9 de 9 funções com md5 idêntico.
- Travas: agente `pausado`, `cob.sync.ativo = false`, 7 políticas proibidas (enviar cobrança/mensagem, baixar,
  cancelar, renegociar, emitir boleto, excluir), RLS forçada, `anon` sem acesso. Lote vazio com espelho cheio é recusado.
- Edge function `cobrancas-sync` v1: sem `COB_WORKER_SECRET` responde 503.

## Para ligar ("PODE LIGAR AS COBRANÇAS")
`COB_WORKER_SECRET` + `cob_worker_secret` no Vault; `ASAAS_TOKENS` (compartilhado com o Caixa); agendar 2×/dia.
