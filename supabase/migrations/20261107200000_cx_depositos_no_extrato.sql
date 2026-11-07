-- =============================================================================
-- Idealize AI — Caixa: o dinheiro do caixa é conferido no extrato (depósito)  · Migração 20261107200000
-- Pedido do Diego (07/11, PODE FAZER): "o agente não confere os depósitos que são feitos? deveria conferir".
-- Antes o agente só olhava se o ADM tinha o depósito anotado (aviso "dinheiro sem depósito"). Agora:
--  • O dinheiro de cada dia do caixa é procurado no extrato do banco como depósito (descrição "DEP DINHEIRO ..."):
--    mesmo valor, depositado no mesmo dia ou até N dias depois (cx.deposito_janela_dias, 45). Depósito de dois dias
--    juntos também casa.
--  • "Dinheiro não depositado": dia com dinheiro que não aparece depositado depois do prazo (cx.deposito_prazo_dias),
--    com o extrato já cobrindo o período.
--  • "Depósito sem caixa": depósito em dinheiro no banco que não corresponde a nenhum dia do caixa.
--  • O aviso antigo (depósito não anotado no ADM) sai: o que vale é o dinheiro estar no banco.
-- =============================================================================
alter table cx.alertas drop constraint if exists alertas_tipo_check;
alter table cx.alertas add constraint alertas_tipo_check check (tipo in ('nao_encontrado','sem_registro_no_caixa','caixa_nao_fechado',
  'caixa_inconsistente','dinheiro_sem_deposito','extrato_atrasado','multi_divergente','deposito_nao_encontrado','deposito_sem_caixa'));

insert into core.config (chave, valor) values
  ('cx.deposito_janela_dias', '45'),
  ('cx.deposito_regex', 'dep(osito)?[^a-z]*(em )?(dinheiro|especie)')
on conflict (chave) do nothing;

create table if not exists cx.depositos_casados (     -- resultado da conferência dos depósitos (recalculado)
  unidade_id   text not null,
  dia          date not null,                        -- dia do caixa
  movimento_id uuid not null,                        -- depósito no extrato
  primary key (unidade_id, dia, movimento_id)
);
alter table cx.depositos_casados enable row level security; alter table cx.depositos_casados force row level security;
do $$ begin
  revoke all on cx.depositos_casados from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on cx.depositos_casados from anon, authenticated'; end if;
end $$;

-- chamada de dentro de cx.recalcular(): usa a tabela temporária _devidos
create or replace function cx._conferir_depositos(p_ini date, p_hoje date) returns int
language plpgsql security definer set search_path = cx, core, pg_catalog as $$
declare v_jan int := cx._cfg_num('cx.deposito_janela_dias', 45)::int; v_prazo int := cx._cfg_num('cx.deposito_prazo_dias', 3)::int;
  v_tv numeric := cx._cfg_num('cx.tolerancia_valor', 0.10); v_re text := coalesce(nullif(core.cfg('cx.deposito_regex', ''), ''), 'dep.*dinheiro');
  x record; v_m uuid; v_par record; n int := 0;
