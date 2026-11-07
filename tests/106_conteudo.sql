-- Agentes de Conteúdo: Ideias → Avaliador → Roteirista + tela Conteúdo (pedido 07/11; dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;

select t.ok('agentes','três agentes de conteúdo cadastrados, só criam aqui e não publicam nem contatam',
  (select count(*) from core.agentes where id like 'conteudo\_%') = 3
  and (core.autorizar((select id from core.principais where agente_id = 'conteudo_roteirista'), 'cont.conteudo', 'publicar', null)).categoria = 'proibida'
  and (core.autorizar((select id from core.principais where agente_id = 'conteudo_ideias'), 'cont.conteudo', 'criar', null)).categoria = 'automatica');
select t.ok('agentes','Supervisor vigia os três', (select count(*) from sup.limites where agente_id like 'conteudo\_%') = 3);

-- ordem: Avaliador e Roteirista esperam o de Ideias
select t.ok('ordem','Avaliador sem ideias do dia aguarda, sem criar tarefa', cont.iniciar('avaliador', 'x')->>'status' = 'aguardando'
  and not exists (select 1 from core.tarefas where agente_id = 'conteudo_avaliador'));

-- Ideias
select set_config('t.i', cont.iniciar('ideias', 'tarefa-agendada')::text, false);
select t.ok('ideias','iniciar manda regras, aprendizado, concorrentes que funcionam e lojas',
  current_setting('t.i')::jsonb->>'status' = 'ok'
  and current_setting('t.i')::jsonb ?& array['regras','aprendizado','concorrentes_longos','noticias','unidades','ja_propostas']
  and (current_setting('t.i')::jsonb->'regras'->>'nota_minima')::int = 75, left(current_setting('t.i'), 200));
select set_config('t.ir', cont.concluir_ideias((current_setting('t.i')::jsonb->>'tarefa')::uuid, 'tarefa-agendada', (
  select jsonb_agg(jsonb_build_object('titulo', 'Ideia de teste número ' || g, 'formato', 'reel', 'unidade_id', case when g = 1 then 'sao_vicente' end,
    'gancho', 'Gancho forte ' || g, 'conceito', 'Conceito', 'evidencia', 'Santês 53 dias', 'fonte', 'concorrentes')) from generate_series(1, 6) g)
  || jsonb_build_array(jsonb_build_object('titulo', 'Sem gancho'), jsonb_build_object('titulo', 'Carrossel fora das regras', 'formato', 'carrossel', 'gancho', 'Gancho ok'),
     jsonb_build_object('titulo', 'Ideia de teste número 1', 'gancho', 'repetida')))::text, false);
select t.ok('ideias','grava as válidas; recusa sem gancho, formato fora das regras e repetida; tarefa validada',
  (current_setting('t.ir')::jsonb->>'ideias')::int = 6 and (current_setting('t.ir')::jsonb->>'recusadas')::int = 3
  and (select status from core.tarefas where id = (current_setting('t.i')::jsonb->>'tarefa')::uuid) = 'concluida', current_setting('t.ir'));
select t.ok('ideias','segunda chamada no mesmo dia não refaz', cont.iniciar('ideias', 'x')->>'status' = 'ja_feita');

-- Avaliador: a aprovação é do banco (top N acima da nota mínima)
select set_config('t.a', cont.iniciar('avaliador', 'tarefa-agendada')::text, false);
select t.ok('avaliador','recebe as 6 ideias novas do dia', jsonb_array_length(current_setting('t.a')::jsonb->'ideias') = 6);
select set_config('t.ar', cont.concluir_avaliacao((current_setting('t.a')::jsonb->>'tarefa')::uuid, 'tarefa-agendada', (
  select jsonb_agg(jsonb_build_object('ideia_id', id, 'parecer', 'parecer ' || id, 'criterios', jsonb_build_object(
    'gancho', case rn when 1 then 19 when 2 then 18 when 3 then 17 when 4 then 16 else 10 end, 'prova', 18, 'oferta', 20,
    'gravacao', 17, 'marca', case when rn = 1 then 99 else 17 end)))
  from (select id, row_number() over (order by id) rn from cont.ideias) q))::text, false);
select t.ok('avaliador','as 3 maiores notas acima de 75 passam; resto descartado com parecer; critério acima de 20 é limitado',
  (current_setting('t.ar')::jsonb->>'aprovadas')::int = 3
  and (select count(*) from cont.ideias where status = 'descartada' and parecer is not null) = 3
  and (select max(nota) from cont.ideias) = 94
  and (select status from core.tarefas where id = (current_setting('t.a')::jsonb->>'tarefa')::uuid) = 'concluida', current_setting('t.ar'));
select t.ok('avaliador','nota 88 acima da mínima mas fora das 3 melhores fica de fora',
  (select status from cont.ideias where nota = 88) = 'descartada');

-- Roteirista
select set_config('t.r', cont.iniciar('roteirista', 'tarefa-agendada')::text, false);
select t.ok('roteirista','recebe as 3 aprovadas, regras e aprendizado', jsonb_array_length(current_setting('t.r')::jsonb->'ideias') = 3
  and current_setting('t.r')::jsonb ? 'regras' and current_setting('t.r')::jsonb ? 'exemplos_aprovados');
select set_config('t.cenas', jsonb_build_array(
  jsonb_build_object('tempo','0-3s','tipo','gancho','aparece','Close na influencer','fala','Dois óculos por 199? Eu também duvidei.','tela','2 ÓCULOS R$ 199,90'),
  jsonb_build_object('tempo','3-12s','tipo','prova','aparece','Etiqueta','fala','Fui conferir.','tela','Você escolhe as 2'),
  jsonb_build_object('tempo','12-25s','tipo','cta','aparece','Aponta para baixo','fala','Chama no WhatsApp.','tela','Chama no WhatsApp'))::text, false);
select set_config('t.rr', cont.concluir_roteiros((current_setting('t.r')::jsonb->>'tarefa')::uuid, 'tarefa-agendada', (
  select jsonb_agg(jsonb_build_object('ideia_id', x->>'id', 'titulo', 'Roteiro ' || (x->>'titulo'), 'duracao_s', 25,
    'gancho', 'Dois óculos por 199? Eu também duvidei.', 'cenas', current_setting('t.cenas')::jsonb, 'capa', 'É PEGADINHA?',
    'trilha', 'em alta', 'legenda', 'Legenda', 'cta', 'Chama no WhatsApp'))
  from jsonb_array_elements(current_setting('t.r')::jsonb->'ideias') x)
  || jsonb_build_array(
    jsonb_build_object('ideia_id', (select id from cont.ideias where status = 'descartada' limit 1), 'titulo', 'Roteiro de ideia reprovada',
      'gancho', 'Gancho qualquer', 'cenas', current_setting('t.cenas')::jsonb),
    jsonb_build_object('ideia_id', (current_setting('t.r')::jsonb->'ideias'->0->>'id'), 'titulo', 'Roteiro curto demais', 'gancho', 'Gancho',
      'cenas', jsonb_build_array(jsonb_build_object('aparece','x','fala','y')))))::text, false);
select t.ok('roteirista','3 roteiros gravados; recusa ideia não aprovada e roteiro com menos de 3 cenas; validado',
  (current_setting('t.rr')::jsonb->>'roteiros')::int = 3 and (current_setting('t.rr')::jsonb->>'recusados')::int = 2
  and (select count(*) from cont.roteiros where status = 'pronto') = 3
  and (select status from core.tarefas where id = (current_setting('t.r')::jsonb->>'tarefa')::uuid) = 'concluida', current_setting('t.rr'));
select t.ok('roteirista','roteiro herda a loja da ideia', exists (select 1 from cont.roteiros where unidade_id = 'sao_vicente'));
select t.ok('roteirista','rodada de ajustes sem pedido não cria tarefa', cont.iniciar('roteirista', 'x', 'ajustes')->>'status' = 'nada_a_fazer');

-- Relatório
select set_config('t.rel', rel.gerar()::text, false);
select t.ok('relatorio','roteiros prontos aparecem no relatório (seção própria e no card do Roteirista)',
  jsonb_array_length(current_setting('t.rel')::jsonb->'conteudo') = 3
  and (select (x->>'abertos')::int from jsonb_array_elements(current_setting('t.rel')::jsonb->'agentes') x where x->>'id' = 'conteudo_roteirista') = 3);

-- Painel
select set_config('t.rid', (select min(id) from cont.roteiros)::text, false);
select set_config('t.rid2', (select max(id) from cont.roteiros)::text, false);
select set_config('t.desc', (select min(id) from cont.ideias where status = 'descartada')::text, false);
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('painel','tela traz roteiros com nota do Avaliador, ideias do dia, agentes e regras',
  jsonb_array_length(public.painel_conteudo()->'roteiros') = 3 and jsonb_array_length(public.painel_conteudo()->'ideias') = 6
  and jsonb_array_length(public.painel_conteudo()->'agentes') = 3 and (public.painel_conteudo()->'roteiros'->0->>'nota') is not null
  and (public.painel_conteudo()->>'pode_editar')::boolean);
select t.erro('painel','pedir ajuste exige dizer o que mudar', format('select public.painel_roteiro_decidir(%s, %L)', current_setting('t.rid'), 'ajuste'), 'escreva o que precisa mudar');
select t.erro('painel','não marca gravado sem aprovar', format('select public.painel_roteiro_decidir(%s, %L)', current_setting('t.rid'), 'gravado'), 'aprove o roteiro');
select public.painel_roteiro_decidir(current_setting('t.rid2')::bigint, 'aprovar', 'ótimo gancho');
select public.painel_roteiro_decidir(current_setting('t.rid2')::bigint, 'publicado', null, 'https://instagram.com/reel/abc', 'SV – Reel 2 óculos');
select public.painel_roteiro_decidir(current_setting('t.rid')::bigint, 'ajuste', 'Troque o gancho: comece pela etiqueta');
select public.painel_ideia_conteudo_promover(current_setting('t.desc')::bigint);
select t.erro('painel','regra fora da faixa é recusada', $q$select public.painel_conteudo_regras_salvar('{"nota_minima": 30}')$q$, 'nota mínima');
select t.erro('painel','formato desconhecido é recusado', $q$select public.painel_conteudo_regras_salvar('{"formatos": ["reel","tiktok"]}')$q$, 'formatos');
select public.painel_conteudo_regras_salvar('{"roteiros_por_dia": 5, "formatos": ["reel","carrossel"], "foco": "Natal e 13º salário"}', 'teste');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('painel','gerente de loja não vê o conteúdo da rede', 'select public.painel_conteudo()', 'sem permissão');
select t.erro('painel','gerente de loja não decide roteiro', format('select public.painel_roteiro_decidir(%s, %L)', current_setting('t.rid'), 'aprovar'));
reset role;
select t.sem_jwt();
select t.ok('painel','publicado guarda link e nome do anúncio; tudo auditado',
  (select status = 'publicado' and anuncio_nome = 'SV – Reel 2 óculos' and link like 'https://%' from cont.roteiros where id = current_setting('t.rid2')::bigint)
  and exists (select 1 from core.auditoria where acao = 'roteiro_publicado') and exists (select 1 from core.auditoria where acao = 'conteudo_regras_alteradas'));
select t.ok('painel','regras novas valem para os agentes', (cont._regras()->>'roteiros_por_dia')::int = 5
  and cont._regras()->'formatos' = '["reel","carrossel"]'::jsonb and cont._regras()->>'foco' = 'Natal e 13º salário');

-- ajuste e ideia resgatada pelo Diego voltam para o Roteirista
select set_config('t.r2', cont.iniciar('roteirista', 'tarefa-agendada', 'ajustes')::text, false);
select t.ok('ajuste','rodada de ajustes traz o pedido do Diego e o roteiro atual', current_setting('t.r2')::jsonb->>'status' = 'ok'
  and current_setting('t.r2')::jsonb->'ajustes'->0->>'pedido_ajuste' = 'Troque o gancho: comece pela etiqueta'
  and jsonb_array_length(current_setting('t.r2')::jsonb->'ideias') = 0, left(current_setting('t.r2'), 300));
select set_config('t.r2r', cont.concluir_roteiros((current_setting('t.r2')::jsonb->>'tarefa')::uuid, 'tarefa-agendada', jsonb_build_array(
  jsonb_build_object('roteiro_id', current_setting('t.rid'), 'titulo', 'Roteiro refeito', 'gancho', 'Olha essa etiqueta.', 'cenas', current_setting('t.cenas')::jsonb)))::text, false);
select t.ok('ajuste','roteiro refeito volta como pronto, versão 2, com a versão anterior guardada',
  (select status = 'pronto' and versao = 2 and jsonb_array_length(historico) = 1 and pedido_ajuste is null and gancho = 'Olha essa etiqueta.'
     from cont.roteiros where id = current_setting('t.rid')::bigint), current_setting('t.r2r'));
select t.ok('ajuste','pedido de ajuste vira aprendizado', jsonb_array_length(cont._aprendizado()->'ajustes_pedidos') = 1
  and jsonb_array_length(cont._aprendizado()->'diego_aprovou') = 1);
select t.ok('promover','ideia resgatada pelo Diego está aprovada e sem roteiro (entra na próxima rodada diária)',
  (select status from cont.ideias where id = current_setting('t.desc')::bigint) = 'aprovada'
  and not exists (select 1 from cont.roteiros where ideia_id = current_setting('t.desc')::bigint));

select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DE CONTEÚDO FALHANDO'; end if; end $$;
