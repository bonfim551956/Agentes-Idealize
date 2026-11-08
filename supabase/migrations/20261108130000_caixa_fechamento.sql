-- =============================================================================
-- Idealize AI — Fechamento do caixa pelo agente · Migração 20261108130000
-- Pedido do Diego (08/11): "a função do agente é conferir o caixa e FECHAR quando tudo bater, ou mostrar as
-- divergências daquele caixa". Agora o agente grava, para cada loja e dia, o resultado da conferência:
--   conferido  → tudo o que dá para conferir foi achado (Pix e depósito no extrato, cartão na Stone, Asaas,
--                Multicrediário venda a venda) e não há aviso aberto: caixa fechado pelo agente.
--   divergente → há aviso aberto do dia ou o total não fecha com as formas; as divergências vão junto.
--   conferindo → ainda falta achar algo, mas está dentro do prazo do agente (sem aviso ainda).
--   aguardando → falta o arquivo (extrato, Stone, Asaas) que cobre aquele dia.
-- O agente não fecha nada no ADM (só leitura): o "fechado" vale no Idealize AI.
-- Roda ao fim de cada conferência do caixa e logo depois que um extrato vira lançamento (que também dispara a
-- conferência do caixa na hora, sem esperar a próxima hora cheia).
-- =============================================================================

create table if not exists cx.fechamentos (
  unidade_id   text not null references core.unidades(id),
  dia          date not null,
  status       text not null check (status in ('conferido', 'divergente', 'conferindo', 'aguardando')),
  divergencias jsonb not null default '[]'::jsonb,
  faltas       jsonb not null default '[]'::jsonb,
  conferido_em timestamptz,
  atualizado_em timestamptz not null default now(),
  primary key (unidade_id, dia)
);
alter table cx.fechamentos enable row level security;
alter table cx.fechamentos force row level security;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'wa_leitura') then execute 'grant select on cx.fechamentos to wa_leitura'; end if;
end $$;

-- fonte que confere cada forma e até/desde quando ela cobre a loja
create or replace function cx._coberto(p_unidade text, p_forma text, p_dia date) returns boolean
language sql stable security definer set search_path = cx, pg_catalog as $$
  select case
    when p_forma in ('pix', 'dinheiro') then exists (
      select 1 from (select min(m.data) de, max(m.data) ate from fin.movimentos m join fin.contas c on c.id = m.conta_id
                      where c.unidade_id = p_unidade and c.tipo = 'corrente') x where p_dia between x.de and x.ate)
    when p_forma in ('credito', 'debito', 'asaas') then exists (
      select 1 from (select min(r.dia) de, max(r.dia) ate from cx.recebimentos r
                      where r.unidade_id = p_unidade and r.fonte = case when p_forma = 'asaas' then 'asaas' else 'stone' end) x
       where p_dia between x.de and x.ate)
    when p_forma = 'crediario' then exists (select 1 from multi.capturas c where (c.capturado_em at time zone 'America/Sao_Paulo')::date > p_dia)
    else true end
$$;

create or replace function cx.fechar_dias(p_dias int default 60) returns jsonb
language plpgsql security definer set search_path = cx, core, pg_catalog as $$
declare d record; v_faltas jsonb; v_div jsonb; v_status text; n jsonb := '{}'::jsonb;
  v_ini date := (now() at time zone 'America/Sao_Paulo')::date - greatest(coalesce(p_dias, 60), 1);
begin
  for d in select * from cx.dias x where x.dia >= v_ini loop
    -- o que ficou sem achar, por forma conferível
    select coalesce(jsonb_agg(jsonb_build_object('forma', f.forma, 'valor', f.falta, 'coberto', cx._coberto(d.unidade_id, f.forma, d.dia)) order by f.forma), '[]'::jsonb)
      into v_faltas
      from (select p.forma, sum(p.valor) falta from cx.pagamentos p
             where p.unidade_id = d.unidade_id and p.dia = d.dia and p.forma in ('pix', 'dinheiro', 'credito', 'debito', 'asaas', 'crediario')
               and not cx.pagamento_achado(p.id, p.forma, p.unidade_id, p.dia)
             group by p.forma) f;
    select coalesce(jsonb_agg(jsonb_build_object('tipo', a.tipo, 'referencia', a.referencia, 'detalhe', a.detalhe) order by a.aberto_em), '[]'::jsonb)
      into v_div from cx.alertas a where a.unidade_id = d.unidade_id and a.dia = d.dia and a.status = 'aberto';
    if d.caixa is not null and abs(d.caixa - d.soma_formas) > 1 then
      v_div := v_div || jsonb_build_array(jsonb_build_object('tipo', 'total_nao_fecha', 'detalhe', jsonb_build_object('caixa', d.caixa, 'soma_formas', d.soma_formas)));
    end if;
    v_status := case
      when jsonb_array_length(v_div) > 0 then 'divergente'
      when exists (select 1 from jsonb_array_elements(v_faltas) x where not (x->>'coberto')::boolean) then 'aguardando'
      when jsonb_array_length(v_faltas) > 0 then 'conferindo'
      else 'conferido' end;
    insert into cx.fechamentos as f (unidade_id, dia, status, divergencias, faltas, conferido_em, atualizado_em)
    values (d.unidade_id, d.dia, v_status, v_div, v_faltas, case when v_status = 'conferido' then now() end, now())
    on conflict (unidade_id, dia) do update set status = excluded.status, divergencias = excluded.divergencias, faltas = excluded.faltas,
      conferido_em = case when excluded.status = 'conferido' then coalesce(f.conferido_em, now()) end, atualizado_em = now();
    n := jsonb_set(n, array[v_status], to_jsonb(coalesce((n->>v_status)::int, 0) + 1));
  end loop;
  return n;
