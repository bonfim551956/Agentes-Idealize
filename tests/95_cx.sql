-- Agente de Caixa (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into core.unidades (id, nome) values ('campinas','Campinas'), ('sorocaba','Sorocaba') on conflict (id) do nothing;
insert into cx.unidades_origem values ('campinas','campinas'), ('sorocaba','sorocaba') on conflict do nothing;
update core.config set valor = '' where chave = 'cx.dias_sem_expediente';   -- teste independe do dia da semana

-- A. Travas e formas
select t.ok('travas','agente nasce pausado', (select status from core.agentes where id = 'caixa') = 'pausado');
select t.ok('travas','sincronização nasce desligada', core.cfg('cx.sync.ativo') = 'false' and cx.agendar_sincronizacao() is null);
select t.ok('travas','proibido baixar parcela, estornar, transferir, alterar fechamento, cobrar ou excluir',
  (select bool_and((core.autorizar(p.id, 'cx.conferencia', op, null)).categoria = 'proibida')
   from core.principais p, unnest(array['baixar_parcela','estornar','transferir','alterar_fechamento','cobrar','excluir']) op
   where p.agente_id = 'caixa'));
select t.ok('formas','formas do ADM viram formas canônicas',
  cx._forma('Crédito') = 'credito' and cx._forma('DÉBITO') = 'debito' and cx._forma('Link Asaas') = 'asaas' and cx._forma('Pix') = 'pix'
  and cx._forma('Multicrediário') = 'crediario' and cx._forma('Sem saldo') = 'nao_financeiro' and cx._forma('Garantia') = 'nao_financeiro'
  and cx._forma('xyz') = 'outro');
select t.ok('privacidade','valores do caixa não têm cliente, OS ou vendedor', not exists (select 1 from information_schema.columns
  where table_schema = 'cx' and column_name in ('cliente','nome','os','cpf','telefone','vendedor')));

update core.agentes set status = 'ativo' where id = 'caixa';
update core.config set valor = 'true' where chave = 'cx.sync.ativo';

-- Banco da loja (importado pelo financeiro): Pix de clientes e uma transferência entre empresas do grupo
insert into fin.contas (id, apelido, tipo, unidade_id) values ('teste_cx_banco', 'Banco Campinas (teste)', 'corrente', 'campinas');
create function t.d(n int) returns date language sql as $$ select cx._hoje() - n $$;
create function t.mov(n int, valor numeric, descr text) returns void language sql as $$
  insert into fin.movimentos (conta_id, data, sentido, valor, descricao, chave_dedup)
  values ('teste_cx_banco', t.d(n), 'credito', valor, descr, 'cx-teste-' || gen_random_uuid())
$$;
select t.mov(6, 550, 'RECEBIMENTO PIX-PIX_CRED 111 CLIENTE A'), t.mov(4, 120, 'RECEBIMENTO PIX-PIX_CRED 222 CLIENTE B'),
       t.mov(6, 45, 'RECEBIMENTO PIX-PIX_CRED 333 CLIENTE C'), t.mov(6, 5000, 'RECEBIMENTO PIX-PIX_CRED 444 IDEALIZE COMERCIO OPTICO'),
       t.mov(5, 70, 'RECEBIMENTO PIX-PIX_CRED 555 CLIENTE D'), t.mov(1, 10, 'RECEBIMENTO PIX-PIX_CRED 666 CLIENTE E'),
       t.mov(6, 900, 'STONE ANTEC VISA-123');

create function t.pg(n int, forma text, valor numeric, origem text default 'venda') returns jsonb language sql as $$
  select jsonb_build_object('unidade','campinas','data',t.d(n),'origem',origem,'forma',forma,'valor',valor)
$$;
create function t.dia(n int, caixa numeric, deposito numeric default null) returns jsonb language sql as $$
  select jsonb_build_object('unidade','campinas','data',t.d(n),'status','aberto','caixa',caixa,'deposito_valor',deposito)
$$;
create function t.lote_cx(com_dia4 boolean default false, deposito numeric default null, extra_pag jsonb default '[]') returns jsonb language sql as $$
  select jsonb_build_object('desde', t.d(6), 'ate', t.d(0),
    'adm', jsonb_build_object(
      'dias', jsonb_build_array(t.dia(6, 2469, deposito), t.dia(5, 100), t.dia(3, 0), t.dia(2, 0), t.dia(1, 10), t.dia(0, 0),
                                jsonb_build_object('unidade','loja_x','data',t.d(1),'caixa',1))
              || case when com_dia4 then jsonb_build_array(t.dia(4, 0)) else '[]' end,
      'pagamentos', jsonb_build_array(
        t.pg(6,'Pix',275), t.pg(6,'Pix',275), t.pg(6,'Pix',120,'entrega'), t.pg(6,'Pix',999),
        t.pg(6,'Asaas',300), t.pg(6,'Link Asaas',80), t.pg(6,'Crédito',500), t.pg(6,'Dinheiro',200), t.pg(6,'Garantia',50),
        t.pg(5,'Pix',70), t.pg(1,'Pix',10),
        jsonb_build_object('unidade','loja_x','data',t.d(1),'origem','venda','forma','Pix','valor',1)) || extra_pag),
    'asaas', jsonb_build_array(jsonb_build_object('unidade_id','campinas','ate',t.d(0),'pagamentos', jsonb_build_array(
        jsonb_build_object('id','pay_1','dia',t.d(6),'forma','asaas','valor',300),
        jsonb_build_object('id','pay_2','dia',t.d(5),'forma','asaas','valor',150,'parcela',true)))))
$$;

create function t.sync_cx(lote jsonb, validar boolean default true) returns jsonb language plpgsql as $$
declare v_t uuid; v jsonb;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'caixa'), 'caixa', 'cx_sincronizacao',
    'cx.conferencia', 'sincronizar', null, '{"origem":"teste"}', 'cx:teste:' || gen_random_uuid(), null, 6);
  perform core.reivindicar('caixa', 'caixa-sync', 120);
  v := cx.concluir_sincronizacao(v_t, 'caixa-sync', lote);
  if validar then v := v || jsonb_build_object('validacao', cx.validar_sincronizacao(v_t, 'validador_sql')); end if;
  return v || jsonb_build_object('tarefa', v_t);