begin
  delete from cx.depositos_casados where true;
  drop table if exists _dep;
  create temp table _dep on commit drop as
    select m.id, c.unidade_id, m.data, m.valor, false usado
      from fin.movimentos m join fin.contas c on c.id = m.conta_id
     where c.tipo = 'corrente' and m.sentido = 'credito' and m.data >= p_ini and cx._simples(m.descricao) ~ v_re;
  drop table if exists _din;
  create temp table _din on commit drop as
    select d.unidade_id, d.dia, s.valor, false casado
      from cx.dias d join lateral (select sum(pg.valor) valor from cx.pagamentos pg
                                    where pg.unidade_id = d.unidade_id and pg.dia = d.dia and pg.forma = 'dinheiro') s on true
     where d.dia >= p_ini and coalesce(s.valor, 0) > 0;

  -- um dia = um depósito (mesmo valor, no dia ou depois, o mais próximo)
  for x in select * from _din order by dia, valor desc loop
    select dp.id into v_m from _dep dp
     where not dp.usado and dp.unidade_id = x.unidade_id and abs(dp.valor - x.valor) <= v_tv and dp.data between x.dia and x.dia + v_jan
     order by dp.data, dp.id limit 1;
    if found then
      update _dep set usado = true where id = v_m;
      update _din set casado = true where unidade_id = x.unidade_id and dia = x.dia;
      insert into cx.depositos_casados values (x.unidade_id, x.dia, v_m);
      n := n + 1;
    end if;
  end loop;
  -- dois dias depositados juntos
  for x in select * from _dep where not usado order by data, id loop
    select a.dia d1, b.dia d2 into v_par from _din a join _din b on b.unidade_id = a.unidade_id and b.dia > a.dia and not b.casado
     where not a.casado and a.unidade_id = x.unidade_id and abs(a.valor + b.valor - x.valor) <= v_tv
       and x.data between b.dia and a.dia + v_jan
     order by b.dia desc, a.dia desc limit 1;
    if found then
      update _dep set usado = true where id = x.id;
      update _din set casado = true where unidade_id = x.unidade_id and dia in (v_par.d1, v_par.d2);
      insert into cx.depositos_casados values (x.unidade_id, v_par.d1, x.id), (x.unidade_id, v_par.d2, x.id);
      n := n + 2;
    end if;
  end loop;

  -- o aviso antigo (depósito não anotado no ADM) sai: o que vale é o dinheiro estar no banco
  delete from _devidos where tipo = 'dinheiro_sem_deposito';

  insert into _devidos
  select 'deposito_nao_encontrado', z.unidade_id || ':' || z.dia, z.unidade_id, z.dia,
         jsonb_build_object('dinheiro', z.valor, 'prazo_dias', v_prazo, 'dia_semana', cx._dia_semana(z.dia))
    from _din z
   where not z.casado and z.dia <= p_hoje - v_prazo
     and z.dia + v_prazo <= coalesce((select max(m.data) from fin.movimentos m join fin.contas c on c.id = m.conta_id
                                      where c.unidade_id = z.unidade_id and c.tipo = 'corrente'), '1900-01-01')
     and z.dia >= coalesce((select min(m.data) from fin.movimentos m join fin.contas c on c.id = m.conta_id
                            where c.unidade_id = z.unidade_id and c.tipo = 'corrente'), '9999-12-31');

  insert into _devidos
  select 'deposito_sem_caixa', dp.unidade_id || ':' || dp.data || ':deposito', dp.unidade_id, dp.data,
         jsonb_build_object('quantidade', count(*), 'valor', sum(dp.valor), 'valores', jsonb_agg(dp.valor order by dp.valor desc),
                            'dia_semana', cx._dia_semana(dp.data))
    from _dep dp
   where not dp.usado and exists (select 1 from cx.dias d where d.unidade_id = dp.unidade_id)
     and dp.data >= (select min(d.dia) from cx.dias d where d.unidade_id = dp.unidade_id)
   group by dp.unidade_id, dp.data;
  return n;
end $$;

-- liga a conferência dos depósitos no recalcular do caixa (antes de gravar os avisos)
do $$ declare v text;
begin
  v := pg_get_functiondef('cx.recalcular()'::regprocedure);
  if v !~ '_conferir_depositos' then
    v := replace(v, $a$  insert into cx.alertas (tipo, referencia, unidade_id, dia, detalhe)
  select tipo, referencia, unidade_id, dia, detalhe from _devidos$a$,
      $a$  -- depósitos do dinheiro conferidos no extrato
  perform cx._conferir_depositos(v_ini, d);

  insert into cx.alertas (tipo, referencia, unidade_id, dia, detalhe)
  select tipo, referencia, unidade_id, dia, detalhe from _devidos$a$);
    if v !~ '_conferir_depositos' then raise exception 'recalcular do caixa não foi atualizado'; end if;
    execute v;
  end if;
end $$;

revoke all on function cx._conferir_depositos(date, date) from public;

-- central: textos dos dois avisos novos
do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_central(text)'::regprocedure);
  if v !~ 'deposito_nao_encontrado' then
    v := replace(v, $a$when 'extrato_atrasado' then 'Extrato atrasado' else a.tipo end,$a$,
      $a$when 'extrato_atrasado' then 'Extrato atrasado' when 'deposito_nao_encontrado' then 'Dinheiro não depositado'
             when 'deposito_sem_caixa' then 'Depósito sem caixa' else a.tipo end,$a$);
    v := replace(v, $a$case when a.tipo in ('nao_encontrado','sem_registro_no_caixa','multi_divergente','caixa_nao_fechado') then 1 else 2 end,$a$,
      $a$case when a.tipo in ('nao_encontrado','sem_registro_no_caixa','multi_divergente','caixa_nao_fechado','deposito_nao_encontrado','deposito_sem_caixa') then 1 else 2 end,$a$);
    v := replace(v, $a$             else 'Sem fechamento de caixa registrado neste dia.' end,$a$,
      $a$             when 'deposito_nao_encontrado' then format('R$ %s em dinheiro do caixa sem depósito no extrato depois de %s dias.', to_char((a.detalhe->>'dinheiro')::numeric, brl), a.detalhe->>'prazo_dias')
             when 'deposito_sem_caixa' then format('Depósito em dinheiro de R$ %s no banco que não corresponde a nenhum dia do caixa.', to_char((a.detalhe->>'valor')::numeric, brl))
             else 'Sem fechamento de caixa registrado neste dia.' end,$a$);
    if v !~ 'Dinheiro não depositado' or v !~ 'Depósito sem caixa' then raise exception 'central não foi atualizada'; end if;
    execute v;
  end if;
end $$;

select cx.recalcular();
