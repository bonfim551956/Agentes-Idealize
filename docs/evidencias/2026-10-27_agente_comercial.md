# Evidência — Agente Comercial / Kommo v0.1.0 (27/10/2026)

Autorização: "pode fazer" do Diego em 26/10/2026 21:58 (instalar desligado). Mapeamento funil → loja: o Diego define
pela página Comercial depois da primeira leitura.

## Local (Postgres 16)
- `scripts/test.sh`: 400 testes SQL PASS / 0 FAIL (inclui `tests/80_com.sql`), Deno lab-sync 5/5, kommo-sync 8/8.
- Painel: 18/18 Playwright (inclui "comercial mostra quem espera resposta e define a loja de um funil").
- Correção achada pelo teste: lote sem `desde/ate` passava pela checagem (null !~ regex) — agora recusado inteiro.

## Supabase Idealize (upkxaovgutzgackexhax)
- Migração `com_agente_kommo` aplicada (1ª tentativa: "Invalid or expired requestState", nada aplicado; 2ª: ok).
- Funções `com.*` e `painel_comercial*`: md5 idêntico ao banco de teste em 7 de 10; as outras 3 diferem só por
  comentários (md5 sem comentários/espaços idêntico).
- Travas conferidas: agente `pausado`, `com.sync.ativo = false`, 4 políticas proibidas (enviar_mensagem,
  alterar_lead, criar_lead, excluir), RLS forçada em todas as tabelas `com`, `anon` sem acesso a `painel_comercial`.
- Edge function `kommo-sync` v1 publicada (verify_jwt=false, autenticação própria): sem `COM_WORKER_SECRET` responde
  503; com o segredo, ainda retorna "desligado" enquanto `com.sync.ativo` = false.
- Advisors: só os avisos já conhecidos (RLS sem políticas por desenho; RPCs do painel com checagem interna).

## Para ligar (só com "PODE LIGAR O COMERCIAL")
1. Diego cria `COM_WORKER_SECRET` em Edge Functions → Secrets.
2. Agendar chamada a cada 15 min; ativar agente `comercial` e `com.sync.ativo = true`.
3. Primeira leitura cobre os últimos 30 dias em janelas de até 3 dias; conferir o token na primeira execução.
