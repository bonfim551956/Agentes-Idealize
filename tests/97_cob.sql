-- Agente de Cobranças (dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;
insert into core.unidades (id, nome) values ('campinas','Campinas'), ('sorocaba','Sorocaba') on conflict (id) do nothing;
insert into cob.unidades_origem values ('campinas','campinas'), ('sorocaba','sorocaba') on conflict do nothing;

-- A. Travas e privacidade
select t.ok('travas','agente nasce pausado', (select status from core.agentes where id = 'cobrancas') = 'pausado');
select t.ok('travas','sincronização nasce desligada', core.cfg('cob.sync.ativo') = 'false' and cob.agendar_sincronizacao() is null);
select t.ok('travas','proibido enviar cobrança ou mensagem, baixar, cancelar, renegociar, emitir boleto ou excluir',
  (select bool_and((core.autorizar(p.id, 'cob.crediario', op, null)).categoria = 'proibida')
   from core.principais p, unnest(array['enviar_cobranca','enviar_mensagem','baixar_parcela','cancelar_cobranca','renegociar','emitir_boleto','excluir']) op
   where p.agente_id = 'cobrancas'));
select t.ok('privacidade','espelho não tem nome, CPF, telefone, CEP ou vendedor', not exists (select 1 from information_schema.columns
  where table_schema = 'cob' and column_name in ('nome','cpf','telefone','cep','vendedor','cliente')));

update core.agentes set status = 'ativo' where id = 'cobrancas';
update core.config set valor = 'true' where chave = 'cob.sync.ativo';

create function t.cd(n int) returns text language sql as $$ select (cob._hoje() + n)::text $$;
create function t.parc(id text, carne text, fin text, num int, valor numeric, venc int, status text default 'aberto', pago int default null,
  carne_status text default 'aberto', entrada numeric default 0, entrada_paga boolean default true, dt_entrada int default -40, loja text default 'campinas')
returns jsonb language sql as $$
  select jsonb_build_object('id', id, 'crediario_id', carne, 'unidade', loja, 'financeira', fin, 'numero', num, 'num_parcelas', 3,
    'valor', valor, 'dt_vencimento', t.cd(venc), 'dt_pagamento', case when pago is not null then t.cd(pago) end, 'status', status,
    'os', 'OS-' || carne, 'os_fake', false, 'carne_status', carne_status, 'renegociado', false, 'dt_compra', t.cd(-60),
    'valor_crediario', valor * 3, 'valor_entrada', entrada, 'entrada_paga', entrada_paga, 'dt_entrada', t.cd(dt_entrada),
    'nome', 'Cliente Fulano', 'cpf', '12345678900')
$$;
create function t.cob(id text, valor numeric, venc int, status text, pago int default null) returns jsonb language sql as $$
  select jsonb_build_object('id', id, 'valor', valor, 'vencimento', t.cd(venc), 'status', status,
    'pagamento', case when pago is not null then t.cd(pago) end, 'parcelamento', 'ins_1')
$$;
-- Carnê A (Asaas): parc 1 paga e baixada; parc 2 vencida há 10 dias; parc 3 a vencer em 20 dias
-- Carnê B (Asaas): parc vencida há 5 dias mas PAGA no Asaas (falta baixa no ADM); parc vencendo em 7 dias sem boleto
-- Carnê C (Asaas): baixado no ADM, cobrança do Asaas ainda pendente
-- Carnê D (Multicrédito): vencida há 40 dias; entrada combinada e não paga
-- Cobrança órfã no Asaas: 999 sem parcela
create function t.lote_cob(extra_cob jsonb default '[]', extra_parc jsonb default '[]') returns jsonb language sql as $$
  select jsonb_build_object(
    'parcelas', jsonb_build_array(
      t.parc('a1','A','asaas',1,100,-40,'pago',-40), t.parc('a2','A','asaas',2,100,-10), t.parc('a3','A','asaas',3,100,20),
      t.parc('b1','B','asaas',1,150,-5), t.parc('b2','B','asaas',2,150,7),
      t.parc('c1','C','asaas',1,80,-3,'pago',-3),
      t.parc('d1','D','multicredito',1,200,-40, entrada => 300, entrada_paga => false, dt_entrada => -30),
      t.parc('x1','X','asaas',1,50,-20, loja => 'loja_x')) || extra_parc,
    'asaas', jsonb_build_array(jsonb_build_object('unidade_id','campinas','cobrancas', jsonb_build_array(
      t.cob('pay_a1',100,-40,'RECEIVED',-40), t.cob('pay_a2',100,-10,'OVERDUE'), t.cob('pay_a3',100,20,'PENDING'),
      t.cob('pay_b1',150,-6,'RECEIVED',-5), t.cob('pay_c1',80,-3,'PENDING'), t.cob('pay_z',999,10,'PENDING'),
      t.cob('pay_ref',40,-1,'REFUNDED')) || extra_cob)))
$$;
create function t.sync_cob(lote jsonb, validar boolean default true) returns jsonb language plpgsql as $$
declare v_t uuid; v jsonb;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'cobrancas'), 'cobrancas', 'cob_sincronizacao',
    'cob.crediario', 'sincronizar', null, '{"origem":"teste"}', 'cob:teste:' || gen_random_uuid(), null, 6);
  perform core.reivindicar('cobrancas', 'cobrancas-sync', 120);
  v := cob.concluir_sincronizacao(v_t, 'cobrancas-sync', lote);
  if validar then v := v || jsonb_build_object('validacao', cob.validar_sincronizacao(v_t, 'validador_sql')); end if;
  return v || jsonb_build_object('tarefa', v_t);
