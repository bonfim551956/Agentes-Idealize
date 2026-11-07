-- =============================================================================
-- Idealize AI — Multicrediário × caixa conferido VENDA A VENDA  · Migração 20261107220000
-- Pedido do Diego (07/11, PODE FAZER): "a conferência deve ser sempre venda a venda" — inclusive quando a venda entra
-- no Multicrediário num dia e é lançada no caixa em outro.
-- Antes: total do dia no Multicrediário × total do dia no caixa (aviso "multi_divergente" nos dois dias).
-- Agora cada venda aprovada no Multicrediário procura o seu lançamento "Multicrediário" no caixa:
--   1. mesmo dia, mesmo valor (um lançamento, ou dois/três que somam a venda);
--   2. de N dias antes a N dias depois (cx.multi_dias_antes / cx.multi_dias_depois), mesmo valor;
--   3. valor parecido (até cx.multi_dif_max) → "valor diferente", com os dois valores.
-- Avisos: venda não lançada no caixa · valor diferente · lançada em outro dia (informativo, com as duas datas) ·
-- lançamento "Multicrediário" no caixa sem venda nem parcela recebida no Multicrediário.
-- Os prazos e a diferença ficam editáveis na tela Multicrediário (Regras).
-- =============================================================================
alter table cx.alertas drop constraint if exists alertas_tipo_check;
alter table cx.alertas add constraint alertas_tipo_check check (tipo in ('nao_encontrado','sem_registro_no_caixa','caixa_nao_fechado',
  'caixa_inconsistente','dinheiro_sem_deposito','extrato_atrasado','multi_divergente','deposito_nao_encontrado','deposito_sem_caixa',
  'multi_sem_caixa','multi_valor_diferente','multi_outro_dia','caixa_multi_sem_venda'));

insert into core.config (chave, valor) values
  ('cx.multi_dias_antes', '3'),     -- o caixa pode ter lançado a venda até N dias ANTES de ela aparecer no Multicrediário
  ('cx.multi_dias_depois', '7'),    -- ... ou até N dias DEPOIS
  ('cx.multi_dif_max', '100')       -- até esta diferença (R$) a venda casa como "valor diferente"; acima, fica sem par
on conflict (chave) do nothing;

create table if not exists cx.multi_casamentos (      -- resultado da conferência venda a venda (recalculado)
  unidade_id  text not null,
  venda       text not null,                          -- nº da venda no Multicrediário
  venda_dia   date not null,
  valor_multi numeric(14,2) not null,
  caixa_dia   date not null,
  valor_caixa numeric(14,2) not null,
  pagamentos  bigint[] not null,                      -- lançamentos do caixa (cx.pagamentos)
  modo        text not null check (modo in ('mesmo_dia','outro_dia','valor_diferente')),
  primary key (unidade_id, venda)
);
alter table cx.multi_casamentos enable row level security; alter table cx.multi_casamentos force row level security;
do $$ begin
  revoke all on cx.multi_casamentos from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on cx.multi_casamentos from anon, authenticated'; end if;
end $$;

-- procura no caixa (tabela temporária _mc) 1, 2 ou 3 lançamentos do mesmo dia que somam o valor da venda
create or replace function cx._multi_achar(p_un text, p_dia date, p_vv numeric, p_gar numeric, p_k int, p_ini date, p_fim date, p_tol numeric)
returns bigint[] language plpgsql volatile set search_path = cx, pg_catalog as $$
declare r bigint[];
begin
  select c.ids into r from (
    select array[a.id] ids, a.valor s, a.dia cd from _mc a
     where not a.usado and a.unidade_id = p_un and a.dia between p_ini and p_fim and p_k = 1
    union all
    select array[a.id, b.id], a.valor + b.valor, a.dia from _mc a join _mc b on b.unidade_id = a.unidade_id and b.dia = a.dia and b.id > a.id and not b.usado
     where not a.usado and a.unidade_id = p_un and a.dia between p_ini and p_fim and p_k = 2
    union all
    select array[a.id, b.id, e.id], a.valor + b.valor + e.valor, a.dia from _mc a
      join _mc b on b.unidade_id = a.unidade_id and b.dia = a.dia and b.id > a.id and not b.usado
      join _mc e on e.unidade_id = a.unidade_id and e.dia = a.dia and e.id > b.id and not e.usado
     where not a.usado and a.unidade_id = p_un and a.dia between p_ini and p_fim and p_k = 3
  ) c
  where least(abs(c.s - p_vv), abs(c.s - coalesce(p_gar, p_vv))) <= p_tol
  order by least(abs(c.s - p_vv), abs(c.s - coalesce(p_gar, p_vv))), abs(c.cd - p_dia), (c.cd < p_dia), c.ids[1]
  limit 1;
  return r;
