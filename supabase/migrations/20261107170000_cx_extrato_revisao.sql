-- =============================================================================
-- Idealize AI — Caixa e extrato: revisão pedida pelo Diego (07/11, PODE FAZER)  · Migração 20261107170000
--  1. Passo 0: o mesmo valor no mesmo dia casa primeiro (o Pix de R$ 100 de 02/10 tinha sido "pego" pelo caixa de 30/09).
--  2. Valor lançado na ENTREGA procura o Pix até 15 dias antes (cliente pagou antes, ex.: Pix de 23/10 lançado em 27/10).
--     Prazo editável: cx.entrega_antes_dias.
--  3. Extrato lido de PDF pela IA: aviso quando ficam dias úteis sem nenhuma linha (sinal de leitura incompleta) — achado
--     em 07/11: 27/10 a 04/11 entraram quase vazios. Para extrato completo e exato, o caminho é o arquivo OFX do banco.
-- =============================================================================
insert into core.config (chave, valor) values ('cx.entrega_antes_dias', '15') on conflict (chave) do nothing;

create or replace function cx.recalcular() returns jsonb
language plpgsql security definer set search_path = cx, core, pg_catalog as $$
declare d date := cx._hoje(); v_tv numeric := cx._cfg_num('cx.tolerancia_valor', 0.10);
  v_td numeric := cx._cfg_num('cx.tolerancia_dia', 1); v_folga int := cx._cfg_num('cx.folga_dias', 3)::int;
  v_dep int := cx._cfg_num('cx.deposito_prazo_dias', 3)::int; v_atr int := cx._cfg_num('cx.extrato_atraso_dias', 2)::int;
  v_antes int := cx._cfg_num('cx.entrega_antes_dias', 15)::int; v_ini date; p record; v_r text; v_r2 record; n_cas int; n_ab int; n_res int; v_fechados int[] := cx._fechados();
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
  -- passo 0: o mesmo valor no MESMO dia casa primeiro (assim um dia não "pega" o Pix do dia seguinte)
  for p in select pg.* from cx.pagamentos pg join cx.fontes_forma ff on ff.forma = pg.forma and ff.fonte in ('banco','asaas','stone')
           where pg.dia >= v_ini and pg.valor > 0 order by pg.dia, pg.valor desc, pg.id loop
    select r.recebimento into v_r from _rec r
     where not r.usado and r.unidade_id = p.unidade_id and r.forma = p.forma and abs(r.valor - p.valor) <= v_tv and r.dia = p.dia
     order by abs(r.valor - p.valor), r.parcela, r.recebimento limit 1;
    if found then
      update _rec set usado = true where recebimento = v_r;
      insert into cx.casamentos values (p.id, v_r, 'um_a_um');
    end if;
  end loop;

  for p in select pg.* from cx.pagamentos pg join cx.fontes_forma ff on ff.forma = pg.forma and ff.fonte in ('banco','asaas','stone')
           where pg.dia >= v_ini and pg.valor > 0 and not exists (select 1 from cx.casamentos c where c.pagamento_id = pg.id)
           order by pg.dia, pg.valor desc, pg.id loop
    select r.recebimento into v_r from _rec r
     where not r.usado and r.unidade_id = p.unidade_id and r.forma = p.forma and abs(r.valor - p.valor) <= v_tv
       and r.dia between case when p.origem = 'entrega' then p.dia - v_antes else cx._dia_aberto_anterior(p.dia) end and p.dia + v_folga
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
       and r1.dia between case when p.origem = 'entrega' then p.dia - v_antes else cx._dia_aberto_anterior(p.dia) end and p.dia + v_folga
       and r2.dia between case when p.origem = 'entrega' then p.dia - v_antes else cx._dia_aberto_anterior(p.dia) end and p.dia + v_folga
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