end $$;

-- B. Primeira leitura
select set_config('t.b1', t.sync_cob(t.lote_cob())::text, false);
select t.ok('sync','4 carnês, 7 parcelas (loja desconhecida ignorada), 6 cobranças do Asaas (estornada fora)',
  (current_setting('t.b1')::jsonb->>'carnes')::int = 4 and (current_setting('t.b1')::jsonb->>'parcelas')::int = 7
  and (current_setting('t.b1')::jsonb->>'cobrancas_asaas')::int = 6 and (current_setting('t.b1')::jsonb->>'ignoradas')::int = 1, current_setting('t.b1'));
select t.ok('sync','carteira em aberto = 100+100+150+150+200', (current_setting('t.b1')::jsonb->>'carteira_aberta')::numeric = 700);
select t.ok('sync','validador independente aprovou', current_setting('t.b1')::jsonb->>'validacao' = 'concluida');
select t.ok('privacidade','nome e CPF do lote não foram gravados', not exists (select 1 from cob.carnes where row_to_json(carnes.*)::text ~ '(Fulano|12345678900)'));
select t.ok('vinculo','parcelas casadas com as cobranças (vencimento com 1 dia de diferença também)',
  (select count(*) from cob.vinculos) = 5 and exists (select 1 from cob.vinculos where parcela_id = 'b1' and asaas_id = 'pay_b1'));
select t.ok('alertas','carnê A com parcela vencida há 10 dias', exists (select 1 from cob.alertas where tipo = 'parcela_vencida' and referencia = 'carne:A'
  and status = 'aberto' and (detalhe->>'dias')::int = 10 and detalhe->>'os' = 'OS-A'));
select t.ok('alertas','carnê B não aparece como atrasado: pago no Asaas', not exists (select 1 from cob.alertas where tipo = 'parcela_vencida' and referencia = 'carne:B'));
select t.ok('alertas','pago no Asaas e sem baixa no ADM', exists (select 1 from cob.alertas where tipo = 'pago_sem_baixa' and referencia = 'parcela:b1'));
select t.ok('alertas','baixado no ADM com cobrança ainda pendente no Asaas', exists (select 1 from cob.alertas where tipo = 'baixa_sem_pagamento' and referencia = 'parcela:c1'));
select t.ok('alertas','cobrança ativa no Asaas sem parcela no ADM', exists (select 1 from cob.alertas where tipo = 'cobranca_sem_parcela' and referencia = 'asaas:pay_z'));
select t.ok('alertas','parcela vencendo em 7 dias sem boleto emitido', exists (select 1 from cob.alertas where tipo = 'parcela_sem_cobranca' and referencia = 'parcela:b2'));
select t.ok('alertas','parcela a vencer em 20 dias não pede boleto ainda', not exists (select 1 from cob.alertas where referencia = 'parcela:a3'));
select t.ok('alertas','Multicrédito: atraso de 40 dias e entrada não paga',
  exists (select 1 from cob.alertas where tipo = 'parcela_vencida' and referencia = 'carne:D' and (detalhe->>'dias')::int = 40)
  and exists (select 1 from cob.alertas where tipo = 'entrada_pendente' and referencia = 'carne:D' and (detalhe->>'valor')::numeric = 300));

-- C. Idempotência e resolução
select set_config('t.b2', t.sync_cob(t.lote_cob())::text, false);
select t.ok('sync','mesmo lote: mesmo retrato e alertas sem duplicar',
  (select count(*) from cob.parcelas) = 7 and (select count(*) from cob.alertas where status = 'aberto' and referencia = 'carne:A') = 1, current_setting('t.b2'));
select set_config('t.b3', t.sync_cob(jsonb_build_object(
  'parcelas', jsonb_build_array(
      t.parc('a1','A','asaas',1,100,-40,'pago',-40), t.parc('a2','A','asaas',2,100,-10,'pago',0), t.parc('a3','A','asaas',3,100,20),
      t.parc('b1','B','asaas',1,150,-5,'pago',-5), t.parc('b2','B','asaas',2,150,7),
      t.parc('c1','C','asaas',1,80,-3,'pago',-3),
      t.parc('d1','D','multicredito',1,200,-40,'pago',0, entrada => 300, entrada_paga => true, dt_entrada => -30)),
  'asaas', jsonb_build_array(jsonb_build_object('unidade_id','campinas','cobrancas', jsonb_build_array(
      t.cob('pay_a1',100,-40,'RECEIVED',-40), t.cob('pay_a2',100,-10,'RECEIVED',0), t.cob('pay_a3',100,20,'PENDING'),
      t.cob('pay_b1',150,-6,'RECEIVED',-5), t.cob('pay_b2',150,7,'PENDING'), t.cob('pay_c1',80,-3,'RECEIVED',-3))))))::text, false);