end $$;
revoke all on function cx.fechar_dias(int) from public;
revoke all on function cx._coberto(text, text, date) from public;

-- 1. ao fim de cada conferência do caixa, o agente fecha (ou aponta) cada dia
do $$ declare v text;
begin
  v := pg_get_functiondef('cx.concluir_sincronizacao(uuid,text,jsonb)'::regprocedure);
  if v !~ 'fechar_dias' then
    v := replace(v, 'v := cx.aplicar_lote(p_tarefa, p_lote);', $a$v := cx.aplicar_lote(p_tarefa, p_lote);
  v := v || jsonb_build_object('fechamento', cx.fechar_dias());$a$);
    if v !~ 'fechar_dias' then raise exception 'conferência do caixa não foi atualizada'; end if;
    execute v;
  end if;
end $$;

-- 2. extrato que vira lançamento já dispara a conferência do caixa na hora
create or replace function fin.processar_extratos(p_ator text default 'agente_financeiro') returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare c record; r jsonb := '[]'::jsonb; a jsonb; b jsonb;
begin
  if not pg_try_advisory_xact_lock(hashtext('fin.processar_extratos')) then return jsonb_build_object('status', 'ocupado'); end if;
  for c in select distinct m.conta_id from fin.movimentos m where m.status = 'pendente'
      and not exists (select 1 from fin.pendencias p where p.movimento_id = m.id and p.status = 'aberta') loop
    a := fin.conciliar(c.conta_id, p_ator);
    b := fin.lancar_do_extrato(c.conta_id, p_ator);
    r := r || jsonb_build_array(jsonb_build_object('conta', c.conta_id, 'conciliados', a, 'lancados', b));
  end loop;
  if jsonb_array_length(r) > 0 then
    perform core.auditar(null, 'agente_financeiro', 'extratos_processados', 'fin.movimentos', null, null, r, 'extrato vira lançamento');
    begin
      perform core.chamar_agente('caixa-sync', 'cx_worker_secret', 300000);   -- confere o caixa agora
    exception when others then null;   -- sem Vault/pg_net (teste local): a conferência de hora em hora pega
    end;
  end if;
  return jsonb_build_object('status', 'ok', 'contas', r);
end $$;
revoke all on function fin.processar_extratos(text) from public;

-- 3. a tela do caixa recebe o fechamento de cada dia
do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_caixa(text,integer,date,date)'::regprocedure);
  if v !~ '''fechamentos''' then
    v := replace(v, $a$'dias', (select coalesce(jsonb_agg(jsonb_build_object('unidade_id', x.unidade_id, 'dia', x.dia, 'status_adm', x.status_adm,$a$,
      $a$'fechamentos', (select coalesce(jsonb_agg(jsonb_build_object('unidade_id', f.unidade_id, 'dia', f.dia, 'status', f.status,
        'divergencias', f.divergencias, 'faltas', f.faltas, 'conferido_em', f.conferido_em, 'atualizado_em', f.atualizado_em)), '[]'::jsonb)
      from cx.fechamentos f where f.dia between v_ini and v_fim and f.unidade_id = any(un)),
    'dias', (select coalesce(jsonb_agg(jsonb_build_object('unidade_id', x.unidade_id, 'dia', x.dia, 'status_adm', x.status_adm,$a$);
    if v !~ '''fechamentos''' then raise exception 'tela do caixa não foi atualizada'; end if;
    execute v;
  end if;
end $$;

select cx.fechar_dias(90);
