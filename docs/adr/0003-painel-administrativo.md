# ADR 0003 — Painel administrativo: SPA estática + RPCs no banco

Data: 26/10/2026 · Status: aceito

## Contexto
O Prompt Master (§4.1, §17, §21) pede um painel web para acompanhar agentes, tarefas, incidentes, custos e
pendências, e para aprovar/rejeitar dentro da alçada. A fundação (ADR 0001) já concentra regras, permissões e
auditoria no Postgres, com tabelas fechadas para `anon`/`authenticated`.

## Decisão
- **Front:** SPA React (Vite, Tailwind, Radix, Lucide, Framer Motion) publicada na Vercel como site estático, sem
  servidor próprio e sem nenhum segredo. Usa só a chave publicável do Supabase.
- **Acesso a dados:** exclusivamente por funções `public.painel_*` (SECURITY DEFINER, `search_path` fixo,
  EXECUTE só para `authenticated`). As tabelas `core`/`fin` continuam fechadas.
- **Identidade:** Supabase Auth (e-mail + senha) **com TOTP obrigatório**. Toda função exige `aal2`, exceto
  `painel_eu` (para o front saber que falta o 2FA). O login precisa estar vinculado a um principal humano ativo
  (`core.principais.auth_uid`); desativar o principal corta o acesso na chamada seguinte.
- **Permissão:** a MESMA matriz do core (`core.autorizar`) com o recurso `painel` e escopo por unidade. Linhas
  sem unidade só aparecem para quem tem papel global.
- **Ações:** reutilizam as funções testadas (`core.aprovar` presa ao hash, `core.reconciliar`,
  `fin.decidir_fechamento`…) e gravam auditoria com o ator real. Motivo obrigatório nas ações críticas.
- **Proteções extras:** mascaramento de CPF/telefone/sequências longas, limite de chamadas por minuto com registro
  de acessos (`core.painel_acessos`), sessão em `sessionStorage` com expiração por inatividade (30 min),
  cabeçalhos de segurança (CSP restrita ao domínio do Supabase, `frame-ancestors 'none'`, `noindex`).
- **Auto-proteção:** ninguém altera o próprio acesso pelo painel e as políticas `admin/painel` só mudam por migração.

## Consequências
- Nenhuma regra de negócio no navegador: um front comprometido não ganha mais poder do que o usuário já tem.
- Novos agentes aparecem no painel sem mudança de código (tarefas, custos e incidentes são genéricos).
- Ligar canais externos (WhatsApp etc.) continua sendo mudança revisada no banco, não botão.
