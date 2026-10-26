# Diagnóstico do ambiente — Idealize AI

Data: 26/10/2026 · Método: inspeção somente leitura via MCP (Supabase × 3 orgs, Vercel, GitHub). Nenhuma alteração foi feita nos sistemas.

## 1. Estado atual

| Ativo | Onde | Situação |
|---|---|---|
| **Sistema ADM** | Supabase `<ref omitido>` (sa-east-1, PG 17) | Ativo. Hospeda o Finance AI (schema `finance`), a central de WhatsApp (`central`), follow-up pós-venda, OS do laboratório, estoque, crediário, fechamento de caixa. 5 jobs `pg_cron`. |
| **Finance AI (atual)** | Edge functions `finance-webhook` (v5) e `finance-worker` (v7) + schema `finance` | **Em produção desde out/2026.** 133 lançamentos (01–23/10), 104 confirmados = R$ 122.734,64; 132 de São Vicente, 1 administrativo. 92 turnos ok, 2 com erro. |
| idealize-RH | Supabase `<ref omitido>` | Ativo (RH 360). |
| pdv-idealize | Supabase `<ref omitido>` | Ativo (PDV). |
| metas | Supabase `<ref omitido>` | Ativo. |
| Plataforma Idealize 360 | Supabase `<ref omitido>` | **Inativo (pausado).** |
| Front-ends | Vercel, 33 projetos (pdv, idealize-rh, labs por loja, painel-meta-ads, painel-automacoes…) | Ativos. |
| Código | GitHub `bonfim551956` — 7 repositórios **públicos** | Não há repositório do Finance AI nem da plataforma; o código vive só nas edge functions. |

## 2. O que já existe e será reaproveitado (não recriar)

O Finance AI atual é bem construído e já implementa vários requisitos do prompt:

- **Fila persistente com turnos** (`finance.turnos`, `reivindicar_turno`, `concluir_turno`), retentativa e reenvio de respostas que falharam.
- **Idempotência de mídia**: SHA-256 do arquivo, `on conflict (mensagem_id) do nothing`, path por hash.
- **Separação documento × texto do usuário** na interpretação, com pergunta quando divergem (exatamente a regra 9.2).
- **Lógica financeira determinística no Postgres** (`finance.executar_turno`); a IA só interpreta.
- **Defesa contra prompt injection** (regra 10 do prompt do modelo), validação real do tipo de arquivo pelos bytes, allowlist de hosts de mídia, limite de tamanho.
- **Segredos no Vault** (`finance.segredo()`), comparação de chave em tempo constante no worker.
- **Usuários por telefone com permissões** (`consulta/lancamento/correcao/cancelamento/admin`) e escopo de unidade; convite com código de 6 dígitos com hash e expiração; números desconhecidos nunca chamam a IA.
- **Auditoria** com antes/depois (`finance.auditoria`), pendências, regras de favorecido aprendidas, grupos por unidade.

## 3. O que falta (lacunas frente ao prompt)

| Requisito | Situação |
|---|---|
| Orquestrador/motor reutilizável por vários agentes | Não existe — o motor é específico do financeiro. **→ construído nesta etapa (`core`).** |
| Matriz de alçadas versionada, aprovação de 2 pessoas, aprovação presa à operação | Não existe. **→ construído (`core`).** |
| Validador independente separado do executor | Não existe. **→ construído (mecanismo); validador financeiro é a Etapa E.** |
| Auditoria imutável | `finance.auditoria` aceita UPDATE/DELETE (tem coluna `revertido_em`). **→ `core.auditoria` append-only com cadeia de hash.** |
| Estado "incerta" + reconciliação | Não existe (turno com erro é retentado). **→ construído.** |
| Incidentes, custos com limite, kill switch | Não existem. **→ construídos.** |
| Modelo financeiro (receita, transferência, rateio, cartão×fatura, conciliado/contestado) | Só `entrada/saida` e `pendente/confirmado/cancelado/duplicado`; e o robô está configurado **só para saídas**. → Etapa D. |
| Importação de extrato e conciliação | Não existe. → Etapa D. |
| Fluxo de caixa realizado × previsto, fechamento com aprovação | Não existe. → Etapa D. |
| Painel administrativo | Não existe para o Finance AI. → após Etapa D. |
| Código versionado em Git, CI, homologação separada | Não existe. → precisa de decisão (seção 8). |

## 4. Riscos encontrados

Os riscos de segurança dos sistemas existentes (1 crítico, 2 altos, 2 médios, 1 baixo) estão no
documento interno do diagnóstico, **fora deste repositório**, para não publicar detalhes exploráveis.
Resumo não sensível: há dados de clientes no sistema legado que precisam de controle de acesso
reforçado; o código do agente financeiro legado não estava versionado; não há ambiente de homologação
separado; o canal de WhatsApp usa API não oficial (decisão consciente, mitigada por adaptador isolado).

## 5. Integrações

| Integração | Estado |
|---|---|
| Z-API, Claude API | Em uso e funcionando no Finance AI (verificado pelos turnos concluídos). |
| Whisper (transcrição) | Código existe; não verifiquei se a chave está cadastrada. |
| ACERT, Kommo, Sicredi, Stone, Asaas, Multicrédito, Braslab/WebPedidos | **Não verificadas.** Nenhuma API confirmada; extratos entram por arquivo. Cadastradas em `core.integracoes` como `nao_verificada`, escrita desabilitada. |

## 6. Plano priorizado

| Etapa | Entregável | Estado |
|---|---|---|
| A | Diagnóstico | **Concluída** |
| B | Fundação `core` (migração versionada) | **Concluída localmente** |
| C | Testes da fundação | **78/78 + concorrência, executados** |
| C′ | Aplicar `core` num **branch** do Supabase ADM e repetir os testes lá | Aguarda "PODE FAZER" |
| D1 | Modelo financeiro completo (natureza do lançamento, contas, transferências, rateio, cartão/fatura) em `finance`, por *expand/contract* sem quebrar o robô atual | Próxima |
| D2 | Importação de extrato (OFX/CSV Sicredi) + conciliação comprovante × extrato | |
| D3 | Fluxo de caixa realizado/previsto e pacote de fechamento | |
| E | Validador financeiro independente (recalcula pelo extrato) | |
| F | Homologação: modo observação com dados reais de SV | Aguarda autorização |
| G | Painel + liberação gradual | Aguarda autorização |

## 7. Testes necessários (próximas etapas)
Todos os cenários financeiros do item 19 do prompt — já mapeados em `STATUS.md` como critérios das etapas D/E.

## 8. Decisões que dependem de você
1. **"PODE FAZER" para aplicar a fundação** num branch do Supabase ADM (custo de branch é cobrado por hora) **ou** num projeto Supabase novo e dedicado à Idealize AI.
2. **Onde versionar o código**: criar repositório **privado** `idealize-ai` no seu GitHub.
3. **Controle de acesso do sistema legado**: ver documento interno.
4. **Escopo de entradas**: hoje o robô registra só saídas, por decisão sua. Fluxo de caixa e conciliação completos precisam das entradas (Stone, PIX, Asaas). Entram via **importação de extrato** (não pelo grupo) — confirmar.