end $$;

-- chamada de dentro de cx.recalcular(): usa a tabela temporária _devidos
create or replace function cx._conferir_multi(p_ini date, p_hoje date) returns int
language plpgsql security definer set search_path = cx, core, pg_catalog as $$
declare v_tv numeric := cx._cfg_num('cx.tolerancia_valor', 0.10);
  v_a int := cx._cfg_num('cx.multi_dias_antes', 3)::int; v_d int := cx._cfg_num('cx.multi_dias_depois', 7)::int;
  v_dif numeric := cx._cfg_num('cx.multi_dif_max', 100);
  x record; ps record; v_ids bigint[]; v_r bigint; n int := 0;
begin
  delete from _devidos where tipo = 'multi_divergente';     -- o aviso pelo total do dia sai: agora é venda a venda
  delete from cx.multi_casamentos where true;
  if to_regclass('multi.v_operacoes') is null then return 0; end if;

  -- período em que o Multicrediário foi lido, por loja
  drop table if exists _cob;
  create temp table _cob on commit drop as
    select c.loja unidade_id, min(c.dia) ini,
           (select max(k.capturado_em)::date - 1 from multi.capturas k where k.loja = c.loja and k.relatorio = 'operacao') fim
      from multi.capturas c where c.relatorio = 'operacao_detalhe' group by c.loja;
  delete from _cob where fim is null or not exists (select 1 from cx.dias d where d.unidade_id = _cob.unidade_id);

  drop table if exists _mv;
  create temp table _mv on commit drop as
    select distinct on (o.loja, o.venda) o.loja unidade_id, o.venda, o.dia, o.valor_venda vv, o.garantido gar, false casado
      from multi.v_operacoes o join _cob b on b.unidade_id = o.loja
     where o.tipo = 1 and coalesce(o.valor_venda, 0) > 0 and o.venda is not null
       and o.dia >= greatest(p_ini, b.ini) and o.dia <= b.fim
       and o.dia >= (select min(d.dia) from cx.dias d where d.unidade_id = o.loja)
     order by o.loja, o.venda, o.dia;

  drop table if exists _mc;
  create temp table _mc on commit drop as
    select pg.id, pg.unidade_id, pg.dia, pg.valor, false usado, false parcela
      from cx.pagamentos pg join _cob b on b.unidade_id = pg.unidade_id
     where pg.forma = 'crediario' and pg.valor > 0 and pg.dia >= greatest(p_ini, b.ini) - v_a;

  -- passos: (quantos lançamentos, só o mesmo dia?, valor exato?)
  for ps in select * from (values (1, true, true), (2, true, true), (3, true, true), (1, false, true), (2, false, true), (3, false, true),
                                  (1, true, false), (2, true, false), (3, true, false), (1, false, false), (2, false, false)) v(k, mesmo, exato) loop
    for x in select * from _mv where not casado order by dia, vv desc, venda loop
      v_ids := cx._multi_achar(x.unidade_id, x.dia, x.vv, x.gar, ps.k,
                               case when ps.mesmo then x.dia else x.dia - v_a end, case when ps.mesmo then x.dia else x.dia + v_d end,
                               case when ps.exato then v_tv else v_dif end);
      if v_ids is not null then
        update _mc set usado = true where id = any(v_ids);
        update _mv set casado = true where unidade_id = x.unidade_id and venda = x.venda;
        insert into cx.multi_casamentos
        select x.unidade_id, x.venda, x.dia, x.vv, min(c.dia), sum(c.valor), v_ids,
               case when not ps.exato and least(abs(sum(c.valor) - x.vv), abs(sum(c.valor) - coalesce(x.gar, x.vv))) > v_tv then 'valor_diferente'
                    when min(c.dia) = x.dia then 'mesmo_dia' else 'outro_dia' end
          from _mc c where c.id = any(v_ids);
        n := n + 1;
      end if;
    end loop;
  end loop;

  -- o que sobrou no caixa como "Multicrediário": parcela recebida na loja (recebimentos do Multicrediário, ou operação tipo 3)?
  drop table if exists _rc;
  create temp table _rc on commit drop as
    select row_number() over (order by r.loja, r.dia, r.venda, r.parcela) rid, r.loja unidade_id, r.dia, r.valor, false usado
      from (select distinct loja, dia, venda, parcela, valor from multi.v_recebidas where dia >= p_ini - 30
            union   -- operações de tipo 3 do relatório de operações (pagamento de parcela de carnê antigo)
            select distinct loja, dia, venda, -3, coalesce(total, garantido, valor_venda) from multi.v_operacoes
             where tipo = 3 and dia >= p_ini - 30 and coalesce(total, garantido, valor_venda) > 0) r;
  for x in select * from _mc where not usado order by dia, id loop
    select rid into v_r from _rc where not usado and unidade_id = x.unidade_id and abs(valor - x.valor) <= v_tv
       and dia between x.dia - v_a and x.dia + v_a order by abs(dia - x.dia), rid limit 1;
    if found then
      update _rc set usado = true where rid = v_r;
      update _mc set parcela = true where id = x.id;
    end if;
  end loop;

  -- avisos
  insert into _devidos
  select case m.modo when 'outro_dia' then 'multi_outro_dia' else 'multi_valor_diferente' end, m.unidade_id || ':' || m.venda, m.unidade_id, m.venda_dia,
         jsonb_build_object('venda', m.venda, 'valor_multi', m.valor_multi, 'valor_caixa', m.valor_caixa, 'diferenca', m.valor_caixa - m.valor_multi,
                            'caixa_dia', m.caixa_dia, 'lancamentos', cardinality(m.pagamentos),
                            'dia_semana', cx._dia_semana(m.venda_dia), 'caixa_dia_semana', cx._dia_semana(m.caixa_dia))
    from cx.multi_casamentos m where m.modo <> 'mesmo_dia';

  insert into _devidos
  select 'multi_sem_caixa', v.unidade_id || ':' || v.venda, v.unidade_id, v.dia,
         jsonb_build_object('venda', v.venda, 'valor_multi', v.vv, 'dias_antes', v_a, 'dias_depois', v_d, 'dia_semana', cx._dia_semana(v.dia))
    from _mv v
   where not v.casado and v.dia + v_d < p_hoje
     and v.dia + v_d <= (select max(d.dia) from cx.dias d where d.unidade_id = v.unidade_id);

  insert into _devidos
  select 'caixa_multi_sem_venda', c.unidade_id || ':' || c.dia || ':' || c.id, c.unidade_id, c.dia,
         jsonb_build_object('valor', c.valor, 'dias_antes', v_a, 'dias_depois', v_d, 'dia_semana', cx._dia_semana(c.dia))
    from _mc c join _cob b on b.unidade_id = c.unidade_id
   where not c.usado and not c.parcela and c.dia >= greatest(p_ini, b.ini) and c.dia + v_a <= b.fim;
  return n;
