# Evidência — Painel administrativo (v0.5.0): camada de acesso aplicada, painel NÃO publicado

Data: 26/10/2026 · Projeto Supabase Idealize · Decisão do Diego: "PODE FAZER, mas não quero que nada rode por enquanto".

## O que foi feito
- Migração `20261026170000_painel_acesso.sql` aplicada em 3 partes no Supabase
  (`painel_acesso_parte1_base`, `painel_acesso_parte2_leitura`, `painel_acesso_parte3_acoes`), mesmo conteúdo do arquivo
  sem os comentários de topo.
- **Conferência de integridade:** md5 de `pg_get_functiondef` das 41 funções (schema `painel`, `public.painel_*`,
  `fin.decidir_fechamento`) idêntico entre o Supabase e o banco de testes onde a suíte passou.
- Revisão de segurança independente (outro agente, sem ver o raciocínio do autor): 2 altas, 5 médias, 5 baixas —
  todas tratadas antes da aplicação (ver commit "painel: correções da revisão de segurança independente").

## Estado conferido no Supabase (nada rodando, nada exposto)
| Item | Estado |
|---|---|
| Agente financeiro | pausado |
| Canal WhatsApp (`fin.whatsapp.ativo` / `responder`) | false / false |
| Modo seguro (`plataforma_pausada`) | false (sem efeito: agente pausado e fila vazia) |
| Logins vinculados a pessoas | 0 → ninguém consegue usar o painel |
| Funções `painel_*` executáveis por anon | 0 |
| Funções internas (`painel.*`) executáveis por authenticated | 0 |
| pg_cron / pg_net | não instalados |
| Tarefas prontas/executando | 0 |
| Auditoria | cadeia íntegra |
| Advisor de segurança | só o esperado: RLS sem políticas (tabelas fechadas, INFO) e as 27 RPCs `painel_*` para authenticated (desenho do ADR 0003) |

## NÃO feito (por decisão do Diego)
- Publicação na Vercel (o front está pronto em `painel/`, com `vercel.json` e cabeçalhos de segurança).
- Vínculo de login (nenhum usuário no Supabase Auth ainda).

## Testes
324 testes SQL (inclui 100 do painel), concorrência 4×200 sem duplicidade, 11 Deno, 10 de unidade do front e
16 de navegador (computador e celular) — todos passando.

## Para abrir quando decidir
1. [feito] Diego criou o login e ativou o 2FA; publicou o painel na Vercel (projeto `idealize-ai-painel`).
2. Publicar o painel na Vercel (projeto novo).
3. Diego entra e ativa o autenticador; vínculo do login ao principal dele por mudança revisada.
