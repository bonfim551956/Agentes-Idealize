-- Pendências resolvidas pelo painel e fatura juntada pelo vencimento (pedido 07/11; dados 100% sintéticos)
\set ON_ERROR_STOP on
delete from t.resultados;

set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.fj', t.ini('fatura_parcelas.pdf', 'fatura', 'env_cart', 'fat-junta')::text, false);
reset role;
select t.sem_jwt();
update core.agentes set status = 'ativo' where id = 'financeiro';
update core.config set valor = 'true' where chave = 'fin.envios.ativo';
select fin.envio_arquivo_recebido(t.id('t.fj'), 1000, t.h64('fat-junta'));
select fin.agendar_envios();
-- compras de vários meses (parcelas antigas) na MESMA fatura, que vence em 25/10/2026
select t.ler('t.fj', jsonb_build_object('tipo','fatura','formato','ia','total', 1000, 'vencimento', '2026-10-25', 'compras', jsonb_build_array(
  jsonb_build_object('data', '2026-01-10', 'descricao', 'LOJA PARCELADA', 'valor', 100, 'parcela', '10/10', 'categoria', 'laboratorio'),
  jsonb_build_object('data', '2026-04-13', 'descricao', 'Mp Mercadolivre', 'valor', 150, 'parcela', '06/10'),
  jsonb_build_object('data', '2026-09-30', 'descricao', 'Hotel Teste Centro', 'valor', 200),
  jsonb_build_object('data', '2026-10-02', 'descricao', 'Hotel Teste Centro', 'valor', 180),
  jsonb_build_object('data', '2026-09-14', 'descricao', 'Zapi Teste', 'valor', 100, 'categoria', 'laboratorio'),
  jsonb_build_object('data', '2026-09-14', 'descricao', 'Zapi Teste', 'valor', 100, 'categoria', 'laboratorio'),
  jsonb_build_object('data', '2026-09-14', 'descricao', 'Zapi Teste', 'valor', 100, 'categoria', 'laboratorio'),
  jsonb_build_object('data', '2026-09-20', 'descricao', 'Cobranca Dobrada', 'valor', 35, 'categoria', 'laboratorio'),
  jsonb_build_object('data', '2026-09-20', 'descricao', 'Cobranca Dobrada', 'valor', 35, 'categoria', 'laboratorio'))));
update core.config set valor = 'false' where chave = 'fin.envios.ativo';
set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.cj', public.painel_envio_confirmar(t.id('t.fj'), null, '{}')::text, false);
reset role;
select t.sem_jwt();

select t.ok('fatura_junta','compras de jan, abr, set e out vão TODAS para a fatura do vencimento (outubro)',
  (select count(distinct l.fatura_id) from fin.lancamentos l join fin.envios e on e.id = t.id('t.fj') and l.criado_em = e.decidido_em
     where l.conta_id = 'env_cart' and l.status <> 'cancelado') = 1
  and (select count(*) from fin.lancamentos l join fin.envios e on e.id = t.id('t.fj') and l.criado_em = e.decidido_em where l.conta_id = 'env_cart') = 9
  and (select competencia from fin.faturas_cartao where id = (current_setting('t.cj')::jsonb->'resultado'->>'fatura')::uuid) = '2026-10-01',
  current_setting('t.cj'));
select t.ok('fatura_junta','total da fatura = soma das compras do documento',
  (select valor_total from fin.faturas_cartao where id = (current_setting('t.cj')::jsonb->'resultado'->>'fatura')::uuid) = 1000);
select t.ok('fatura_junta','não sobra fatura vazia de janeiro ou abril',
  not exists (select 1 from fin.faturas_cartao where conta_id = 'env_cart' and competencia in ('2026-01-01','2026-04-01')));

-- conserto de compras já penduradas na fatura errada
do $$ declare v_ids uuid[]; v_f uuid; begin
  insert into fin.faturas_cartao (conta_id, competencia, vencimento, valor_total) values ('env_cart', '2025-03-01', '2025-04-10', 0);
  select array_agg(id) into v_ids from fin.lancamentos where conta_id = 'env_cart' and descricao like 'LOJA PARCELADA%';
  update fin.faturas_cartao set valor_total = valor_total - 100 where id = (select fatura_id from fin.lancamentos where id = v_ids[1]);
  update fin.lancamentos set fatura_id = (select id from fin.faturas_cartao where conta_id = 'env_cart' and competencia = '2025-03-01') where id = v_ids[1];
  update fin.faturas_cartao set valor_total = 100 where conta_id = 'env_cart' and competencia = '2025-03-01';
  v_f := fin._juntar_na_fatura(v_ids, 'env_cart', '2026-10-25');
  perform t.ok('fatura_junta','conserto move a compra de volta e apaga a fatura que ficou vazia',
    (select fatura_id from fin.lancamentos where id = v_ids[1]) = v_f
    and not exists (select 1 from fin.faturas_cartao where conta_id = 'env_cart' and competencia = '2025-03-01')
    and (select valor_total from fin.faturas_cartao where id = v_f) = 1000);
end $$;

-- pendências: contexto para decidir
select set_config('t.pid_hotel', (select p.id from fin.pendencias p join fin.lancamentos l on l.id = p.lancamento_id
  where p.status = 'aberta' and p.tipo = 'sem_classificacao' and l.descricao = 'Hotel Teste Centro' order by l.numero limit 1)::text, false);
select set_config('t.pid_zapi', (select p.id from fin.pendencias p join fin.lancamentos l on l.id = p.lancamento_id
  where p.status = 'aberta' and p.tipo = 'duplicidade_suspeita' and l.descricao = 'Zapi Teste' order by l.numero limit 1)::text, false);