end $$;

revoke all on function cx._conferir_multi(date, date) from public;
revoke all on function cx._multi_achar(text, date, numeric, numeric, int, date, date, numeric) from public;

-- liga a conferência venda a venda no recalcular do caixa (antes dos depósitos e de gravar os avisos)
do $$ declare v text;
begin
  v := pg_get_functiondef('cx.recalcular()'::regprocedure);
  if v !~ '_conferir_multi' then
    v := replace(v, $a$  -- depósitos do dinheiro conferidos no extrato
  perform cx._conferir_depositos(v_ini, d);$a$,
      $a$  -- Multicrediário × caixa, venda a venda
  perform cx._conferir_multi(v_ini, d);

  -- depósitos do dinheiro conferidos no extrato
  perform cx._conferir_depositos(v_ini, d);$a$);
    if v !~ '_conferir_multi' then raise exception 'recalcular do caixa não foi atualizado'; end if;
    execute v;
  end if;
end $$;

-- central: títulos, gravidade e textos
do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_central(text)'::regprocedure);
  if v !~ 'multi_sem_caixa' then
    v := replace(v, $a$when 'deposito_sem_caixa' then 'Depósito sem caixa' else a.tipo end,$a$,
      $a$when 'deposito_sem_caixa' then 'Depósito sem caixa'
             when 'multi_sem_caixa' then 'Venda do Multicrediário fora do caixa' when 'multi_valor_diferente' then 'Multicrediário: valor diferente no caixa'
             when 'multi_outro_dia' then 'Multicrediário lançado em outro dia' when 'caixa_multi_sem_venda' then 'Multicrediário no caixa sem venda'
             else a.tipo end,$a$);
    v := replace(v, $a$'deposito_nao_encontrado','deposito_sem_caixa') then 1 else 2 end,$a$,
      $a$'deposito_nao_encontrado','deposito_sem_caixa','multi_sem_caixa','multi_valor_diferente') then 1
                when a.tipo = 'multi_outro_dia' then 3 else 2 end,$a$);
    v := replace(v, $a$             else 'Sem fechamento de caixa registrado neste dia.' end,$a$,
      $a$             when 'multi_sem_caixa' then format('Venda %s de R$ %s aprovada no Multicrediário e não lançada no caixa (procurado de %s dias antes a %s dias depois).',
               a.detalhe->>'venda', to_char((a.detalhe->>'valor_multi')::numeric, brl), a.detalhe->>'dias_antes', a.detalhe->>'dias_depois')
             when 'multi_valor_diferente' then format('Venda %s: Multicrediário R$ %s × caixa R$ %s em %s.', a.detalhe->>'venda',
               to_char((a.detalhe->>'valor_multi')::numeric, brl), to_char((a.detalhe->>'valor_caixa')::numeric, brl), to_char((a.detalhe->>'caixa_dia')::date, 'DD/MM'))
             when 'multi_outro_dia' then format('Venda %s de R$ %s lançada no caixa em %s (%s).', a.detalhe->>'venda',
               to_char((a.detalhe->>'valor_multi')::numeric, brl), to_char((a.detalhe->>'caixa_dia')::date, 'DD/MM'), a.detalhe->>'caixa_dia_semana')
             when 'caixa_multi_sem_venda' then format('R$ %s lançado como Multicrediário no caixa e não achado como venda nem parcela no Multicrediário.',
               to_char((a.detalhe->>'valor')::numeric, brl))
             else 'Sem fechamento de caixa registrado neste dia.' end,$a$);
    if v !~ 'multi_sem_caixa' or v !~ 'Multicrediário lançado em outro dia' or v !~ 'não achado como venda nem parcela' then
      raise exception 'central não foi atualizada';
    end if;
    execute v;
  end if;
