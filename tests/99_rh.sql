-- Agente de RH (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into core.unidades (id, nome) values ('campinas','Campinas'), ('sorocaba','Sorocaba') on conflict (id) do nothing;
insert into rh.lojas_origem values ('CAMPINAS','campinas'), ('SOROCABA','sorocaba') on conflict do nothing;

-- A. Travas e privacidade
select t.ok('travas','agente nasce pausado', (select status from core.agentes where id = 'rh') = 'pausado');
select t.ok('travas','sincronização nasce desligada', core.cfg('rh.sync.ativo') = 'false' and rh.agendar_sincronizacao() is null);
select t.ok('travas','proibido desligar, advertir, mexer em salário/cargo, efetivar, conceder férias, calcular rescisão, mandar mensagem ou alterar cadastro',
  (select bool_and((core.autorizar(p.id, 'rh.pessoas', op, null)).categoria = 'proibida')
   from core.principais p, unnest(array['desligar','advertir','alterar_salario','alterar_cargo','efetivar','conceder_ferias',
     'calcular_rescisao','enviar_mensagem','alterar_cadastro','excluir']) op where p.agente_id = 'rh'));
select t.ok('privacidade','espelho não tem CPF, nascimento, endereço, telefone, e-mail ou salário', not exists (select 1 from information_schema.columns
  where table_schema = 'rh' and column_name in ('cpf','data_nascimento','nascimento','endereco','logradouro','telefone','email','salario','salario_base','valor')));

update core.agentes set status = 'ativo' where id = 'rh';
update core.config set valor = 'true' where chave = 'rh.sync.ativo';

create function t.rd(n int) returns date language sql as $$ select rh._hoje() + n $$;
create function t.anos(a int, n int) returns date language sql as $$ select (rh._hoje() - make_interval(years => a) + make_interval(days => n))::date $$;
create function t.vin(id text, nome text, loja text, tipo text, status text, adm date, jornada numeric default 44, escala text default 'DAS 09:00 AS 18:00') returns jsonb
language sql as $$ select jsonb_build_object('vinculo_id', id, 'nome', nome, 'loja', loja, 'cargo', 'CONSULTOR', 'tipo', tipo, 'status', status,
  'data_admissao', adm, 'jornada_semanal_horas', jornada, 'escala', escala, 'cpf', '12345678900', 'salario_base', 3000) $$;
create function t.lote_rh(ferias_v3 boolean default false, desligamento_concluido boolean default false, tarefa_status text default 'pendente',
  saldo_uniforme int default 2) returns jsonb language sql as $$
  select jsonb_build_object(
    'vinculos', jsonb_build_array(
      t.vin('v1','ANA EXPERIENCIA','CAMPINAS','clt_experiencia','ativo', t.rd(-26)),
      t.vin('v2','BIA EXPERIENCIA VENCIDA','CAMPINAS','clt_experiencia','ativo', t.rd(-95)),
      t.vin('v3','CAIO FERIAS VENCIDAS','CAMPINAS','clt_prazo_indeterminado','ativo', t.anos(2, -30)),
      t.vin('v4','DUDA FERIAS PERTO','SOROCABA','clt_prazo_indeterminado','ativo', t.anos(2, 64)),
      t.vin('v5','EDU JORNADA 48','CAMPINAS','clt_prazo_indeterminado','ativo', t.rd(-100), 48),
      t.vin('v6','FABI SEM ESCALA','CAMPINAS','clt_prazo_indeterminado','ativo', t.rd(-100), 44, 'DAS 00:00 AS 00:00'),
      t.vin('v7','GABI DESLIGADA','CAMPINAS','clt_prazo_indeterminado','desligado', t.rd(-300)),
      t.vin('v8','HUGO NOVO','CAMPINAS','clt_experiencia','pre_admissao', t.rd(0)),
      t.vin('v9','IVO LOJA X','LOJA_X','clt_prazo_indeterminado','desligado', t.rd(-300))),
    'ferias', jsonb_build_array(
      jsonb_build_object('id','f4','vinculo_id','v4','inicio',t.rd(-30),'fim',t.rd(-21),'aquisitivo_inicio',t.anos(2,64),'aquisitivo_fim',(t.anos(1,64) - 1)),
      jsonb_build_object('id','fx','vinculo_id','v5','inicio',t.rd(1),'fim',t.rd(200),'aquisitivo_inicio',t.rd(-100)))
      || case when ferias_v3 then jsonb_build_array(jsonb_build_object('id','f3','vinculo_id','v3','inicio',t.rd(-20),'fim',t.rd(9),
           'aquisitivo_inicio',t.anos(2,-30),'aquisitivo_fim',(t.anos(1,-30) - 1))) else '[]' end,
    'desligamentos', jsonb_build_array(jsonb_build_object('id','d7','vinculo_id','v7','modalidade','sem_justa_causa','data_desligamento',t.rd(-8),
      'status', case when desligamento_concluido then 'concluido' else 'em_andamento' end)),
    'tarefas', jsonb_build_array(jsonb_build_object('id','t1','titulo','ENTREGAR CTPS','categoria','admissao','loja','CAMPINAS','prazo',t.rd(-1),'status',tarefa_status)),
    'documentos', jsonb_build_array(jsonb_build_object('id','doc4','vinculo_id','v4','categoria','exames_ocupacionais','vencimento',t.rd(10),'status','aprovado')),
    'mudancas', jsonb_build_array(jsonb_build_object('id','salario:1','vinculo_id','v3','tipo','salario','data',t.rd(0))),
    'uniformes', jsonb_build_array(jsonb_build_object('id','u1','peca','POLO FEMININO','tamanho','M','estoque_minimo',12,'saldo',saldo_uniforme)))
$$;
create function t.sync_rh(lote jsonb, validar boolean default true) returns jsonb language plpgsql as $$
declare v_t uuid; v jsonb;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'rh'), 'rh', 'rh_sincronizacao',
    'rh.pessoas', 'sincronizar', null, '{"origem":"teste"}', 'rh:teste:' || gen_random_uuid(), null, 6);
  perform core.reivindicar('rh', 'rh-sync', 120);
  v := rh.concluir_sincronizacao(v_t, 'rh-sync', lote);
  if validar then v := v || jsonb_build_object('validacao', rh.validar_sincronizacao(v_t, 'validador_sql')); end if;
  return v || jsonb_build_object('tarefa', v_t);
