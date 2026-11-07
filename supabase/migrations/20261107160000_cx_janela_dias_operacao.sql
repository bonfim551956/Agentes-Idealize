-- =============================================================================
-- Idealize AI — Caixa: janela pelos dias de operação, Pix em dois, Asaas e Multicrediário no fechamento  · 20261107160000
-- Pedido do Diego (07/11, PODE FAZER):
--  1. O valor do caixa é procurado no extrato desde o último dia em que a loja abriu antes dele (Pix do sábado que entrou
--     no caixa de segunda casa) até N dias depois (cx.folga_dias).
--  2. Um lançamento do caixa = dois créditos (cliente pagou em dois Pix: 540 + 60 = 600), além do contrário (já existia).
--  3. Parcela de carnê paga pelo Asaas também confere com o lançamento "Asaas" do caixa (antes era ignorada).
--     Parcela paga direto pelo cliente (sem passar no caixa) não vira "sem registro no caixa".
--  4. Crédito/débito/Asaas só cobrados a partir do primeiro dia que a fonte tem (Stone começou em 02/11: os dias anteriores
--     davam "não achado" falso).
--  5. Todo aviso de dinheiro traz o dia da semana e se a loja estava fechada nesse dia.
--  6. Multicrediário no fechamento: por dia, as vendas aprovadas no Multicrediário (valor da venda) × o que o caixa lançou
--     como Multicrediário (tirando as parcelas recebidas na loja). Diferença vira aviso "multi_divergente".
--  7. Relatório do dia avisa Pix/Asaas que entrou sem registro no caixa e divergência do Multicrediário.
-- =============================================================================
alter table cx.alertas drop constraint if exists alertas_tipo_check;
alter table cx.alertas add constraint alertas_tipo_check check (tipo in ('nao_encontrado','sem_registro_no_caixa','caixa_nao_fechado',
  'caixa_inconsistente','dinheiro_sem_deposito','extrato_atrasado','multi_divergente'));

alter table cx.casamentos drop constraint if exists casamentos_modo_check;
alter table cx.casamentos add constraint casamentos_modo_check check (modo in ('um_a_um','dois_em_um','um_em_dois'));

-- todos os créditos que podem casar com o caixa (inclui parcela de carnê paga pelo Asaas)
create or replace view cx.v_recebimentos_todos as
select recebimento, unidade_id, dia, forma, valor, fonte from cx.v_recebimentos
union all
select id, unidade_id, dia, forma, valor, fonte from cx.recebimentos where parcela_crediario;
revoke all on cx.v_recebimentos_todos from public;

create or replace function cx._fechados() returns int[] language sql stable set search_path = core, pg_catalog as $$
  select coalesce(array_agg(x::int), '{}') from unnest(string_to_array(core.cfg('cx.dias_sem_expediente', '0'), ',')) x where btrim(x) ~ '^[0-6]$'
$$;

-- último dia em que a loja abriu ANTES de d (pula os dias sem expediente)
create or replace function cx._dia_aberto_anterior(d date) returns date language sql stable set search_path = cx, pg_catalog as $$
  select coalesce((select g::date from generate_series(d - 1, d - 7, interval '-1 day') g
                    where not (extract(dow from g)::int = any(cx._fechados())) limit 1), d - 1)
$$;

create or replace function cx._dia_semana(d date) returns text language sql immutable set search_path = pg_catalog as $$
  select (array['domingo','segunda','terça','quarta','quinta','sexta','sábado'])[extract(dow from d)::int + 1]
$$;

create or replace function cx.recalcular() returns jsonb
language plpgsql security definer set search_path = cx, core, pg_catalog as $$
declare d date := cx._hoje(); v_tv numeric := cx._cfg_num('cx.tolerancia_valor', 0.10);
  v_td numeric := cx._cfg_num('cx.tolerancia_dia', 1); v_folga int := cx._cfg_num('cx.folga_dias', 3)::int;
  v_dep int := cx._cfg_num('cx.deposito_prazo_dias', 3)::int; v_atr int := cx._cfg_num('cx.extrato_atraso_dias', 2)::int;
  v_ini date; p record; v_r text; v_r2 record; n_cas int; n_ab int; n_res int; v_fechados int[] := cx._fechados();