end $$;

-- B. Primeira leitura
select set_config('t.c1', t.sync_cx(t.lote_cx())::text, false);
select t.ok('sync','10 valores do caixa (garantia e loja desconhecida ignoradas), 6 dias, 2 recebimentos do Asaas',
  (current_setting('t.c1')::jsonb->>'pagamentos')::int = 10 and (current_setting('t.c1')::jsonb->>'dias')::int = 6
  and (current_setting('t.c1')::jsonb->>'recebimentos')::int = 2 and (current_setting('t.c1')::jsonb->>'ignoradas')::int = 3, current_setting('t.c1'));
select t.ok('sync','validador independente aprovou', current_setting('t.c1')::jsonb->>'validacao' = 'concluida');
select t.ok('casamento','dois Pix de 275 casados com um crédito de 550 no banco',
  (select count(*) from cx.casamentos c join cx.pagamentos p on p.id = c.pagamento_id where p.valor = 275 and c.modo = 'dois_em_um') = 2);
select t.ok('casamento','Pix de 120 casado com crédito que caiu 2 dias depois',
  exists (select 1 from cx.casamentos c join cx.pagamentos p on p.id = c.pagamento_id where p.valor = 120 and c.modo = 'um_a_um'));
select t.ok('casamento','Asaas de 300 casado; parcela de crediário não entra',
  exists (select 1 from cx.casamentos c join cx.pagamentos p on p.id = c.pagamento_id where p.forma = 'asaas' and p.valor = 300)
  and not exists (select 1 from cx.casamentos where recebimento = 'asaas:pay_2'));
select t.ok('alertas','Pix de 999 não achado no banco', exists (select 1 from cx.alertas where tipo = 'nao_encontrado' and status = 'aberto'
  and referencia = 'campinas:' || t.d(6) || ':pix' and (detalhe->>'valor')::numeric = 999));
select t.ok('alertas','Link Asaas de 80 não achado no Asaas', exists (select 1 from cx.alertas where tipo = 'nao_encontrado' and status = 'aberto'
  and referencia = 'campinas:' || t.d(6) || ':asaas' and (detalhe->>'valor')::numeric = 80));
select t.ok('alertas','crédito sem arquivo da Stone ainda não vira alerta', not exists (select 1 from cx.alertas where referencia like '%:credito'));
select t.ok('alertas','Pix de 45 no banco sem registro no caixa; transferência do grupo e Stone ignoradas',
  exists (select 1 from cx.alertas where tipo = 'sem_registro_no_caixa' and status = 'aberto' and (detalhe->>'valor')::numeric = 45)
  and not exists (select 1 from cx.alertas where tipo = 'sem_registro_no_caixa' and (detalhe->>'valor')::numeric >= 900));
select t.ok('alertas','dia sem fechamento no ADM', exists (select 1 from cx.alertas where tipo = 'caixa_nao_fechado' and referencia = 'campinas:' || t.d(4) and status = 'aberto'));
select t.ok('alertas','total do caixa (100) diferente da soma das formas (70)', exists (select 1 from cx.alertas where tipo = 'caixa_inconsistente'
  and referencia = 'campinas:' || t.d(5) and (detalhe->>'diferenca')::numeric = 30));
select t.ok('alertas','dinheiro de 200 sem depósito', exists (select 1 from cx.alertas where tipo = 'dinheiro_sem_deposito' and referencia = 'campinas:' || t.d(6)));
select t.ok('alertas','dia que bate não tem alerta', not exists (select 1 from cx.alertas where referencia like 'campinas:' || t.d(1) || '%'));

-- C. Idempotência e resolução automática
select set_config('t.c2', t.sync_cx(t.lote_cx())::text, false);
select t.ok('sync','mesmo lote: mesmos valores e alertas sem duplicar',
  (select count(*) from cx.pagamentos) = 10 and (select count(*) from cx.alertas where status = 'aberto' and tipo = 'nao_encontrado') = 2, current_setting('t.c2'));
