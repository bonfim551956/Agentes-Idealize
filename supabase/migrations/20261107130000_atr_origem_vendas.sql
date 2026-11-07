-- =============================================================================
-- Idealize AI — Origem das vendas (Loja × Visão Ideal, por loja)  · Migração 20261107130000
-- Pedido do Diego (07/11, PODE FAZER): "quero entender se é LOJA ou VISÃO IDEAL e qual loja".
-- O ADM não guarda a origem da venda. Cada venda do ADM é ligada, pelo telefone (só em código), ao lead mais recente
-- da Kommo antes dela (até N dias). O funil do lead diz o tipo e a loja de onde o cliente veio:
--   funil "LOJA <loja>" = campanha da loja (conta CA Idealize) · "CAMPANHA <loja>" = Visão Ideal (conta CA Visão Ideal)
--   "PÓS-VENDA ..." = pós-venda. Sem lead: "sem origem" (cliente que já comprou antes = recorrente; senão balcão/outros).
-- A tabela funil → tipo/loja nasce preenchida pelos nomes e é editável na tela (funil novo aparece "sem classificação").
-- Só leitura de dados que já estão aqui (atr.vendas, atr.leads, com.funis). Nenhum telefone aberto.
-- =============================================================================
create table if not exists atr.funis_tipo (
  funil_id      bigint primary key,
  tipo          text not null check (tipo in ('loja', 'visao_ideal', 'pos_venda', 'ignorar')),
  unidade_id    text references core.unidades(id),
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
create index if not exists atr_funis_tipo_unidade on atr.funis_tipo (unidade_id);
alter table atr.funis_tipo enable row level security; alter table atr.funis_tipo force row level security;
do $$ begin
  revoke all on atr.funis_tipo from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on atr.funis_tipo from anon, authenticated'; end if;
end $$;

insert into core.config (chave, valor) values ('atr.origem_janela_dias', '90') on conflict (chave) do nothing;

-- preenche pelos nomes dos funis da Kommo (só os que ainda não foram classificados)
insert into atr.funis_tipo (funil_id, tipo, unidade_id, atualizado_por)
select f.id,
       case when f.nome ilike 'CAMPANHA%' then 'visao_ideal' when f.nome ilike 'LOJA%' then 'loja'
            when f.nome ilike 'P_S-VENDA%' or f.nome ilike 'POS-VENDA%' then 'pos_venda' end,
       case when f.nome ~* '\m(SV|S[ÃA]O VICENTE)\M' then 'sao_vicente' when f.nome ~* 'CAMPINAS' then 'campinas'
            when f.nome ~* 'SOROCABA' then 'sorocaba' when f.nome ~* 'PIRACICABA' then 'piracicaba' end,
       'migração (pelo nome do funil)'
  from com.funis f
 where (f.nome ilike 'CAMPANHA%' or f.nome ilike 'LOJA%' or f.nome ilike 'P_S-VENDA%' or f.nome ilike 'POS-VENDA%')
on conflict (funil_id) do nothing;

-- cada venda do ADM com a origem: lead mais recente do mesmo telefone até N dias antes (inclusive o dia da venda)
create or replace view atr.v_origem_vendas as
select v.id os, v.unidade_id, v.dia, v.tipo tipo_os, v.valor,
       case when l.id is null then case when ant.existe then 'recorrente' else 'sem_origem' end
            else coalesce(ft.tipo, 'sem_classificacao') end origem,
       coalesce(ft.unidade_id, l.unidade_id) unidade_lead, f.nome funil, l.id lead_id,
       (l.criado_em at time zone 'America/Sao_Paulo')::date dia_lead,
       v.dia - (l.criado_em at time zone 'America/Sao_Paulo')::date dias_ate_venda
  from atr.vendas v
  left join lateral (
    select l.* from atr.leads l
     where v.tel_hash is not null and l.tel_hash = v.tel_hash
       and (l.criado_em at time zone 'America/Sao_Paulo')::date between v.dia - atr._cfg_int('atr.origem_janela_dias', 90) and v.dia
       and not exists (select 1 from atr.funis_tipo x where x.funil_id = l.funil_id and x.tipo = 'ignorar')
     order by l.criado_em desc limit 1) l on true
  left join atr.funis_tipo ft on ft.funil_id = l.funil_id
  left join com.funis f on f.id = l.funil_id
  left join lateral (select exists (select 1 from atr.vendas a where v.tel_hash is not null and a.tel_hash = v.tel_hash and a.dia < v.dia - 30) existe) ant on true
 where v.valor > 0;

-- tela: resumo por loja × origem, lista venda por venda e a classificação dos funis
create or replace function public.painel_origem_vendas(p_unidade text default null, p_dias int default 30, p_origem text default null)
returns jsonb language plpgsql security definer set search_path = atr, core, pg_catalog as $$
declare v_eu uuid; un text[]; n int := least(greatest(coalesce(p_dias, 30), 1), 120); v_ini date := atr._hoje() - (least(greatest(coalesce(p_dias, 30), 1), 120) - 1);
begin
  v_eu := painel._entrar('origem_vendas', p_unidade);
  if not painel._pode_algum(v_eu, 'consultar') then raise exception 'sem permissão para consultar' using errcode = '42501'; end if;
  un := painel._unidades(v_eu);
  if p_unidade is not null then perform painel._exigir(v_eu, 'consultar', p_unidade); un := array[p_unidade]; end if;
  drop table if exists _ov;
  create temp table _ov on commit drop as select * from atr.v_origem_vendas where unidade_id = any(un) and dia >= v_ini;
  return jsonb_build_object(
    'desde', v_ini, 'ate', atr._hoje(), 'dias', n, 'pode_editar', painel._pode(v_eu, 'administrar'),
    'janela_dias', atr._cfg_int('atr.origem_janela_dias', 90),
    'ultima_leitura', (select max(em) from atr.sincronizacoes),
    'resumo', (select coalesce(jsonb_agg(jsonb_build_object('unidade_id', unidade_id, 'origem', origem, 'vendas', q, 'valor', s) order by unidade_id, origem), '[]'::jsonb)
                 from (select unidade_id, origem, count(*) q, sum(valor) s from _ov group by 1, 2) r),
    'cruzadas', (select coalesce(jsonb_agg(jsonb_build_object('unidade_lead', unidade_lead, 'unidade_venda', unidade_id, 'origem', origem, 'vendas', q, 'valor', s)), '[]'::jsonb)
                 from (select unidade_lead, unidade_id, origem, count(*) q, sum(valor) s from _ov
                        where unidade_lead is not null and unidade_lead <> unidade_id group by 1, 2, 3) r),
    'vendas', (select coalesce(jsonb_agg(jsonb_build_object('os', os, 'unidade_id', unidade_id, 'dia', dia, 'valor', valor, 'origem', origem,
                   'unidade_lead', unidade_lead, 'funil', funil, 'dia_lead', dia_lead, 'dias_ate_venda', dias_ate_venda) order by dia desc, os), '[]'::jsonb)
                 from (select * from _ov where p_origem is null or origem = p_origem order by dia desc, os limit 500) x),
    'funis', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'nome', f.nome, 'tipo', ft.tipo, 'unidade_id', ft.unidade_id) order by f.nome), '[]'::jsonb)
                from com.funis f left join atr.funis_tipo ft on ft.funil_id = f.id));