begin
  select coalesce(min(dia), d) into v_ini from cx.dias;
  v_ini := greatest(v_ini, d - 60);

  -- recebimentos elegíveis na janela (fixos durante o cálculo); parcela de carnê entra só para casar com o caixa
  drop table if exists _rec;
  create temp table _rec on commit drop as
    select r.recebimento, r.unidade_id, r.dia, r.forma, r.valor, false as parcela, false as usado
      from cx.v_recebimentos r where r.dia >= v_ini - 7
    union all
    select x.id, x.unidade_id, x.dia, x.forma, x.valor, true, false
      from cx.recebimentos x where x.parcela_crediario and x.dia >= v_ini - 7;
  create index on _rec (unidade_id, forma, valor);

  delete from cx.casamentos where true;

  -- 1º passo: um valor do caixa = um crédito (mesmo valor; do último dia aberto antes até N dias depois)
  for p in select pg.* from cx.pagamentos pg join cx.fontes_forma ff on ff.forma = pg.forma and ff.fonte in ('banco','asaas','stone')
           where pg.dia >= v_ini and pg.valor > 0 order by pg.dia, pg.valor desc, pg.id loop
    select r.recebimento into v_r from _rec r
     where not r.usado and r.unidade_id = p.unidade_id and r.forma = p.forma and abs(r.valor - p.valor) <= v_tv
       and r.dia between cx._dia_aberto_anterior(p.dia) and p.dia + v_folga
     order by abs(r.dia - p.dia), r.parcela, r.recebimento limit 1;
    if found then
      update _rec set usado = true where recebimento = v_r;
      insert into cx.casamentos values (p.id, v_r, 'um_a_um');
    end if;
  end loop;

  -- 2º passo: dois valores do caixa (mesma loja, forma e dia) = um crédito só
  for v_r2 in
    select r.recebimento, r.unidade_id, r.forma, r.dia, r.valor from _rec r where not r.usado order by r.dia, r.recebimento loop
    select a.id ia, b.id ib into p
      from cx.pagamentos a join cx.pagamentos b on b.unidade_id = a.unidade_id and b.forma = a.forma and b.dia = a.dia and b.id > a.id
     where a.unidade_id = v_r2.unidade_id and a.forma = v_r2.forma and a.dia between v_r2.dia - v_folga and v_r2.dia + 7
       and v_r2.dia >= cx._dia_aberto_anterior(a.dia)
       and a.dia >= v_ini and abs(a.valor + b.valor - v_r2.valor) <= v_tv
       and not exists (select 1 from cx.casamentos c where c.pagamento_id in (a.id, b.id))
     order by abs(a.dia - v_r2.dia), a.id limit 1;
    if found then
      update _rec set usado = true where recebimento = v_r2.recebimento;
      insert into cx.casamentos values (p.ia, v_r2.recebimento, 'dois_em_um'), (p.ib, v_r2.recebimento, 'dois_em_um');
    end if;
  end loop;

  -- 3º passo: um valor do caixa = dois créditos (cliente pagou em duas vezes)
  for p in select pg.* from cx.pagamentos pg join cx.fontes_forma ff on ff.forma = pg.forma and ff.fonte in ('banco','asaas','stone')
           where pg.dia >= v_ini and pg.valor > 0 and not exists (select 1 from cx.casamentos c where c.pagamento_id = pg.id)
           order by pg.dia, pg.valor desc, pg.id loop
    select r1.recebimento r1, r2.recebimento r2 into v_r2 from _rec r1 join _rec r2
        on r2.unidade_id = r1.unidade_id and r2.forma = r1.forma and r2.recebimento > r1.recebimento and not r2.usado
     where not r1.usado and r1.unidade_id = p.unidade_id and r1.forma = p.forma
       and r1.dia between cx._dia_aberto_anterior(p.dia) and p.dia + v_folga
       and r2.dia between cx._dia_aberto_anterior(p.dia) and p.dia + v_folga
       and abs(r1.valor + r2.valor - p.valor) <= v_tv
     order by abs(r1.dia - p.dia) + abs(r2.dia - p.dia), r1.recebimento limit 1;
    if found then
      update _rec set usado = true where recebimento in (v_r2.r1, v_r2.r2);
      insert into cx.casamentos values (p.id, v_r2.r1 || '+' || v_r2.r2, 'um_em_dois');   -- os dois créditos, separados por +
    end if;
  end loop;
  select count(*) into n_cas from cx.casamentos;

  -- Alertas devidos
  drop table if exists _devidos;
  create temp table _devidos (tipo text, referencia text, unidade_id text, dia date, detalhe jsonb) on commit drop;

  -- valores do caixa não achados, só quando a fonte já cobre o dia + folga e só a partir do 1º dia que a fonte tem
  insert into _devidos
  select 'nao_encontrado', pg.unidade_id || ':' || pg.dia || ':' || pg.forma, pg.unidade_id, pg.dia,
         jsonb_build_object('forma', pg.forma, 'rotulo', ff.rotulo, 'fonte', ff.fonte, 'quantidade', count(*), 'valor', sum(pg.valor),
                            'valores', jsonb_agg(pg.valor order by pg.valor desc), 'dia_semana', cx._dia_semana(pg.dia))
  from cx.pagamentos pg join cx.fontes_forma ff on ff.forma = pg.forma
  where pg.dia >= v_ini and pg.valor > 0 and ff.fonte in ('banco','asaas','stone')
    and not exists (select 1 from cx.casamentos c where c.pagamento_id = pg.id)
    and pg.dia + v_folga <= case ff.fonte
          when 'banco' then (select max(m.data) from fin.movimentos m join fin.contas c on c.id = m.conta_id
                             where c.unidade_id = pg.unidade_id and c.tipo = 'corrente')
          else (select co.ate from cx.cobertura co where co.fonte = ff.fonte and co.unidade_id = pg.unidade_id) end
    and pg.dia >= coalesce(case ff.fonte
          when 'banco' then (select min(m.data) from fin.movimentos m join fin.contas c on c.id = m.conta_id
                             where c.unidade_id = pg.unidade_id and c.tipo = 'corrente')
          else (select min(x.dia) from cx.recebimentos x where x.fonte = ff.fonte and x.unidade_id = pg.unidade_id) end, '9999-12-31'::date)
  group by pg.unidade_id, pg.dia, pg.forma, ff.rotulo, ff.fonte;

  -- dinheiro que entrou (Pix no banco, Asaas, Stone) e não está em nenhum fechamento — com o dia da semana
  insert into _devidos
  select 'sem_registro_no_caixa', r.unidade_id || ':' || r.dia || ':' || r.forma || ':extrato', r.unidade_id, r.dia,
         jsonb_build_object('forma', r.forma, 'rotulo', (select rotulo from cx.fontes_forma where forma = r.forma),
                            'quantidade', count(*), 'valor', sum(r.valor), 'valores', jsonb_agg(r.valor order by r.valor desc),
                            'dia_semana', cx._dia_semana(r.dia), 'loja_fechada', extract(dow from r.dia)::int = any(v_fechados))
  from _rec r
  where not r.usado and not r.parcela and r.dia >= v_ini and r.dia <= d - v_folga - 1
    and exists (select 1 from cx.dias x where x.unidade_id = r.unidade_id)
  group by r.unidade_id, r.dia, r.forma;

  -- dia útil sem fechamento no ADM (a partir do primeiro fechamento lido da loja; não conta hoje)
  insert into _devidos
  select 'caixa_nao_fechado', u.unidade_id || ':' || g.dia::date, u.unidade_id, g.dia::date,
         jsonb_build_object('dia', g.dia::date, 'dia_semana', cx._dia_semana(g.dia::date))
  from (select unidade_id, min(dia) ini from cx.dias group by unidade_id) u
  cross join lateral generate_series(greatest(u.ini, d - 14), d - 1, interval '1 day') g(dia)
  where not (extract(dow from g.dia)::int = any(v_fechados))
    and not exists (select 1 from cx.dias x where x.unidade_id = u.unidade_id and x.dia = g.dia::date);

  -- total do caixa diferente da soma das formas
  insert into _devidos
  select 'caixa_inconsistente', x.unidade_id || ':' || x.dia, x.unidade_id, x.dia,
         jsonb_build_object('caixa', x.caixa, 'soma_formas', x.soma_formas, 'diferenca', x.caixa - x.soma_formas, 'dia_semana', cx._dia_semana(x.dia))
  from cx.dias x where x.dia >= v_ini and x.caixa is not null and abs(x.caixa - x.soma_formas) > v_td;

  -- dinheiro recebido sem depósito registrado no prazo
  insert into _devidos
  select 'dinheiro_sem_deposito', x.unidade_id || ':' || x.dia, x.unidade_id, x.dia,
         jsonb_build_object('dinheiro', s.valor, 'prazo_dias', v_dep, 'dia_semana', cx._dia_semana(x.dia))
  from cx.dias x join lateral (select sum(valor) valor from cx.pagamentos pg where pg.unidade_id = x.unidade_id and pg.dia = x.dia and pg.forma = 'dinheiro') s on true
  where x.dia >= v_ini and x.dia <= d - v_dep and coalesce(s.valor, 0) > 0 and x.deposito_valor is null;

  -- Multicrediário no fechamento: vendas aprovadas (valor da venda) × caixa "Multicrediário" sem as parcelas recebidas na loja
  if to_regclass('multi.v_operacoes') is not null then
    insert into _devidos
    select 'multi_divergente', q.unidade_id || ':' || q.dia, q.unidade_id, q.dia,
           jsonb_build_object('caixa_vendas', q.caixa_vendas, 'multi_vendas', q.multi_vendas, 'diferenca', q.caixa_vendas - q.multi_vendas,
                              'parcelas_no_caixa', q.parcelas, 'vendas_multi', q.n_multi, 'dia_semana', cx._dia_semana(q.dia))
    from (
      select x.unidade_id, x.dia,
             coalesce((select sum(pg.valor) from cx.pagamentos pg where pg.unidade_id = x.unidade_id and pg.dia = x.dia and pg.forma = 'crediario'
                        and not exists (select 1 from multi.v_recebidas rr where rr.loja = x.unidade_id and abs(rr.valor - pg.valor) <= v_tv
                                          and rr.dia between x.dia - 3 and x.dia + 1)), 0) caixa_vendas,
             coalesce((select sum(pg.valor) from cx.pagamentos pg where pg.unidade_id = x.unidade_id and pg.dia = x.dia and pg.forma = 'crediario'
                        and exists (select 1 from multi.v_recebidas rr where rr.loja = x.unidade_id and abs(rr.valor - pg.valor) <= v_tv
                                      and rr.dia between x.dia - 3 and x.dia + 1)), 0) parcelas,
             coalesce((select sum(o.valor_venda) from multi.v_operacoes o where o.tipo = 1 and o.loja = x.unidade_id and o.dia = x.dia), 0) multi_vendas,
             (select count(*) from multi.v_operacoes o where o.tipo = 1 and o.loja = x.unidade_id and o.dia = x.dia) n_multi
        from cx.dias x
       where x.dia >= v_ini and x.dia < d
         and exists (select 1 from multi.capturas c where c.loja = x.unidade_id and c.relatorio = 'operacao_detalhe')
         and x.dia between (select min(c.dia) from multi.capturas c where c.loja = x.unidade_id and c.relatorio = 'operacao_detalhe')
                       and (select max(c.capturado_em)::date - 1 from multi.capturas c where c.loja = x.unidade_id and c.relatorio = 'operacao')) q
    where abs(q.caixa_vendas - q.multi_vendas) > v_td;
  end if;

  -- extrato atrasado: a loja tem fechamento recente e a fonte não foi lida há mais de N dias
  insert into _devidos
  select 'extrato_atrasado', u.unidade_id || ':' || f.fonte, u.unidade_id, null,
         jsonb_build_object('fonte', f.fonte, 'ultimo_dia', f.ate, 'limite_dias', v_atr)
  from (select distinct unidade_id from cx.dias where dia >= d - 7) u
  cross join lateral (
    select 'banco'::text fonte, (select max(m.data) from fin.movimentos m join fin.contas c on c.id = m.conta_id
                                 where c.unidade_id = u.unidade_id and c.tipo = 'corrente') ate
    where exists (select 1 from fin.contas c where c.unidade_id = u.unidade_id and c.tipo = 'corrente' and c.ativo)
    union all
    select co.fonte, co.ate from cx.cobertura co where co.unidade_id = u.unidade_id) f
  where coalesce(f.ate, '1900-01-01') < d - v_atr;

  insert into cx.alertas (tipo, referencia, unidade_id, dia, detalhe)
  select tipo, referencia, unidade_id, dia, detalhe from _devidos
  on conflict (tipo, referencia) where status = 'aberto'
  do update set detalhe = excluded.detalhe;
  get diagnostics n_ab = row_count;

  update cx.alertas a set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente_caixa: situação deixou de existir'
   where a.status = 'aberto' and not exists (select 1 from _devidos x where x.tipo = a.tipo and x.referencia = a.referencia);
  get diagnostics n_res = row_count;
  return jsonb_build_object('casados', n_cas, 'ativos', n_ab, 'resolvidos', n_res);
