# Painel administrativo — Idealize AI

SPA estática (React + Vite + Tailwind + Radix + Lucide + Framer Motion). Fala com o Supabase **só** pelas funções
`public.painel_*` (migração `20261026170000_painel_acesso.sql`). Decisão registrada em `docs/adr/0003-painel-administrativo.md`.

## Rodar
```bash
cp .env.example .env.local   # URL e chave PUBLICÁVEL do Supabase (nunca a service_role)
npm install
npm run dev
```

## Testes
```bash
npm test            # unidade (vitest)
npx playwright test # navegador, com Supabase simulado (tests/mock.ts) — computador e celular
```
Os testes de banco da camada de acesso estão em `tests/60_painel.sql` (rodam em `scripts/test.sh`).

## Dar acesso a uma pessoa
1. Supabase → Authentication → Add user (e-mail + senha, confirmado). Deixe **desligado** o cadastro público.
2. No painel (admin): Pessoas e permissões → Vincular login. No primeiro acesso a pessoa cadastra o autenticador (TOTP).
3. Dê o papel e a unidade. Sem papel, a pessoa não vê nada.

## Telas
Visão geral (estado + o que precisa de decisão) · Aprovações · Tarefas e detalhe · Incidentes · Pendências financeiras ·
Financeiro por loja (DRE, caixa, fechamento) · Agentes · Custos de IA · Histórico auditado · Operação e integrações ·
Pessoas e permissões.
