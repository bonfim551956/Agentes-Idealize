-- Ajustes de 27/10: tempo médio da Kommo e avisos de nova admissão e aniversário no RH (dados sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;

-- A. Kommo: tempo médio só no horário de atendimento
select t.ok('kommo','minutos úteis: sábado 18:50 → segunda 09:05 = 15 min (domingo e madrugada fora)',
  com._minutos_uteis('2026-10-24 18:50-03', '2026-10-26 09:05-03') = 15);
select t.ok('kommo','minutos úteis: dentro do expediente conta corrido', com._minutos_uteis('2026-10-27 10:00-03', '2026-10-27 10:12-03') = 12);
select t.ok('kommo','minutos úteis: resposta antes da mensagem ou sem resposta = 0',
  com._minutos_uteis('2026-10-27 10:00-03', '2026-10-27 09:00-03') = 0 and com._minutos_uteis(null, now()) = 0);

insert into core.unidades (id, nome) values ('ext_a','Loja Extras') on conflict (id) do nothing;
insert into com.usuarios (id, nome) values (9701, 'Atendente Carla Ext') on conflict (id) do nothing;
insert into com.funis (id, nome, unidade_id) values (9702, 'Funil Extras', 'ext_a') on conflict (id) do nothing;
insert into com.etapas (funil_id, id, nome, tipo, ordem) values (9702, 1, 'Novo', 'entrada', 1) on conflict do nothing;
insert into com.leads (id, funil_id, etapa_id, responsavel_id, valor, criado_em, atualizado_em, hash_origem) values
  (970001, 9702, 1, 9701, 0, now() - interval '9 days', now() - interval '1 day', 'h'),
  (970002, 9702, 1, 9701, 0, now() - interval '9 days', now() - interval '1 day', 'h');
-- conversa 1: cliente no sábado 18:50, resposta na segunda 09:05 (15 min úteis, 38 h corridas)
-- conversa 2: cliente numa terça 10:00, resposta 10:25 (25 min)
select set_config('t.sab', ((date_trunc('week', now() at time zone 'America/Sao_Paulo')::date - 2) || ' 18:50')::text, false);
select set_config('t.seg', ((date_trunc('week', now() at time zone 'America/Sao_Paulo')::date) || ' 09:05')::text, false);
select set_config('t.ter', ((date_trunc('week', now() at time zone 'America/Sao_Paulo')::date - 6) || ' 10:00')::text, false);
insert into com.mensagens (evento_id, entidade_tipo, entidade_id, sentido, usuario_id, em) values
  ('ext1', 'lead', 970001, 'cliente', null, (current_setting('t.sab')::timestamp at time zone 'America/Sao_Paulo')),
  ('ext2', 'lead', 970001, 'atendente', 9701, (current_setting('t.seg')::timestamp at time zone 'America/Sao_Paulo')),
  ('ext3', 'lead', 970002, 'cliente', null, (current_setting('t.ter')::timestamp at time zone 'America/Sao_Paulo')),
  ('ext4', 'lead', 970002, 'atendente', 9701, (current_setting('t.ter')::timestamp at time zone 'America/Sao_Paulo') + interval '25 minutes');
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.pc', public.painel_comercial('ext_a', 14)::text, false);
reset role;
select t.sem_jwt();
select t.ok('kommo','por atendente: tempo médio 20 min (15 e 25, só horário de atendimento); mediana corrida segue à parte',
  (select (x->>'media_min')::numeric = 20 and (x->>'mediana_min')::numeric > 60 from jsonb_array_elements(current_setting('t.pc')::jsonb->'atendentes') x
   where x->>'nome' = 'Atendente Carla Ext'), current_setting('t.pc')::jsonb->>'atendentes');
select t.ok('kommo','geral da loja também traz o tempo médio e o horário usado',
  (current_setting('t.pc')::jsonb->'resposta_geral'->>'media_min')::numeric = 20
  and current_setting('t.pc')::jsonb->>'horario_atendimento' = '09:00-19:00');

-- B. RH: nova admissão e aniversário
update core.agentes set status = 'ativo' where id = 'rh';
create function t.vx(id text, nome text, status text, adm date, aniv text) returns jsonb language sql as $$
  select jsonb_build_object('vinculo_id', id, 'nome', nome, 'loja', 'CAMPINAS', 'cargo', 'CONSULTORA', 'tipo', 'clt_experiencia',
    'status', status, 'data_admissao', adm, 'jornada_semanal_horas', 44, 'escala', 'DAS 09:00 AS 18:00', 'aniversario', aniv) $$;
select set_config('t.r1', t.sync_rh(jsonb_build_object('vinculos', jsonb_build_array(
  t.vx('x1', 'PESSOA PRE ADMISSAO', 'pre_admissao', rh._hoje() + 5, null),
  t.vx('x2', 'PESSOA ENTROU ONTEM', 'ativo', rh._hoje() - 1, null),
  t.vx('x3', 'PESSOA ANTIGA', 'ativo', rh._hoje() - 200, to_char(rh._hoje() + 3, 'MM-DD')),
  t.vx('x4', 'PESSOA ANIVERSARIO LONGE', 'ativo', rh._hoje() - 300, to_char(rh._hoje() + 20, 'MM-DD')),
  t.vx('x5', 'PESSOA ANIVERSARIO HOJE', 'ativo', rh._hoje() - 400, to_char(rh._hoje(), 'MM-DD')),
  t.vx('x6', 'PESSOA DATA ERRADA', 'ativo', rh._hoje() - 400, '1990-03-15'))))::text, false);
select t.ok('rh','leitura aprovada pelo conferente', current_setting('t.r1')::jsonb->>'validacao' = 'concluida', current_setting('t.r1'));
select t.ok('rh','nova admissão: pré-admissão e quem entrou ontem; quem entrou há 200 dias não',
  exists (select 1 from rh.alertas where status = 'aberto' and tipo = 'nova_admissao' and referencia = 'vinculo:x1' and (detalhe->>'pre_admissao')::boolean)
  and exists (select 1 from rh.alertas where status = 'aberto' and tipo = 'nova_admissao' and referencia = 'vinculo:x2')
  and not exists (select 1 from rh.alertas where status = 'aberto' and tipo = 'nova_admissao' and referencia = 'vinculo:x3'));
select t.ok('rh','aniversário em 3 dias e hoje avisam (só dia/mês); em 20 dias ainda não',
  exists (select 1 from rh.alertas where status = 'aberto' and tipo = 'aniversario' and referencia like 'vinculo:x3:%' and detalhe->>'dia' = to_char(rh._hoje() + 3, 'DD/MM'))
  and exists (select 1 from rh.alertas where status = 'aberto' and tipo = 'aniversario' and referencia like 'vinculo:x5:%' and (detalhe->>'hoje')::boolean)
  and not exists (select 1 from rh.alertas where status = 'aberto' and tipo = 'aniversario' and referencia like 'vinculo:x4:%'));
select t.ok('privacidade','data completa de nascimento é descartada (só MM-DD entra)', (select aniversario from rh.vinculos where id = 'x6') is null
  and not exists (select 1 from rh.alertas where detalhe::text like '%1990%'));
-- aniversário passou / admissão ficou velha: avisos se resolvem
select t.sync_rh(jsonb_build_object('vinculos', jsonb_build_array(
  t.vx('x2', 'PESSOA ENTROU ONTEM', 'ativo', rh._hoje() - 30, null),
  t.vx('x3', 'PESSOA ANTIGA', 'ativo', rh._hoje() - 200, to_char(rh._hoje() - 1, 'MM-DD')))));
select t.ok('rh','aniversário que passou e admissão de 30 dias atrás: avisos resolvidos sozinhos',
  not exists (select 1 from rh.alertas where status = 'aberto' and tipo in ('nova_admissao','aniversario')));
select t.ok('experiencia','marcos: 15+15 para todos; CONSULTOR(A) ÓPTICO 15+30 (com ou sem acento/parênteses)',
  rh._marcos_experiencia('AUXILIAR ADMINISTRATIVO') = array[15,30] and rh._marcos_experiencia('CONSULTOR(A) ÓPTICO') = array[15,45]
  and rh._marcos_experiencia('Consultor Optico') = array[15,45] and rh._marcos_experiencia(null) = array[15,30]);
select t.ok('experiencia','aviso passa a ser 5 dias antes', core.cfg('rh.experiencia_aviso_dias') = '5');
select t.sync_rh(jsonb_build_object('vinculos', jsonb_build_array(
  jsonb_build_object('vinculo_id','e1','nome','CONSULTORA NOVA','loja','CAMPINAS','cargo','CONSULTOR(A) ÓPTICO','tipo','clt_experiencia','status','ativo',
    'data_admissao', rh._hoje() - 12, 'jornada_semanal_horas', 44, 'escala', 'DAS 09:00 AS 18:00'),
  jsonb_build_object('vinculo_id','e2','nome','CONSULTORA PRORROGADA','loja','CAMPINAS','cargo','CONSULTOR(A) ÓPTICO','tipo','clt_experiencia','status','ativo',
    'data_admissao', rh._hoje() - 42, 'jornada_semanal_horas', 44, 'escala', 'DAS 09:00 AS 18:00'),
  jsonb_build_object('vinculo_id','e3','nome','AUXILIAR PASSOU','loja','CAMPINAS','cargo','AUXILIAR DE OPERAÇÕES','tipo','clt_experiencia','status','ativo',
    'data_admissao', rh._hoje() - 32, 'jornada_semanal_horas', 44, 'escala', 'DAS 09:00 AS 18:00'),
  jsonb_build_object('vinculo_id','e4','nome','CONSULTORA NO PRAZO','loja','CAMPINAS','cargo','CONSULTOR(A) ÓPTICO','tipo','clt_experiencia','status','ativo',
    'data_admissao', rh._hoje() - 32, 'jornada_semanal_horas', 44, 'escala', 'DAS 09:00 AS 18:00'))));
select t.ok('experiencia','consultora com 13 dias: 1º período (15) termina em 2 dias',
  exists (select 1 from rh.alertas where status = 'aberto' and tipo = 'fim_experiencia' and referencia = 'vinculo:e1:15' and prazo = rh._hoje() + 2));
select t.ok('experiencia','consultora com 43 dias: prorrogação (45) termina em 2 dias',
  exists (select 1 from rh.alertas where status = 'aberto' and tipo = 'fim_experiencia' and referencia = 'vinculo:e2:45' and prazo = rh._hoje() + 2));
select t.ok('experiencia','auxiliar com 33 dias: passou dos 30 — experiência vencida; consultora com 33 dias ainda não',
  exists (select 1 from rh.alertas where status = 'aberto' and tipo = 'experiencia_vencida' and referencia = 'vinculo:e3')
  and not exists (select 1 from rh.alertas where status = 'aberto' and tipo = 'experiencia_vencida' and referencia = 'vinculo:e4'));
update core.agentes set status = 'pausado' where id = 'rh';

select t.ok('auditoria','cadeia íntegra', core.verificar_auditoria() is null);

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DOS AJUSTES FALHANDO'; end if; end $$;
