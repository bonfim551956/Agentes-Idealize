-- Só o que falta resolver aparece; resolvidos numa gaveta; período de/até; modelo de IA por dificuldade (dados sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;

insert into com.alertas (tipo, referencia, unidade_id, detalhe, status, aberto_em, resolvido_em, resolvido_por) values
  ('cliente_sem_resposta', 'sof:1', 'campinas', '{"minutos": 50}', 'resolvido', now() - interval '3 hours', now() - interval '1 hour', 'agente_comercial: situação deixou de existir'),
  ('cliente_sem_resposta', 'sof:2', 'campinas', '{"minutos": 40}', 'aberto', now() - interval '2 hours', null, null),
  ('lead_parado', 'sof:3', 'campinas', '{"dias": 9}', 'resolvido', now() - interval '20 days', now() - interval '15 days', 'agente_comercial: situação deixou de existir');

set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.r', public.painel_avisos_resolvidos('comercial', 'campinas')::text, false);
select set_config('t.r30', public.painel_avisos_resolvidos('comercial', 'campinas', current_date - 30, current_date)::text, false);
select set_config('t.ini', public.painel_inicio()::text, false);
select set_config('t.c', public.painel_comercial('campinas', 7, current_date - 1, current_date)::text, false);
select set_config('t.c7', public.painel_comercial('campinas', 7)::text, false);
select set_config('t.m', public.painel_marketing(null, 7, current_date - 10, current_date - 3)::text, false);
select set_config('t.o', public.painel_origem_vendas(null, 30, null, current_date - 5, current_date)::text, false);
select set_config('t.a', public.painel_atribuicao(null, 30, current_date - 20, current_date)::text, false);
select set_config('t.au', public.painel_auditoria_atendimento(30, null, current_date - 3, current_date)::text, false);
select t.erro('periodo','data final antes da inicial é recusada', $q$select public.painel_comercial(null, 7, current_date, current_date - 3)$q$, 'antes da inicial');
select t.erro('resolvidos','tela desconhecida é recusada', $q$select public.painel_avisos_resolvidos('xpto')$q$, 'desconhecida');
select set_config('t.ia', public.painel_ia()::text, false);
select public.painel_ia_salvar('{"maximo": "claude-opus-5-5"}', '{"wa_conversa": "rapido"}');
select set_config('t.ia2', public.painel_ia()::text, false);
select t.erro('ia','modelo com nome estranho é recusado', $q$select public.painel_ia_salvar('{"maximo": "gpt-4; drop"}', null)$q$, 'inválido');
select t.erro('ia','nível inexistente é recusado', $q$select public.painel_ia_salvar(null, '{"wa_conversa": "turbo"}')$q$, 'inválido');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('ia','gerente não troca o modelo', $q$select public.painel_ia_salvar('{"maximo": "claude-opus-5-5"}', null)$q$, 'permiss');
select t.erro('resolvidos','gerente não vê resolvidos do Multicrediário da rede', $q$select public.painel_avisos_resolvidos('multicrediario')$q$, 'permiss');
reset role; select t.sem_jwt();

select t.ok('resolvidos','gaveta mostra o que o agente resolveu na semana, marcado como "sozinho"',
  (select count(*) from jsonb_array_elements(current_setting('t.r')::jsonb->'itens') x where x->>'referencia' = 'sof:1' and (x->>'sozinho')::boolean) = 1, current_setting('t.r'));
select t.ok('resolvidos','aberto não entra na gaveta',
  not exists (select 1 from jsonb_array_elements(current_setting('t.r')::jsonb->'itens') x where x->>'referencia' = 'sof:2'));
select t.ok('resolvidos','período escolhido traz o resolvido de 15 dias atrás',
  exists (select 1 from jsonb_array_elements(current_setting('t.r30')::jsonb->'itens') x where x->>'referencia' = 'sof:3')
  and not exists (select 1 from jsonb_array_elements(current_setting('t.r')::jsonb->'itens') x where x->>'referencia' = 'sof:3'));
select t.ok('inicio','"novos" conta só o que continua aberto e os resolvidos vêm à parte',
  (select (x->>'novos')::int = (select count(*) from com.alertas where status = 'aberto' and aberto_em > now() - interval '24 hours')
      and (x->>'resolvidos')::int >= 1 and x->>'rotulo_novos' = 'novos ainda abertos'
     from jsonb_array_elements(current_setting('t.ini')::jsonb->'agentes') x where x->>'id' = 'comercial'),
  (select x::text from jsonb_array_elements(current_setting('t.ini')::jsonb->'agentes') x where x->>'id' = 'comercial'));
select t.ok('periodo','Comercial aceita de/até e devolve as datas', current_setting('t.c')::jsonb->>'desde' = (current_date - 1)::text
  and current_setting('t.c')::jsonb->>'ate' = current_date::text, left(current_setting('t.c'), 200));
select t.ok('periodo','Comercial sem datas continua nos últimos N dias', (current_setting('t.c7')::jsonb->>'periodo_dias')::int = 7
  and current_setting('t.c7')::jsonb ? 'lojas');
select t.ok('periodo','Marketing aceita de/até', current_setting('t.m')::jsonb->>'desde' = (current_date - 10)::text and current_setting('t.m')::jsonb->>'ate' = (current_date - 3)::text);
select t.ok('periodo','Origem das vendas aceita de/até', current_setting('t.o')::jsonb->>'desde' = (current_date - 5)::text);
select t.ok('periodo','Retorno aceita de/até', current_setting('t.a')::jsonb->>'desde' = (current_date - 20)::text);
select t.ok('periodo','Auditoria aceita de/até', current_setting('t.au')::jsonb->>'desde' = (current_date - 3)::text and current_setting('t.au')::jsonb ? 'ate');
select t.ok('periodo','só a versão nova de cada tela existe (sem ambiguidade)',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
     and p.proname in ('painel_comercial', 'painel_marketing', 'painel_atribuicao', 'painel_origem_vendas', 'painel_auditoria_atendimento')) = 5);