end $$;

do $$ declare f text; begin
  foreach f in array array['cx._fechados()', 'cx._dia_aberto_anterior(date)', 'cx._dia_semana(date)', 'cx.recalcular()'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', f); end if;
  end loop;
end $$;

-- Relatório do dia: dinheiro sem registro no caixa e Multicrediário divergente (inserido nas prioridades)
do $$ declare v text;
begin
  v := pg_get_functiondef('rel.gerar(date)'::regprocedure);
  if v !~ 'sem_registro_no_caixa' then
    v := replace(v, $q$    select 80, 'Caixa', rel._unidade(unidade_id)$q$,
      $q$    select 81, 'Caixa', rel._unidade(unidade_id), format('Dinheiro que entrou sem registro no caixa: %s', string_agg(format('%s R$ %s em %s (%s%s)',
             detalhe->>'rotulo', replace(detalhe->>'valor', '.', ','), to_char(dia, 'DD/MM'), detalhe->>'dia_semana',
             case when (detalhe->>'loja_fechada')::boolean then ', loja fechada' else '' end), '; ' order by dia)), '/caixa'
      from cx.alertas where status = 'aberto' and tipo = 'sem_registro_no_caixa' group by unidade_id
    union all
    select 79, 'Caixa', rel._unidade(unidade_id), format('Multicrediário × caixa diferente em %s dia(s): %s', count(*),
             string_agg(format('%s (%s): caixa R$ %s × Multi R$ %s', to_char(dia, 'DD/MM'), detalhe->>'dia_semana',
             replace(detalhe->>'caixa_vendas', '.', ','), replace(detalhe->>'multi_vendas', '.', ',')), '; ' order by dia)), '/caixa'
      from cx.alertas where status = 'aberto' and tipo = 'multi_divergente' group by unidade_id
    union all
    select 80, 'Caixa', rel._unidade(unidade_id)$q$);
    if v !~ 'sem registro no caixa' then raise exception 'relatório do dia não foi atualizado'; end if;
    execute v;
  end if;
end $$;

-- validador independente: aceita crédito de parcela e o casamento "um em dois"; só cobra o Asaas a partir do 1º dia lido
do $$ declare v text;
begin
  v := pg_get_functiondef('cx.validar_sincronizacao(uuid,text)'::regprocedure);
  v := replace(v, 'where not exists (select 1 from cx.v_recebimentos r where r.recebimento = c.recebimento and r.unidade_id = pg.unidade_id and r.forma = pg.forma);',
                  'where not exists (select 1 from cx.v_recebimentos_todos r where r.recebimento = any(string_to_array(c.recebimento, ''+'')) and r.unidade_id = pg.unidade_id and r.forma = pg.forma);');
  v := replace(v, 'where pg.valor > 0 and pg.dia >= cx._hoje() - 60 and',
                  'where pg.valor > 0 and pg.dia >= cx._hoje() - 60 and pg.dia >= (select min(x.dia) from cx.recebimentos x where x.fonte = ''asaas'' and x.unidade_id = pg.unidade_id) and');
  if v !~ 'v_recebimentos_todos' then raise exception 'validador do caixa não foi atualizado'; end if;
  execute v;
end $$;

select cx.recalcular();