end $$;

-- B. Primeira leitura
select set_config('t.r1', t.sync_rh(t.lote_rh())::text, false);
select t.ok('sync','9 vínculos lidos; férias de 200 dias descartada', (current_setting('t.r1')::jsonb->>'vinculos')::int = 9
  and (current_setting('t.r1')::jsonb->>'ferias')::int = 1, current_setting('t.r1'));
select t.ok('sync','validador independente aprovou', current_setting('t.r1')::jsonb->>'validacao' = 'concluida');
select t.ok('privacidade','CPF e salário do lote não foram gravados', not exists (select 1 from rh.vinculos where row_to_json(vinculos.*)::text ~ '(12345678900|3000)'));
select t.ok('alertas','experiência 15+15: prorrogação (30 dias) termina em 3 dias', exists (select 1 from rh.alertas where tipo = 'fim_experiencia'
  and referencia = 'vinculo:v1:30' and prazo = t.rd(3) and status = 'aberto'));
select t.ok('alertas','experiência passou do prazo sem efetivação registrada', exists (select 1 from rh.alertas where tipo = 'experiencia_vencida' and referencia = 'vinculo:v2'));
select t.ok('alertas','férias do 1º período não tiradas e limite passado: risco de pagar em dobro',
  exists (select 1 from rh.alertas where tipo = 'ferias_vencidas' and referencia = 'vinculo:v3:' || t.anos(2,-30) and (detalhe->>'dias_faltando')::int = 30));
select t.ok('alertas','férias com limite em 64 dias e 20 dias faltando', exists (select 1 from rh.alertas where tipo = 'ferias_limite'
  and referencia = 'vinculo:v4:' || t.anos(2,64) and (detalhe->>'dias_faltando')::int = 20));
select t.ok('alertas','exame ocupacional vencendo em 10 dias', exists (select 1 from rh.alertas where tipo = 'exame_vencendo' and referencia = 'documento:doc4'));
select t.ok('alertas','desligamento com acerto vencendo em 2 dias', exists (select 1 from rh.alertas where tipo = 'desligamento_prazo' and referencia = 'desligamento:d7' and prazo = t.rd(2)));
select t.ok('alertas','tarefa atrasada', exists (select 1 from rh.alertas where tipo = 'tarefa_atrasada' and referencia = 'tarefa:t1'));
select t.ok('alertas','jornada de 48h e escala vazia',
  exists (select 1 from rh.alertas where tipo = 'jornada_irregular' and referencia = 'vinculo:v5' and detalhe->>'motivo' = 'acima')
  and exists (select 1 from rh.alertas where tipo = 'jornada_irregular' and referencia = 'vinculo:v6' and detalhe->>'motivo' = 'sem_escala'));
select t.ok('alertas','uniforme abaixo do mínimo', exists (select 1 from rh.alertas where tipo = 'uniforme_baixo' and referencia = 'uniforme:u1'));
select t.ok('alertas','quem está em pré-admissão ou desligado não gera aviso de experiência/jornada',
  not exists (select 1 from rh.alertas where (referencia like 'vinculo:v8%' or referencia like 'vinculo:v7%') and tipo <> 'nova_admissao'));
select t.ok('alertas','pré-admissão gera o aviso de nova admissão', exists (select 1 from rh.alertas where referencia = 'vinculo:v8' and tipo = 'nova_admissao' and status = 'aberto'));