end $$;

-- relatório do dia: Multicrediário × caixa venda a venda
do $$ declare v text;
begin
  v := pg_get_functiondef('rel.gerar(date)'::regprocedure);
  if v !~ 'multi_sem_caixa' then
    v := replace(v, $a$format('Multicrediário × caixa diferente em %s dia(s): %s', count(*),
             string_agg(format('%s (%s): caixa R$ %s × Multi R$ %s', to_char(dia, 'DD/MM'), detalhe->>'dia_semana',
             replace(detalhe->>'caixa_vendas', '.', ','), replace(detalhe->>'multi_vendas', '.', ',')), '; ' order by dia)), '/caixa'
      from cx.alertas where status = 'aberto' and tipo = 'multi_divergente' group by unidade_id$a$,
      $a$format('Multicrediário × caixa (venda a venda), %s problema(s): %s', count(*),
             string_agg(format('%s (%s) R$ %s %s', to_char(dia, 'DD/MM'), detalhe->>'dia_semana',
             replace(coalesce(detalhe->>'valor_multi', detalhe->>'valor'), '.', ','),
             case tipo when 'multi_sem_caixa' then 'não lançada no caixa'
                       when 'multi_valor_diferente' then 'lançada no caixa como R$ ' || replace(detalhe->>'valor_caixa', '.', ',')
                       else 'no caixa sem venda no Multicrediário' end), '; ' order by dia)), '/caixa'
      from cx.alertas where status = 'aberto' and tipo in ('multi_sem_caixa','multi_valor_diferente','caixa_multi_sem_venda') group by unidade_id$a$);
    if v !~ 'multi_sem_caixa' then raise exception 'relatório do dia não foi atualizado'; end if;
    execute v;
  end if;
