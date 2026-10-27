# Evidência — Agente Supervisor v0.1.0 (27/10/2026)

Autorização: "PODE FAZER QUERO MEU ESCRITÓRIO DIGITAL A PROVA DE ERROS" do Diego, 27/10/2026.

## O que faz (a cada hora, quando ligado)
Saúde de cada agente (leu no prazo? ligado pela metade?), conferência reprovada pelo validador (o core não abria
incidente nesse caso), tarefa presa (feita e não conferida, travada, fila parada), incidentes abertos, aprovação
parada, custo perto do limite, integração com problema, modo seguro ligado, auditoria (refaz a cadeia de hash; se
adulterada → CRÍTICO + liga o modo seguro sozinho), conferência por amostragem na FONTE (Asaas, Kommo, ADM/laboratório:
separa "mudou depois da leitura" de diferença real; falha de leitura da fonte também vira aviso).
Avisos pelo WhatsApp (Z-API): urgente na hora para o grave ainda não avisado (repete se a gravidade subir) e resumo
às 7h, 12h e 18h, só para pessoas com papel admin e telefone cadastrado. Texto sem dado pessoal (o validador reprova
e segura o aviso se achar telefone, CPF ou e-mail).

## Travas
Agente `pausado`, `sup.sync.ativo = false`, `sup.enviar = false` (modo sombra: registra o aviso e não envia).
Proibido: desligar o modo seguro, alterar agente/política/dados, apagar auditoria, excluir, mandar para terceiros.
Permitido: verificar, avisar e LIGAR o modo seguro. Roda como monitoramento (continua com o modo seguro ligado).

## Local
`scripts/test.sh`: 623 testes SQL PASS / 0 FAIL (61 do Supervisor em `tests/100_sup.sql`), Deno supervisor-sync 7/7,
ciclo ponta a ponta da função contra o Postgres local (fonte fora do ar vira aviso, não derruba). Painel 27/27.

## Supabase Idealize
Pendente: a aplicação da migração foi cancelada em 27/10 e nada foi aplicado (conferido: schema `sup` inexistente).