select t.mov(5, 999, 'RECEBIMENTO PIX-PIX_CRED 777 CLIENTE F');
select set_config('t.c3', t.sync_cx(t.lote_cx(com_dia4 => true, deposito => 200,
  extra_pag => jsonb_build_array(t.pg(6,'Pix',45))))::text, false);
select t.ok('resolucao','Pix achado, dia fechado, depósito feito e Pix de 45 registrado: alertas resolvidos sozinhos',
  not exists (select 1 from cx.alertas where status = 'aberto' and tipo in ('caixa_nao_fechado','dinheiro_sem_deposito','sem_registro_no_caixa'))
  and not exists (select 1 from cx.alertas where status = 'aberto' and referencia = 'campinas:' || t.d(6) || ':pix')
  and exists (select 1 from cx.alertas where status = 'resolvido' and resolvido_por like 'agente_caixa%'), current_setting('t.c3'));
select t.ok('resolucao','validação da leitura seguinte aprovou', current_setting('t.c3')::jsonb->>'validacao' = 'concluida');
select t.ok('janela','próximas leituras relêem os últimos 10 dias', (cx.proxima_janela()->>'desde')::date = cx._hoje() - 9);

-- D. Validador e atomicidade
do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'caixa'), 'caixa', 'cx_sincronizacao',
    'cx.conferencia', 'sincronizar', null, '{"origem":"teste"}', 'cx:teste:validador', null, 6);
  perform core.reivindicar('caixa', 'caixa-sync', 120);
  perform cx.concluir_sincronizacao(v_t, 'caixa-sync', t.lote_cx(true, 200));
  update cx.dias set soma_formas = soma_formas + 1 where dia = t.d(6);
  perform set_config('t.cv', cx.validar_sincronizacao(v_t, 'validador_sql'), false);
end $$;
select t.ok('validador','soma das formas adulterada: validador reprova e bloqueia', current_setting('t.cv') = 'bloqueada');
do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'caixa'), 'caixa', 'cx_sincronizacao',
    'cx.conferencia', 'sincronizar', null, '{"origem":"teste"}', 'cx:teste:atomico', null, 6);
  perform core.reivindicar('caixa', 'caixa-sync', 120);
  perform set_config('t.ca', v_t::text, false);
end $$;
select t.erro('atomico','lote sem dados do ADM é recusado inteiro',
  format('select cx.concluir_sincronizacao(%L, %L, %L::jsonb)', current_setting('t.ca'), 'caixa-sync',
         jsonb_build_object('desde', t.d(3), 'ate', t.d(0))), 'ADM');
select t.ok('atomico','nada apagado: valores do caixa continuam lá', (select count(*) from cx.pagamentos) = 10
  and (select status from core.tarefas where id = current_setting('t.ca')::uuid) = 'executando');
select t.erro('validador','executor não valida a si mesmo',
  format('select cx.validar_sincronizacao(%L, %L)', current_setting('t.ca'), 'caixa-sync'), 'validação');
select t.sync_cx(t.lote_cx(true, 200, jsonb_build_array(t.pg(6,'Pix',45))));

-- E. Painel e escopo
select set_config('t.d6', t.d(6)::text, false);
set role anon;
select t.erro('seguranca','anon não chama o painel do caixa', 'select public.painel_caixa()', 'permission');
reset role;
set role authenticated;
select t.erro('seguranca','usuário logado não lê o espelho direto', 'select count(*) from cx.pagamentos', 'permission');
select t.erro('seguranca','usuário logado não chama funções do agente', 'select cx.recalcular()', 'permission');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.ok('painel','gerente de outra unidade não vê o caixa de Campinas',
  jsonb_array_length(public.painel_caixa()->'conferencia') = 0 and jsonb_array_length(public.painel_caixa()->'alertas') = 0);
select t.erro('painel','gerente não consulta loja fora do acesso', $q$select public.painel_caixa('campinas')$q$, 'sem permissão');
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('painel','conferência do dia: Pix de R$ 1.714 no caixa, todo achado no banco',
  (select (x->>'sistema')::numeric = 1714 and (x->>'faltando')::numeric = 0
   from jsonb_array_elements(public.painel_caixa('campinas')->'conferencia') x where x->>'dia' = current_setting('t.d6') and x->>'forma' = 'pix'),
  public.painel_caixa('campinas')::text);
select t.ok('painel','cobertura mostra banco e Asaas', (select count(*) from jsonb_array_elements(public.painel_caixa('campinas')->'cobertura')) = 2);
reset role;
select t.sem_jwt();

select t.ok('auditoria','cadeia íntegra', core.verificar_auditoria() is null);
update core.agentes set status = 'pausado' where id = 'caixa';
update core.config set valor = 'false' where chave = 'cx.sync.ativo';
update core.config set valor = '0' where chave = 'cx.dias_sem_expediente';

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DO CAIXA FALHANDO'; end if; end $$;
