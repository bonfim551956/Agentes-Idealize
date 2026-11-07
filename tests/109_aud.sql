-- Auditoria do atendimento (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into com.usuarios (id, nome) values (9201, 'Operadora Ana Aud'), (9202, 'Operadora Bia Aud') on conflict (id) do nothing;
insert into com.funis (id, nome) values (9210, 'LOJA AUD') on conflict (id) do nothing;
insert into com.etapas (funil_id, id, nome, tipo, ordem) values (9210, 92101, 'Consulta Agendada', 'aberta', 1), (9210, 92102, 'SEM RESPOSTA', 'aberta', 2)
on conflict do nothing;
insert into com.leads (id, funil_id, etapa_id, responsavel_id, valor, criado_em, atualizado_em, hash_origem)
select 920000 + g, 9210, case when g = 1 then 92101 else 92102 end, case when g <= 2 then 9201 else 9202 end, 0, now() - interval '3 days', now(), md5(g::text)
  from generate_series(1, 3) g on conflict (id) do nothing;
insert into com.mensagens (evento_id, entidade_tipo, entidade_id, sentido, usuario_id, em)
select 'aud-' || g || '-' || k, 'lead', 920000 + g, 'atendente', case when g <= 2 then 9201 else 9202 end,
       ((now() at time zone 'America/Sao_Paulo')::date - 1)::timestamp at time zone 'America/Sao_Paulo' + interval '14 hours' + k * interval '1 minute'
  from generate_series(1, 3) g, generate_series(1, 2) k on conflict do nothing;

update core.config set valor = '1' where chave = 'aud.por_operadora_dia';
select t.ok('fila','robô recebe 1 conversa por operadora (a mais movimentada)', (select count(*) from public.aud_fila()) = 2
  and (select count(distinct responsavel_id) from public.aud_fila()) = 2);
update core.config set valor = '8' where chave = 'aud.por_operadora_dia';

select public.aud_receber(920001, (now() at time zone 'America/Sao_Paulo')::date - 1, jsonb_build_array(
  jsonb_build_object('em', '06/11 14:00', 'de', 'cliente', 'autor', 'Cliente', 'texto', 'Olá! Tenho interesse no exame de vista gratuito. Meu número é (13) 99777-1234'),
  jsonb_build_object('em', '06/11 14:01', 'de', 'atendente', 'autor', 'Ana', 'texto', 'Oi, sou a Ana! Qual seu nome? Posso agendar amanhã às 10h?'),
  jsonb_build_object('em', '06/11 14:02', 'de', 'atendente', 'autor', 'Ana', 'texto', '')));
select t.ok('privacidade','telefone sai do texto e mensagem vazia não entra',
  (select jsonb_array_length(mensagens) = 2 and mensagens::text !~ '99777' and primeira_cliente like '%[número]%' from aud.conversas where lead_id = 920001));
select t.ok('fila','conversa lida sai da fila', not exists (select 1 from public.aud_fila() where lead_id = 920001));
select public.aud_receber(920003, (now() at time zone 'America/Sao_Paulo')::date - 1, '[{"de":"cliente","texto":"Quanto custa?"},{"de":"atendente","texto":"R$ 199"}]');

select t.ok('agente','pendentes trazem checklist e conversas', jsonb_array_length(aud.pendentes()->'criterios') = 8 and jsonb_array_length(aud.pendentes()->'conversas') = 2);
select t.ok('agente','nota pelos pesos; "não se aplica" fica fora',
  aud.concluir_avaliacao(920001, '{"saudacao":{"ok":true,"trecho":"sou a Ana"},"tempo":{"ok":true},"necessidade":{"ok":false},"oferta":{"ok":false},"agendamento":{"ok":true,"trecho":"amanhã às 10h"},"objecao":{"ok":null},"confirmacao":{"ok":false},"followup":{"ok":null}}', 'Agendou rápido, mas não entendeu a necessidade.')
  = round(100.0 * (1 + 2 + 3) / (1 + 2 + 2 + 2 + 3 + 2)));
select aud.concluir_avaliacao(920003, '{"saudacao":{"ok":false},"tempo":{"ok":true},"necessidade":{"ok":false},"oferta":{"ok":true},"agendamento":{"ok":false},"confirmacao":{"ok":false}}', 'Só passou o preço, sem agendar.');
select t.erro('agente','avaliação sem resumo é recusada', 'select aud.concluir_avaliacao(920003, ''{}'', ''curto'')', 'resumo');

set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.a', public.painel_auditoria_atendimento(30)::text, false);
select t.ok('painel','por operadora: nota média, critérios e quem agendou',
  (select (x->>'agendou')::int from jsonb_array_elements(current_setting('t.a')::jsonb->'operadoras') x where x->>'nome' = 'Operadora Ana Aud') = 100
  and (select (x->'criterios'->>'agendamento')::int from jsonb_array_elements(current_setting('t.a')::jsonb->'operadoras') x where x->>'nome' = 'Operadora Bia Aud') = 0
  and jsonb_array_length(current_setting('t.a')::jsonb->'faixas') = 2, current_setting('t.a'));
select t.erro('painel','código de critério inválido', 'select public.painel_aud_criterio_salvar(''Com Espaço'', ''Título'', ''Descrição longa o bastante'', 2, 9, true)', 'código do critério');
select public.painel_aud_criterio_salvar('nome_cliente', 'Usa o nome do cliente', 'Chama o cliente pelo nome ao longo da conversa.', 1, 9, true);
select t.ok('painel','critério novo pela tela', exists (select 1 from jsonb_array_elements(public.painel_auditoria_atendimento()->'criterios') x where x->>'id' = 'nome_cliente'));
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('painel','gerente de loja não vê a auditoria da rede', 'select public.painel_auditoria_atendimento()', 'sem permissão');
reset role;
select t.sem_jwt();

select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),120) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DA AUDITORIA FALHANDO'; end if; end $$;