-- C. Idempotência e resolução
select set_config('t.r2', t.sync_rh(t.lote_rh())::text, false);
select t.ok('sync','mesmo lote: alertas sem duplicar', (select count(*) from rh.alertas where status = 'aberto' and referencia = 'vinculo:v2') = 1, current_setting('t.r2'));
select set_config('t.r3', t.sync_rh(t.lote_rh(ferias_v3 => true, desligamento_concluido => true, tarefa_status => 'concluida', saldo_uniforme => 20))::text, false);
select t.ok('resolucao','férias lançadas (mesmo fora do prazo), acerto concluído, tarefa feita e uniforme reposto: alertas resolvidos',
  not exists (select 1 from rh.alertas where status = 'aberto' and referencia in ('vinculo:v3:' || t.anos(2,-30), 'desligamento:d7', 'tarefa:t1', 'uniforme:u1')), current_setting('t.r3'));
select t.ok('alertas','férias tiradas depois do limite viram aviso de pagamento em dobro a conferir',
  exists (select 1 from rh.alertas where status = 'aberto' and tipo = 'ferias_vencidas' and referencia = 'vinculo:v3:' || t.anos(2,-30) || ':fora'
          and (detalhe->>'dias_fora_do_prazo')::int = 30));
select t.ok('resolucao','validação da leitura seguinte aprovou', current_setting('t.r3')::jsonb->>'validacao' = 'concluida');

-- D. Validador e atomicidade
do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'rh'), 'rh', 'rh_sincronizacao',
    'rh.pessoas', 'sincronizar', null, '{"origem":"teste"}', 'rh:teste:validador', null, 6);
  perform core.reivindicar('rh', 'rh-sync', 120);
  perform rh.concluir_sincronizacao(v_t, 'rh-sync', t.lote_rh());
  update rh.alertas set status = 'resolvido', resolvido_em = now(), resolvido_por = 'teste' where referencia = 'vinculo:v2' and status = 'aberto';
  perform set_config('t.rv', rh.validar_sincronizacao(v_t, 'validador_sql'), false);
end $$;
select t.ok('validador','experiência vencida sem alerta: validador reprova e bloqueia', current_setting('t.rv') = 'bloqueada');
do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'rh'), 'rh', 'rh_sincronizacao',
    'rh.pessoas', 'sincronizar', null, '{"origem":"teste"}', 'rh:teste:atomico', null, 6);
  perform core.reivindicar('rh', 'rh-sync', 120);
  perform set_config('t.ra', v_t::text, false);
end $$;
select t.erro('atomico','lote vazio com espelho cheio é recusado', format('select rh.concluir_sincronizacao(%L, %L, %L::jsonb)',
  current_setting('t.ra'), 'rh-sync', '{"vinculos":[]}'), 'suspeita');
select t.ok('atomico','nada apagado', (select count(*) from rh.vinculos) = 9);
select t.erro('validador','executor não valida a si mesmo', format('select rh.validar_sincronizacao(%L, %L)', current_setting('t.ra'), 'rh-sync'), 'validação');
select t.sync_rh(t.lote_rh());

-- E. Painel e escopo
select set_config('t.hoje', rh._hoje()::text, false);
set role anon;
select t.erro('seguranca','anon não chama o painel de RH', 'select public.painel_rh()', 'permission');
reset role;
set role authenticated;
select t.erro('seguranca','usuário logado não lê o espelho direto', 'select count(*) from rh.vinculos', 'permission');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.ok('painel','gerente de outra unidade não vê ninguém', jsonb_array_length(public.painel_rh()->'quadro') = 0
  and jsonb_array_length(public.painel_rh()->'contabilidade'->'admissoes') = 0
  and not exists (select 1 from jsonb_array_elements(public.painel_rh()->'alertas') x where x->>'unidade_id' is not null));
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('painel','quadro de Campinas: 5 ativos, 2 em experiência, 1 em admissão',
  (select (x->>'ativos')::int = 5 and (x->>'em_experiencia')::int = 2 and (x->>'em_admissao')::int = 1
   from jsonb_array_elements(public.painel_rh('campinas')->'quadro') x), public.painel_rh('campinas')::text);
select t.ok('painel','lista do mês para a contabilidade: admissão de hoje e mudança de salário (sem valor)',
  (select count(*) from jsonb_array_elements(public.painel_rh('campinas')->'contabilidade'->'admissoes') x where x->>'nome' = 'HUGO NOVO') = 1
  and (select count(*) from jsonb_array_elements(public.painel_rh('campinas')->'contabilidade'->'mudancas') x where x->>'tipo' = 'salario' and not (x ? 'valor')) = 1);
select t.ok('painel','filtro por loja mostra só alertas dela', (select bool_and(x->>'unidade_id' = 'sorocaba') from jsonb_array_elements(public.painel_rh('sorocaba')->'alertas') x));
reset role;
select t.sem_jwt();

select t.ok('auditoria','cadeia íntegra', core.verificar_auditoria() is null);
update core.agentes set status = 'pausado' where id = 'rh';
update core.config set valor = 'false' where chave = 'rh.sync.ativo';

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DO RH FALHANDO'; end if; end $$;
