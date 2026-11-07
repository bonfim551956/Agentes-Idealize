-- =============================================================================
-- Idealize AI — agente "Conferência de conversões"  · Migração 20261107070000
-- Pedido do Diego (07/11, PODE FAZER). Os casos "Para conferir" do Agendamento (Visão Ideal) ganham o parecer de um
-- agente que lê a conversa do paciente na Strong Sales (robô só leitura no GitHub Actions) e diz CONFIRMAR, DESCARTAR
-- ou CONFERIR NA MÃO, com o trecho que prova. Ele trabalha no banco do Agendamento; aqui fica o cadastro do agente e o
-- registro de cada rodada (intel.sincronizacoes), para aparecer no painel e no Relatório do dia.
-- Nesta etapa ele NÃO confirma nada: quem decide é a Pré-Vendas.
-- =============================================================================
insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('conversoes', 'Conferência de conversões', 'comercial', 'ativo', '0.1.0',
   'De hora em hora (9h às 19h) lê na Strong Sales a conversa de cada caso "Para conferir" do Agendamento e deixa no card o parecer (confirmar, descartar ou conferir na mão) com o trecho que prova. Não confirma sozinho: quem decide é a Pré-Vendas.')
on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', 'Conferência de conversões', 'conversoes' where not exists (select 1 from core.principais where agente_id = 'conversoes');

-- registro da rodada (chamado pela tarefa agendada do agente)
create or replace function intel.registrar_conversoes(p_resumo jsonb) returns void
language sql security definer set search_path = intel, pg_catalog as $$
  insert into intel.sincronizacoes (agente_id, resumo) values ('conversoes', coalesce(p_resumo, '{}'::jsonb))
$$;
revoke all on function intel.registrar_conversoes(jsonb) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on function intel.registrar_conversoes(jsonb) from anon, authenticated'; end if;
end $$;