select set_config('t.pid_dobro', (select p.id from fin.pendencias p join fin.lancamentos l on l.id = p.lancamento_id
  where p.status = 'aberta' and p.tipo = 'duplicidade_suspeita' and l.descricao = 'Cobranca Dobrada' limit 1)::text, false);
select t.ok('pendencias','fatura gerou 2 pendências do hotel, 2 de duplicidade da Z-API e 1 da cobrança dobrada',
  (select count(*) from fin.pendencias p join fin.lancamentos l on l.id = p.lancamento_id where p.status = 'aberta' and p.tipo = 'sem_classificacao' and l.descricao = 'Hotel Teste Centro') = 2
  and (select count(*) from fin.pendencias p join fin.lancamentos l on l.id = p.lancamento_id where p.status = 'aberta' and p.tipo = 'duplicidade_suspeita' and l.descricao = 'Zapi Teste') = 2
  and current_setting('t.pid_dobro') <> '');

set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.lista', public.painel_pendencias('env_a')::text, false);
select t.ok('pendencias','duplicidade mostra os 3 lançamentos parecidos, com o desta pendência marcado',
  (select jsonb_array_length(x->'parecidos') = 3 and (select count(*) from jsonb_array_elements(x->'parecidos') y where (y->>'este')::boolean) = 1
     from jsonb_array_elements(current_setting('t.lista')::jsonb) x where (x->>'id')::bigint = current_setting('t.pid_zapi')::bigint));
select t.ok('pendencias','card traz conta e fornecedor do lançamento',
  (select x->'lancamento'->>'conta' = 'Cartão Envio' and x->'lancamento'->>'fornecedor' = 'Hotel Teste Centro'
     from jsonb_array_elements(current_setting('t.lista')::jsonb) x where (x->>'id')::bigint = current_setting('t.pid_hotel')::bigint));
select t.ok('pendencias','lista de categorias de despesa para escolher', jsonb_array_length(public.painel_categorias('despesa')) > 0);

select t.erro('decidir','categoria inexistente é recusada',
  format('select public.painel_pendencia_decidir(%s, %L, %L)', current_setting('t.pid_hotel'), 'categoria', 'nao_existe'), 'escolha uma categoria');
select t.erro('decidir','"são diferentes" não vale para pendência de categoria',
  format('select public.painel_pendencia_decidir(%s, %L)', current_setting('t.pid_hotel'), 'diferentes'), 'possível duplicidade');
select set_config('t.r1', public.painel_pendencia_decidir(current_setting('t.pid_hotel')::bigint, 'categoria', 'laboratorio', true)::text, false);
reset role;
select t.ok('decidir','categoria escolhida com "usar sempre": resolve as 2 do hotel e cria a regra do fornecedor',
  (current_setting('t.r1')::jsonb->>'resolvidas')::int = 2
  and not exists (select 1 from fin.pendencias p join fin.lancamentos l on l.id = p.lancamento_id where p.status = 'aberta' and l.descricao = 'Hotel Teste Centro')
  and (select bool_and(categoria_id = 'laboratorio') from fin.lancamentos where descricao = 'Hotel Teste Centro')
  and fin.categoria_por_regra(null, 'HOTEL TESTE CENTRO 03/05', 'debito', current_date) = 'laboratorio', current_setting('t.r1'));

set role authenticated;
select t.jwt('00000000-0000-0000-0000-00000000a002');
select t.erro('decidir','gerente de outra loja não decide pendência desta loja',
  format('select public.painel_pendencia_decidir(%s, %L)', current_setting('t.pid_zapi'), 'diferentes'));
select t.jwt('00000000-0000-0000-0000-00000000a001');
select set_config('t.r2', public.painel_pendencia_decidir(current_setting('t.pid_zapi')::bigint, 'diferentes')::text, false);
select set_config('t.r3', public.painel_pendencia_decidir(current_setting('t.pid_dobro')::bigint, 'repetida')::text, false);
select t.erro('decidir','pendência já decidida não é decidida de novo',
  format('select public.painel_pendencia_decidir(%s, %L)', current_setting('t.pid_dobro'), 'repetida'), 'não está aberta');
reset role;
select t.sem_jwt();
select t.ok('decidir','"são diferentes": encerra as 2 da Z-API como aceitas e mantém os 3 lançamentos',
  (current_setting('t.r2')::jsonb->>'resolvidas')::int = 2
  and not exists (select 1 from fin.pendencias p join fin.lancamentos l on l.id = p.lancamento_id where p.status = 'aberta' and l.descricao = 'Zapi Teste')
  and (select count(*) from fin.lancamentos where descricao = 'Zapi Teste' and status <> 'cancelado') = 3);
select t.ok('decidir','"é repetida": cancela o lançamento e tira o valor da fatura',
  (select count(*) from fin.lancamentos where descricao = 'Cobranca Dobrada' and status = 'cancelado') = 1
  and (select valor_total from fin.faturas_cartao where id = (current_setting('t.cj')::jsonb->'resultado'->>'fatura')::uuid) = 1000 - 35,
  current_setting('t.r3'));
select t.ok('decidir','decisões ficam na auditoria', (select count(*) from core.auditoria where acao = 'pendencia_decidida') = 3);
select t.ok('auditoria','cadeia íntegra ao final', core.verificar_auditoria() is null);

\pset footer off
select grupo, teste, case when ok then 'PASS' else 'FAIL' end as r, left(coalesce(detalhe,''),80) as detalhe from t.resultados order by n;
select count(*) filter (where ok) as pass, count(*) filter (where not ok) as fail from t.resultados;
do $$ begin if exists (select 1 from t.resultados where not ok) then raise exception 'HÁ TESTES DE PENDÊNCIAS FALHANDO'; end if; end $$;
