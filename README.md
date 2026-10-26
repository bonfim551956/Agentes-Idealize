# Agentes Idealize — plataforma Idealize AI

Plataforma central de agentes de IA das Óticas Idealize: orquestrador, fila de tarefas, alçadas de aprovação,
validação independente, auditoria imutável, incidentes e custos — reutilizáveis por todos os agentes.
Primeiro agente: financeiro.

- **Estado e próximos passos:** [`STATUS.md`](STATUS.md)
- **Diagnóstico do ambiente:** [`docs/DIAGNOSTICO.md`](docs/DIAGNOSTICO.md)
- **Decisões de arquitetura:** [`docs/adr/`](docs/adr)
- **Evidências de teste:** [`docs/evidencias/`](docs/evidencias)

## Estrutura
```
supabase/migrations/   migrações versionadas (aplicadas em ordem)
tests/                 suíte SQL (dados sintéticos) + teste de concorrência
scripts/test.sh        recria banco descartável, aplica migrações, roda tudo
docs/                  diagnóstico, ADRs, evidências
```

## Rodar os testes (PostgreSQL 16+ local)
```bash
PGHOST=/caminho/do/socket PGPORT=5432 ./scripts/test.sh
```
Nunca aponte o script para um banco de produção: ele faz `dropdb`/`createdb` de `idealize_ai_test`.

## Regras do projeto
- Nenhum segredo no repositório. Credenciais ficam no Vault do Supabase e são referenciadas pelo nome.
- Nada vai para produção sem aprovação explícita do Diego.
- Teste escrito não é teste executado; mock não é integração validada.