select t.ok('resolucao','tudo regularizado: todos os alertas resolvidos sozinhos',
  not exists (select 1 from cob.alertas where status = 'aberto')
  and (select count(*) from cob.alertas where status = 'resolvido' and resolvido_por like 'agente_cobrancas%') >= 7, current_setting('t.b3'));
select t.ok('resolucao','validação da leitura seguinte aprovou', current_setting('t.b3')::jsonb->>'validacao' = 'concluida');
select t.sync_cob(t.lote_cob());   -- volta o cenário com pendências

-- D. Validador e atomicidade
do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'cobrancas'), 'cobrancas', 'cob_sincronizacao',
    'cob.crediario', 'sincronizar', null, '{"origem":"teste"}', 'cob:teste:validador', null, 6);
  perform core.reivindicar('cobrancas', 'cobrancas-sync', 120);
  perform cob.concluir_sincronizacao(v_t, 'cobrancas-sync', t.lote_cob());
  update cob.alertas set status = 'resolvido', resolvido_em = now(), resolvido_por = 'teste: sumiu' where referencia = 'carne:A' and status = 'aberto';
  perform set_config('t.bv', cob.validar_sincronizacao(v_t, 'validador_sql'), false);
end $$;
select t.ok('validador','atraso sem alerta: validador reprova e bloqueia', current_setting('t.bv') = 'bloqueada');
do $$
declare v_t uuid;
begin
  v_t := core.criar_tarefa((select id from core.principais where agente_id = 'cobrancas'), 'cobrancas', 'cob_sincronizacao',
    'cob.crediario', 'sincronizar', null, '{"origem":"teste"}', 'cob:teste:atomico', null, 6);
  perform core.reivindicar('cobrancas', 'cobrancas-sync', 120);
  perform set_config('t.ba', v_t::text, false);
end $$;
select t.erro('atomico','lote vazio com espelho cheio é recusado (leitura suspeita)',
  format('select cob.concluir_sincronizacao(%L, %L, %L::jsonb)', current_setting('t.ba'), 'cobrancas-sync', '{"parcelas":[]}'), 'suspeita');
select t.ok('atomico','nada apagado', (select count(*) from cob.parcelas) = 7
  and (select status from core.tarefas where id = current_setting('t.ba')::uuid) = 'executando');
select t.erro('validador','executor não valida a si mesmo',
  format('select cob.validar_sincronizacao(%L, %L)', current_setting('t.ba'), 'cobrancas-sync'), 'validação');
select t.sync_cob(t.lote_cob());

-- E. Painel e escopo
set role anon;
select t.erro('seguranca','anon não chama o painel de cobranças', 'select public.painel_cobrancas()', 'permission');
reset role;
set role authenticated;
select t.erro('seguranca','usuário logado não lê o espelho direto', 'select count(*) from cob.parcelas', 'permission');
select t.erro('seguranca','usuário logado não chama funções do agente', 'select cob.recalcular()', 'permission');
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.ok('painel','gerente de outra unidade não vê a carteira de Campinas',
  jsonb_array_length(public.painel_cobrancas()->'carteira') = 0 and jsonb_array_length(public.painel_cobrancas()->'alertas') = 0);
select t.jwt('00000000-0000-0000-0000-00000000a001');
select t.ok('painel','carteira Asaas de Campinas: a vencer 250 (em 30 dias), vencido 250 entre 1 e 30 dias',
  (select (x->>'a_vencer_30')::numeric = 250 and (x->>'vencido_1_30')::numeric = 250 and (x->>'clientes_em_atraso')::int = 2
   from jsonb_array_elements(public.painel_cobrancas('campinas')->'carteira') x where x->>'financeira' = 'asaas'),
  public.painel_cobrancas('campinas')::text);
select t.ok('painel','Multicrédito: 200 vencido entre 31 e 60 dias',
  (select (x->>'vencido_31_60')::numeric = 200 from jsonb_array_elements(public.painel_cobrancas('campinas')->'carteira') x where x->>'financeira' = 'multicredito'));
select t.ok('painel','alertas mais graves primeiro (cobrança sem parcela)', public.painel_cobrancas()->'alertas'->0->>'tipo' = 'cobranca_sem_parcela');
reset role;
select t.sem_jwt();

select t.ok('auditoria','cadeia íntegra', core.verificar_auditoria() is null);
update core.agentes set status = 'pausado' where id = 'cobrancas';
update core.config set valor = 'false' where chave = 'cob.sync.ativo';

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DE COBRANÇAS FALHANDO'; end if; end $$;