end $$;

-- regras editáveis na tela Multicrediário
create or replace function multi._ajustes() returns jsonb language sql stable set search_path = core, pg_catalog as $$
  select jsonb_build_object(
    'unidades', core.cfg('multi.unidades_adm', 'saovicente'),
    'tolerancia', coalesce(nullif(core.cfg('multi.tolerancia', ''), '')::numeric, 0.01),
    'adm_inicio', coalesce(nullif(core.cfg('multi.adm_inicio', ''), '')::date, '2026-08-25'::date),
    'caixa_dias_antes', coalesce(nullif(core.cfg('cx.multi_dias_antes', ''), '')::int, 3),
    'caixa_dias_depois', coalesce(nullif(core.cfg('cx.multi_dias_depois', ''), '')::int, 7),
    'caixa_dif_max', coalesce(nullif(core.cfg('cx.multi_dif_max', ''), '')::numeric, 100))
$$;

drop function if exists public.painel_multi_ajustes_salvar(numeric, date, text, text);
create or replace function public.painel_multi_ajustes_salvar(p_tolerancia numeric, p_adm_inicio date, p_unidades text, p_motivo text default null,
  p_caixa_dias_antes int default null, p_caixa_dias_depois int default null, p_caixa_dif_max numeric default null)
returns jsonb language plpgsql security definer set search_path = multi, core, pg_catalog as $$
declare v_eu uuid; v_antes jsonb := multi._ajustes(); v_un text;
begin
  v_eu := painel._entrar('multi_ajustes_salvar');
  perform painel._exigir(v_eu, 'administrar');
  if p_tolerancia is null or p_tolerancia < 0 or p_tolerancia > 5 then raise exception 'tolerância: de R$ 0,00 a R$ 5,00' using errcode = '22023'; end if;
  if p_adm_inicio is null or p_adm_inicio < date '2020-01-01' or p_adm_inicio > current_date then raise exception 'data de início inválida' using errcode = '22023'; end if;
  v_un := array_to_string(array(select distinct lower(btrim(e)) from unnest(string_to_array(coalesce(p_unidades, ''), ',')) e where lower(btrim(e)) ~ '^[a-z0-9_]{2,40}$'), ',');
  if v_un = '' then raise exception 'informe ao menos uma unidade do ADM (ex.: saovicente)' using errcode = '22023'; end if;
  if p_caixa_dias_antes is not null and (p_caixa_dias_antes < 0 or p_caixa_dias_antes > 15) then raise exception 'dias antes: de 0 a 15' using errcode = '22023'; end if;
  if p_caixa_dias_depois is not null and (p_caixa_dias_depois < 0 or p_caixa_dias_depois > 30) then raise exception 'dias depois: de 0 a 30' using errcode = '22023'; end if;
  if p_caixa_dif_max is not null and (p_caixa_dif_max < 0 or p_caixa_dif_max > 1000) then raise exception 'diferença: de R$ 0 a R$ 1.000' using errcode = '22023'; end if;
  insert into core.config (chave, valor) values ('multi.tolerancia', round(p_tolerancia, 2)::text), ('multi.adm_inicio', p_adm_inicio::text), ('multi.unidades_adm', v_un)
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  insert into core.config (chave, valor)
  select k, v from (values ('cx.multi_dias_antes', p_caixa_dias_antes::text), ('cx.multi_dias_depois', p_caixa_dias_depois::text),
                           ('cx.multi_dif_max', round(p_caixa_dif_max, 2)::text)) q(k, v) where v is not null
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  perform core.auditar(v_eu, null, 'multi_ajustes_alterados', 'core.config', 'multi', v_antes, multi._ajustes(), nullif(btrim(coalesce(p_motivo, '')), ''));
  perform multi.conferir();
  if to_regprocedure('cx.recalcular()') is not null then perform cx.recalcular(); end if;
  return multi._ajustes();
end $$;

do $$ begin
  revoke all on function public.painel_multi_ajustes_salvar(numeric,date,text,text,int,int,numeric) from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on function public.painel_multi_ajustes_salvar(numeric,date,text,text,int,int,numeric) from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.painel_multi_ajustes_salvar(numeric,date,text,text,int,int,numeric) to authenticated';
  end if;
end $$;

select cx.recalcular();