end $$;

-- diretoria classifica um funil (tipo e loja) pela tela
create or replace function public.painel_origem_funil_salvar(p_funil bigint, p_tipo text, p_unidade text default null) returns void
language plpgsql security definer set search_path = atr, core, pg_catalog as $$
declare v_eu uuid; v_antes jsonb;
begin
  v_eu := painel._entrar('origem_funil_salvar', p_funil::text);
  perform painel._exigir(v_eu, 'administrar');
  if not exists (select 1 from com.funis where id = p_funil) then raise exception 'funil inexistente' using errcode = '22023'; end if;
  if p_tipo not in ('loja', 'visao_ideal', 'pos_venda', 'ignorar') then raise exception 'tipo inválido' using errcode = '22023'; end if;
  if p_tipo in ('loja', 'visao_ideal') and p_unidade is null then raise exception 'informe a loja do funil' using errcode = '22023'; end if;
  if p_unidade is not null and not exists (select 1 from core.unidades where id = p_unidade) then raise exception 'loja inexistente' using errcode = '22023'; end if;
  select to_jsonb(t) into v_antes from atr.funis_tipo t where funil_id = p_funil;
  insert into atr.funis_tipo (funil_id, tipo, unidade_id, atualizado_em, atualizado_por) values (p_funil, p_tipo, p_unidade, now(), 'painel')
  on conflict (funil_id) do update set tipo = excluded.tipo, unidade_id = excluded.unidade_id, atualizado_em = now(), atualizado_por = 'painel';
  perform core.auditar(v_eu, null, 'origem_funil_classificado', 'atr.funis_tipo', p_funil::text, v_antes,
    jsonb_build_object('tipo', p_tipo, 'unidade_id', p_unidade), null);
end $$;

do $$ declare f text; begin
  revoke all on atr.v_origem_vendas from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on atr.v_origem_vendas from anon, authenticated'; end if;
  foreach f in array array['public.painel_origem_vendas(text,int,text)', 'public.painel_origem_funil_salvar(bigint,text,text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('grant execute on function %s to authenticated', f); end if;
  end loop;
end $$;
