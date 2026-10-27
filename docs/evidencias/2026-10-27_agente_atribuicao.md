# Evidência — Agente de Atribuição v0.1.0 (27/10/2026)

Autorização: "PODE FAZER" (montar), "consegue incluir o responsavel na Kommo" e "PODE FAZER" (instalar), do Diego, 27/10/2026.

## O que faz
Lead da Kommo (loja pelo funil, atendente responsável, data do 1º contato) → venda no ADM com o mesmo telefone,
na mesma loja, em até 60 dias → faturamento por loja, por atendente e por campanha da Meta. A campanha é exata quando
a origem do lead a identifica e estimada (rateio pelo gasto do dia na loja) quando não identifica. O telefone nunca é gravado:
vira código HMAC-SHA256 (segredo `ATR_CHAVE_TELEFONE`) em memória, dos dois lados.

## Sistema ADM (xxmrdadnchxdsfinvzsp)
- Visão `idealize_ai.vendas_atribuicao` (id, unidade, data, tipo, valor, dígitos do telefone; sem canceladas):
  6.516 vendas. `idealize_ai_leitor` lê a visão e não lê a tabela; `anon` sem acesso. Nenhuma tabela alterada.

## Local
- `scripts/test.sh`: 562 testes SQL PASS / 0 FAIL (inclui `tests/98_atr.sql`, 24), Deno atribuicao-sync 6/6. Painel 26/26.

## Supabase Idealize
- Migração `atr_agente_atribuicao` aplicada; 9 de 9 funções com md5 idêntico ao testado
  (`_cfg_int`, `_hoje`, `agendar_sincronizacao`, `aplicar_lote`, `concluir_sincronizacao`, `janela`, `recalcular`,
  `validar_sincronizacao`, `painel_atribuicao`).
- Travas: agente `pausado`, `atr.sync.ativo = false`, 6 políticas proibidas (guardar telefone, enviar mensagem,
  alterar lead, alterar venda, alterar campanha, excluir), RLS forçada em todas as tabelas `atr`, `anon` sem acesso ao painel.
- O banco recusa qualquer lote com telefone fora do formato de código (64 hexadecimais).
- Edge function `atribuicao-sync` v1 (ACTIVE, verify_jwt=false): sem `ATR_WORKER_SECRET` responde 503; com
  `atr.sync.ativo = false` responde "desligado" sem ler nada.

## Para ligar ("PODE LIGAR A ATRIBUIÇÃO")
`ATR_CHAVE_TELEFONE` (32+ caracteres, definida uma vez e nunca trocada; trocar zera o histórico de casamentos),
`ATR_WORKER_SECRET` + cópia no Vault, `ADM_LEITURA_DB_URL`, `KOMMO_TOKEN`, `KOMMO_SUBDOMINIO`; agendar 1×/dia.
