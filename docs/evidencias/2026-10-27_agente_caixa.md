# Evidência — Agente de Caixa v0.1.0 (27/10/2026)

Autorização: "PODE FAZER" do Diego em 26/10/2026 23:27 (instalar desligado + visões de leitura no ADM).
Decisões do Diego: Pix cai na conta do banco; Asaas é uma conta por loja/CNPJ; cartões são Stone em todas as lojas;
trabalhar com API (Asaas) e extratos baixados (banco, Stone).

## Descoberta (leitura no ADM e no Idealize)
- `public.fechamento_caixa` (113 dias, 01/09 a 26/10/2026): vendas (forma1/pago1, forma2/pago2, extras) e entregas
  (forma/valor, forma2/valor2). Em 98 de 113 dias o total `caixa` = soma das formas; os outros 15 viram alerta.
- Teste da lógica com Pix de São Vicente (15–26/10) contra o Sicredi SV: valores batem 1:1 com folga de dias
  (Pix de sábado lançado na segunda) e há casos de dois valores no caixa = um Pix (275+275=550, 150+150=300, 100+100=200).
- Créditos "STONE ANTEC/DEB" no banco = liquidação dos cartões (não usados na conferência por data de venda).

## Sistema ADM (xxmrdadnchxdsfinvzsp)
- Visões `idealize_ai.caixa_pagamentos` (1.844 linhas) e `idealize_ai.caixa_dias` (113) criadas via SQL;
  `idealize_ai_leitor` lê só as visões (não a tabela), `anon` sem acesso. Nenhuma tabela alterada.

## Local (Postgres 16)
- `scripts/test.sh`: 474 testes SQL PASS / 0 FAIL (inclui `tests/95_cx.sql`), Deno caixa-sync 6/6. Painel 23/23.

## Supabase Idealize
- Migração `cx_agente_caixa` aplicada; 11 de 11 funções com md5 idêntico ao banco de teste.
- Travas: agente `pausado`, `cx.sync.ativo = false`, 6 políticas proibidas, RLS forçada, `anon` sem acesso ao painel.
- Edge function `caixa-sync` v1: sem `CX_WORKER_SECRET` responde 503; desligada enquanto `cx.sync.ativo` = false.

## Pendências
- Leitor do arquivo da Stone (crédito/débito): aguardando arquivo real.
- Para ligar ("PODE LIGAR O CAIXA"): `CX_WORKER_SECRET` + `cx_worker_secret` no Vault; `ASAAS_TOKENS` ("unidade=chave"
  por linha); importar extratos bancários das outras lojas no financeiro; agendar 3×/dia.