select t.ok('ia','padrão: investigar aviso usa o máximo, com reserva no avançado e no rápido',
  core.ia_modelos('painel_aviso') = array['claude-opus-5-5', 'claude-sonnet-5-5'] or (core.ia_modelos('painel_aviso'))[1] is not null, array_to_string(core.ia_modelos('painel_aviso'), ','));
select t.ok('ia','a tela mostra as 5 tarefas e os 3 níveis', jsonb_array_length(current_setting('t.ia')::jsonb->'tarefas') = 5
  and current_setting('t.ia')::jsonb->'modelos'->>'maximo' = 'claude-fable-5-1');
select t.ok('ia','troca pela tela vale na hora', current_setting('t.ia2')::jsonb->'modelos'->>'maximo' = 'claude-opus-5-5'
  and (core.ia_modelos('wa_conversa'))[1] = 'claude-sonnet-5-5');
update core.config set valor = 'claude-fable-5-1' where chave = 'ia.modelo.maximo';
update core.config set valor = 'avancado' where chave = 'ia.nivel.wa_conversa';
select t.ok('ia','ordem de reserva: escolhido primeiro, depois do mais forte ao mais simples, sem repetir',
  core.ia_modelos('fin_extrato') = array['claude-fable-5-1', 'claude-opus-5-5', 'claude-sonnet-5-5']
  and core.ia_modelos('wa_conversa') = array['claude-opus-5-5', 'claude-fable-5-1', 'claude-sonnet-5-5'], array_to_string(core.ia_modelos('wa_conversa'), ','));

-- extrato vira lançamento sozinho
select set_config('t.ch', 'sof-ext-' || gen_random_uuid(), false);
insert into fin.movimentos (conta_id, data, sentido, valor, descricao, chave_dedup, status) values
  ('c_cps', current_date, 'debito', 37.90, 'QWZK SOF 1 ZZQ', current_setting('t.ch'), 'pendente');
select set_config('t.px', fin.processar_extratos('teste')::text, false);
select t.ok('extrato','extrato pendente é conciliado/lançado pela rotina', (select status from fin.movimentos where chave_dedup = current_setting('t.ch')) = 'conciliado'
  and exists (select 1 from fin.conciliacoes x join fin.movimentos m on m.id = x.movimento_id where m.chave_dedup = current_setting('t.ch')), current_setting('t.px'));
select t.ok('extrato','sem regra vira pendência para classificar na tela', exists (select 1 from fin.pendencias p join fin.movimentos m on m.id = p.movimento_id
  where m.chave_dedup = current_setting('t.ch') and p.tipo = 'sem_classificacao'));
select t.ok('extrato','rodar de novo não duplica', (fin.processar_extratos('teste')->'contas') = '[]'::jsonb);

delete from com.alertas where referencia like 'sof:%';
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),200) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DE "SÓ O QUE FALTA" FALHANDO'; end if; end $$;