create or replace function fin._checar_leitura(p_tipo text, l jsonb) returns jsonb
language plpgsql immutable set search_path = pg_catalog as $$
declare n int; s numeric; ruins int; v_vazios text; tol numeric := 0.05; esp numeric; ok boolean; av text[] := '{}'; pg numeric;
begin
  if p_tipo = 'extrato' then
    select count(*), coalesce(sum((x->>'valor')::numeric), 0),
           count(*) filter (where x->>'data' !~ '^\d{4}-\d{2}-\d{2}$' or coalesce((x->>'valor')::numeric, 0) = 0)
      into n, s, ruins from jsonb_array_elements(coalesce(l->'linhas', '[]')) x;
    if (l->>'saldo_inicial') is not null and (l->>'saldo_final') is not null then
      esp := (l->>'saldo_final')::numeric - (l->>'saldo_inicial')::numeric;
      ok := abs(s - esp) <= 0.01;
      if not ok then av := av || ('saldo inicial + movimentos não fecha com o saldo final (diferença de ' || round(s - esp, 2) || ')'); end if;
    else ok := null; av := av || 'extrato sem saldo inicial e final: não dá para conferir o fechamento'::text; end if;
    -- leitura pela IA (PDF/foto): dia útil sem nenhuma linha entre a primeira e a última data é sinal de leitura incompleta
    if coalesce(l->>'formato', '') = 'ia' then
      select string_agg(to_char(g, 'DD/MM'), ', ' order by g) into v_vazios
        from generate_series((select min((x->>'data')::date) from jsonb_array_elements(coalesce(l->'linhas', '[]')) x where x->>'data' ~ '^\d{4}-\d{2}-\d{2}$'),
                             (select max((x->>'data')::date) from jsonb_array_elements(coalesce(l->'linhas', '[]')) x where x->>'data' ~ '^\d{4}-\d{2}-\d{2}$'),
                             interval '1 day') g
       where extract(dow from g) between 1 and 5
         and not exists (select 1 from jsonb_array_elements(coalesce(l->'linhas', '[]')) x where x->>'data' = to_char(g, 'YYYY-MM-DD'));
      if v_vazios is not null then
        av := av || ('dias úteis sem nenhuma linha lida: ' || v_vazios || ' — confira se o PDF foi lido inteiro (o arquivo OFX do banco é lido sem erro)');
      end if;
    end if;
  elsif p_tipo = 'fatura' then
    -- pagamento da fatura anterior não é compra desta fatura: fica fora da soma
    select count(*),
           coalesce(sum((x->>'valor')::numeric) filter (where not ((x->>'valor')::numeric < 0
                    and coalesce(x->>'descricao', '') ~* '^\s*(pagamento|pagto|pgto)')), 0),
           coalesce(sum((x->>'valor')::numeric) filter (where (x->>'valor')::numeric < 0
                    and coalesce(x->>'descricao', '') ~* '^\s*(pagamento|pagto|pgto)'), 0),
           count(*) filter (where x->>'data' !~ '^\d{4}-\d{2}-\d{2}$' or (x->>'valor') is null)
      into n, s, pg, ruins from jsonb_array_elements(coalesce(l->'compras', '[]')) x;
    esp := (l->>'total')::numeric;
    if esp is null then ok := null; av := av || 'fatura sem total: não dá para conferir'::text;
    else ok := abs(s - esp) <= tol;
      if not ok then av := av || ('soma das compras (' || round(s, 2) || ') não bate com o total da fatura (' || esp || ')'); end if;
    end if;
    if pg < 0 then av := av || ('pagamento da fatura anterior (' || round(-pg, 2) || ') não entra na soma'); end if;
  elsif p_tipo = 'stone' then
    select count(*), coalesce(sum((x->>'valor')::numeric), 0),
           count(*) filter (where x->>'data' !~ '^\d{4}-\d{2}-\d{2}$' or coalesce((x->>'valor')::numeric, 0) <= 0
                              or coalesce(x->>'forma', '') not in ('credito','debito','pix'))
      into n, s, ruins from jsonb_array_elements(coalesce(l->'transacoes', '[]')) x;
    esp := (l->>'total_bruto')::numeric;
    if esp is null then ok := null; av := av || 'relatório sem total bruto: não dá para conferir'::text;
    else ok := abs(s - esp) <= tol;
      if not ok then av := av || ('soma das vendas (' || round(s, 2) || ') não bate com o total do relatório (' || esp || ')'); end if;
    end if;
  elsif p_tipo in ('comprovante','boleto','nota') then
    select count(*), coalesce(sum((x->>'valor')::numeric), 0), count(*) filter (where coalesce((x->>'valor')::numeric, 0) <= 0)
      into n, s, ruins from jsonb_array_elements(coalesce(l->'itens', '[]')) x;
    ok := n > 0 and ruins = 0;
  else
    return jsonb_build_object('ok', false, 'itens', 0, 'avisos', jsonb_build_array('não reconheci como documento financeiro'));
  end if;
  if ruins > 0 then ok := false; av := av || (ruins || ' linha(s) sem data ou valor legível'); end if;
  if n = 0 then ok := false; av := av || 'nenhuma linha lida'::text; end if;
  return jsonb_build_object('ok', ok, 'itens', n, 'soma', round(s, 2), 'esperado', esp, 'avisos', to_jsonb(av));
end $$;

do $$ declare f text; begin
  foreach f in array array['cx.recalcular()'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', f); end if;
  end loop;
end $$;

-- refaz a conferência dos envios ainda para conferir e o caixa
update fin.envios set checagens = fin._checar_leitura(tipo, leitura), atualizado_em = now() where status = 'conferir' and tipo = 'extrato';
select cx.recalcular();
