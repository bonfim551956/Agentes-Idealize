# Evidência — Teste da chave do Asaas (27/10/2026)

Autorização: "pode fazer" do Diego (opção "Testar a chave"), 27/10/2026.

- Edge function `asaas-teste` v1 (`supabase/functions/asaas-teste/`): só GET em `/v3/payments?status=X&limit=1`, lê apenas
  o `totalCount`; devolve contagens, sem nome, CPF, valor ou id. Só responde enquanto `core.config 'asaas.teste_ate'` estiver no futuro.
- Janela aberta por 15 min, uma chamada (navegador do app), janela encerrada logo depois: agora responde 403 "teste encerrado".
- Resultado: `ASAAS_TOKENS` existe, 1 linha no formato certo (`sao_vicente=…`), chave de **produção** aceita (HTTP 200).
  São Vicente no Asaas: 147 pendentes, 229 vencidas, 729 recebidas, 249 confirmadas (contagem total da conta).
- `core.integracoes.asaas` → `ok`. Agentes de Caixa e Cobranças continuam `pausado`, `cx.sync.ativo` e `cob.sync.ativo` = false.
- Nada do Asaas foi gravado no banco.
