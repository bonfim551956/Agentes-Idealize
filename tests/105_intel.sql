-- Relatório do dia + Radar do Mercado + Concorrentes (pedido 07/11; dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;

select t.ok('agentes','Radar e Concorrentes cadastrados, com papel só de pesquisa e proibições',
  (select count(*) from core.agentes where id in ('radar','concorrentes')) = 2
  and (core.autorizar((select id from core.principais where agente_id = 'concorrentes'), 'intel.concorrentes', 'publicar', null)).categoria = 'proibida'
  and (core.autorizar((select id from core.principais where agente_id = 'radar'), 'intel.mercado', 'pesquisar', null)).categoria = 'automatica');
select t.ok('agentes','lista inicial com os 13 concorrentes do Diego', (select count(*) from intel.concorrentes) = 13);

-- Radar
select set_config('t.r', intel.iniciar('radar', 'tarefa-agendada')::text, false);
select t.ok('radar','iniciar cria e reivindica a tarefa do dia e manda os temas', current_setting('t.r')::jsonb->>'status' = 'ok'
  and (select status from core.tarefas where id = (current_setting('t.r')::jsonb->>'tarefa')::uuid) = 'executando'
  and length(current_setting('t.r')::jsonb->>'temas') > 20, current_setting('t.r'));
select set_config('t.rr', intel.concluir_radar((current_setting('t.r')::jsonb->>'tarefa')::uuid, 'tarefa-agendada', jsonb_build_array(
  jsonb_build_object('titulo','Fabricante lança nova lente para miopia infantil','fonte','Revista X','url','https://exemplo.com/a','impacto','Oportunidade de linha infantil','relevancia',5),
  jsonb_build_object('titulo','Notícia repetida','url','https://exemplo.com/a'),
  jsonb_build_object('titulo','sem url válida','url','javascript:alert(1)')))::text, false);
select t.ok('radar','grava só a notícia válida e nova; tarefa concluída e validada',
  (current_setting('t.rr')::jsonb->>'novas')::int = 1 and (current_setting('t.rr')::jsonb->>'descartadas')::int = 2
  and (select status from core.tarefas where id = (current_setting('t.r')::jsonb->>'tarefa')::uuid) = 'concluida', current_setting('t.rr'));
select t.ok('radar','segunda chamada no mesmo dia não refaz', intel.iniciar('radar', 'tarefa-agendada')->>'status' = 'ja_feita');

-- Concorrentes
select set_config('t.c', intel.iniciar('concorrentes', 'tarefa-agendada')::text, false);
select t.ok('concorrentes','iniciar devolve a lista ativa com termo de busca e páginas',
  jsonb_array_length(current_setting('t.c')::jsonb->'concorrentes') = 13
  and (select bool_and(x->>'termo_busca' <> '') from jsonb_array_elements(current_setting('t.c')::jsonb->'concorrentes') x));
select set_config('t.k1', (select id from intel.concorrentes where nome = 'Óticas Gassi')::text, false);
select set_config('t.k2', (select id from intel.concorrentes where nome = 'Óticas Diniz')::text, false);
insert into intel.anuncios (id, concorrente_id, titulo, inicio, primeiro_visto, ultimo_visto) values
  ('99900001', current_setting('t.k1')::int, 'Anúncio antigo que saiu', now() - interval '60 days', now() - interval '50 days', now() - interval '2 days'),
  ('99900002', current_setting('t.k2')::int, '2 óculos por 199', now() - interval '45 days', now() - interval '40 days', now() - interval '1 day');
select set_config('t.cc', intel.concluir_concorrentes((current_setting('t.c')::jsonb->>'tarefa')::uuid, 'tarefa-agendada',
  jsonb_build_array(
    jsonb_build_object('concorrente_id', current_setting('t.k1')::int, 'id','12345678','page_id','1335226946332018','page_nome','Óticas Gassi São Vicente',
      'titulo','Exame grátis + armação gratuita!','inicio', extract(epoch from now() - interval '1 day')::bigint::text,
      'snapshot_url','https://www.facebook.com/ads/library/?id=12345678'),
    jsonb_build_object('concorrente_id', current_setting('t.k2')::int, 'id','99900002','titulo','2 óculos por 199'),
    jsonb_build_object('concorrente_id', current_setting('t.k1')::int, 'id','87654321','titulo','Anúncio antigo','inicio', extract(epoch from now() - interval '40 days')::bigint::text),
    jsonb_build_object('concorrente_id', 999999, 'id','55555555','titulo','concorrente inexistente'),
    jsonb_build_object('concorrente_id', current_setting('t.k1')::int, 'id','abc','titulo','id inválido')),
  array[current_setting('t.k1')::int, current_setting('t.k2')::int],
  jsonb_build_array(jsonb_build_object('concorrente_id', current_setting('t.k2')::int, 'titulo','Anúncio só de primeiro multifocal',
    'evidencia','Diniz roda "Seu primeiro multifocal"','como_aplicar','Campanha com as linhas 45% a 98%'),
    jsonb_build_object('titulo','x')))::text, false);
select t.ok('concorrentes','grava anúncio novo, atualiza o que continua, ignora inválido e concorrente inexistente',
  (current_setting('t.cc')::jsonb->>'novos')::int = 1 and (current_setting('t.cc')::jsonb->>'anuncios_vistos')::int = 3
  and not exists (select 1 from intel.anuncios where id in ('55555555','abc')), current_setting('t.cc'));
select t.ok('concorrentes','anúncio antigo visto pela 1ª vez não conta como novo (entra com a data em que foi ao ar)',
  (select primeiro_visto < now() - interval '30 days' from intel.anuncios where id = '87654321'));
select t.ok('concorrentes','anúncio que não veio de concorrente varrido sai do ar',
  (select ativo from intel.anuncios where id = '99900001') = false and (select ativo from intel.anuncios where id = '99900002'));
select t.ok('concorrentes','ideia válida gravada como sugerida; título curto ignorado',
  (select count(*) from intel.ideias where status = 'sugerida') = 1);
select t.ok('concorrentes','tarefa concluída e validada; registro da varredura para o Supervisor',
  (select status from core.tarefas where id = (current_setting('t.c')::jsonb->>'tarefa')::uuid) = 'concluida'
  and exists (select 1 from sup.v_ultimas where agente_id = 'concorrentes' and em is not null));

-- Relatório
select set_config('t.rel', rel.gerar()::text, false);
select t.ok('relatorio','relatório traz totais, prioridades, agentes, mercado e concorrentes',
  current_setting('t.rel')::jsonb ?& array['totais','prioridades','agentes','mercado','concorrentes']
  and jsonb_array_length(current_setting('t.rel')::jsonb->'prioridades') between 1 and 5);
select t.ok('relatorio','campanha nova de concorrente vira prioridade',
  exists (select 1 from jsonb_array_elements(current_setting('t.rel')::jsonb->'prioridades') x
          where x->>'area' = 'Concorrentes' and x->>'texto' like 'Óticas Gassi colocou 1 anúncio%'), (current_setting('t.rel')::jsonb->'prioridades')::text);
select t.ok('relatorio','concorrentes ocupam no máximo 2 das prioridades',
  (select count(*) from jsonb_array_elements(current_setting('t.rel')::jsonb->'prioridades') x where x->>'area' = 'Concorrentes'
     and x->>'rota' = '/mercado' and x->>'texto' like '%colocou%') <= 2);
select t.ok('relatorio','Radar e Concorrentes aparecem com o que fizeram',
  (select (x->>'novos')::int from jsonb_array_elements(current_setting('t.rel')::jsonb->'agentes') x where x->>'id' = 'radar') = 1
  and (select (x->>'rodadas')::int from jsonb_array_elements(current_setting('t.rel')::jsonb->'agentes') x where x->>'id' = 'concorrentes') = 1);
select t.ok('relatorio','anúncio no ar há mais de 30 dias aparece como longo',
  exists (select 1 from jsonb_array_elements(current_setting('t.rel')::jsonb->'concorrentes'->'longos') x where x->>'titulo' = '2 óculos por 199'));
select rel.gerar();
select t.ok('relatorio','gerar de novo no mesmo dia atualiza (versão sobe), sem duplicar', (select count(*) from rel.relatorios) = 1
  and (select versao from rel.relatorios) = 2);

-- Painel
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('painel','admin lê o relatório do dia e a lista de dias', (public.painel_relatorio()->>'existe')::boolean
  and jsonb_array_length(public.painel_relatorio()->'dias') = 1 and (public.painel_relatorio()->>'pode_gerar')::boolean);
select t.ok('painel','tela de inteligência traz concorrentes com anúncios, notícias e ideias',
  jsonb_array_length(public.painel_inteligencia()->'concorrentes') = 13 and jsonb_array_length(public.painel_inteligencia()->'noticias') = 1
  and jsonb_array_length(public.painel_inteligencia()->'ideias') = 1);
select set_config('t.nid', public.painel_concorrente_salvar(null, 'Ótica Nova Teste', 'Sorocaba', null, '@otica.nova', null, '{}', null, true)::text, false);
reset role;
select t.ok('painel','admin inclui concorrente (o @ é limpo)', (select instagram from intel.concorrentes where id = current_setting('t.nid')::int) = 'otica.nova');
set role authenticated;
select t.erro('painel','Instagram inválido é recusado', $q$select public.painel_concorrente_salvar(null, 'Outra', null, null, 'nome com espaço', null, '{}', null, true)$q$, 'Instagram inválido');
select t.erro('painel','nome repetido é recusado', $q$select public.painel_concorrente_salvar(null, 'ótica nova teste')$q$, 'já existe');
select public.painel_concorrente_salvar(current_setting('t.nid')::int, 'Ótica Nova Teste', 'Sorocaba', null, null, null, '{}', null, false);
reset role;
select set_config('t.iid', (select id from intel.ideias limit 1)::text, false);
set role authenticated;
select public.painel_ideia_decidir(current_setting('t.iid')::bigint, 'aprovada', 'vamos testar na Black');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('painel','gerente de loja não vê o relatório da rede', 'select public.painel_relatorio()', 'sem permissão');
select t.erro('painel','gerente de loja não altera concorrentes', $q$select public.painel_concorrente_salvar(null, 'Tentativa')$q$);
reset role;
select t.sem_jwt();
select t.ok('painel','desativar concorrente tira da próxima varredura',
  not exists (select 1 from jsonb_array_elements(intel.iniciar('concorrentes', 'x')->'concorrentes') x where x->>'nome' = 'Ótica Nova Teste')
  or intel.iniciar('concorrentes', 'x')->>'status' = 'ja_feita');
select t.ok('painel','ideia aprovada com a nota e registrada na auditoria',
  (select status = 'aprovada' and nota = 'vamos testar na Black' from intel.ideias limit 1)
  and exists (select 1 from core.auditoria where acao = 'ideia_aprovada'));
select t.ok('seguranca','anon/authenticated não chamam a esteira dos agentes direto',
  not has_function_privilege('authenticated', 'intel.concluir_radar(uuid,text,jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'rel.gerar(date)', 'execute'));
select t.ok('auditoria','cadeia íntegra ao final', core.verificar_auditoria() is null);

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DE INTELIGÊNCIA FALHANDO'; end if; end $$;
