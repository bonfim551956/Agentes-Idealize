-- =============================================================================
-- Idealize AI — OFX ocupa o lugar da linha lida do PDF  · Migração 20261107190000
-- Achado em 07/11: o mesmo extrato subido em PDF (lido pela IA) e depois em OFX criou 61 linhas em dobro em São Vicente
-- (15 em outubro, 46 em novembro): a chave de repetição do PDF (data|valor|descrição) é diferente da do OFX (FITID).
-- Pedido do Diego (07/11, PODE FAZER, "opção 2"): quando chega o OFX, ele ocupa o lugar da linha do PDF.
--  • fin._ofx_substitui(conta): para cada linha do OFX com "gêmea" lida de PDF/foto (mesma conta, dia, valor e sentido),
--    a gêmea sai do extrato; o que estava ligado a ela (conciliação, pendência) passa para a linha do OFX. A gêmea é
--    guardada em fin.movimentos_substituidos (dá para consultar e voltar).
--  • fin.importar_extrato: roda a troca ao importar OFX; e ao importar PDF/foto, não cria linha que o OFX já trouxe.
-- =============================================================================
create table if not exists fin.movimentos_substituidos (
  id             uuid primary key,
  conta_id       text not null,
  data           date not null,
  sentido        text not null,
  valor          numeric(14,2) not null,
  descricao      text,
  documento_banco text,
  saldo_apos     numeric(14,2),
  chave_dedup    text,
  importacao_id  uuid,
  status         text,
  criado_em      timestamptz,
  substituido_por uuid not null,
  substituido_em timestamptz not null default now()
);
create index if not exists fin_mov_subst_conta on fin.movimentos_substituidos (conta_id, data);
alter table fin.movimentos_substituidos enable row level security; alter table fin.movimentos_substituidos force row level security;
do $$ begin
  revoke all on fin.movimentos_substituidos from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on fin.movimentos_substituidos from anon, authenticated'; end if;
end $$;

-- movimento do banco continua sem poder ser apagado; a única exceção é a troca PDF → OFX, e só depois de a linha ser
-- guardada em fin.movimentos_substituidos
create or replace function fin._proteger_movimento() returns trigger
language plpgsql set search_path = fin, pg_catalog as $$
begin
  if tg_op = 'DELETE' then
    if coalesce(current_setting('fin.substituicao_ofx', true), '') = 'on'
       and exists (select 1 from fin.movimentos_substituidos s where s.id = old.id) then
      return old;
    end if;
    raise exception 'movimentos bancários não são apagados' using errcode = '42501';
  end if;
  if (new.valor, new.sentido, new.data, new.descricao, new.conta_id, coalesce(new.documento_banco,''))
     is distinct from (old.valor, old.sentido, old.data, old.descricao, old.conta_id, coalesce(old.documento_banco,'')) then
    raise exception 'dados do extrato são imutáveis' using errcode = '42501';
  end if;
  return new;
end $$;

create or replace function fin._ofx_substitui(p_conta text) returns int
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare r record; n int := 0;
begin
  for r in
    with o as (select m.id, m.data, m.valor, m.sentido,
                      row_number() over (partition by m.data, m.valor, m.sentido order by m.criado_em, m.id) k
                 from fin.movimentos m join fin.importacoes i on i.id = m.importacao_id
                where m.conta_id = p_conta and i.formato = 'ofx'),
         p as (select m.id, m.data, m.valor, m.sentido,
                      row_number() over (partition by m.data, m.valor, m.sentido order by m.criado_em, m.id) k
                 from fin.movimentos m join fin.importacoes i on i.id = m.importacao_id
                where m.conta_id = p_conta and i.formato = 'ia')
    select o.id ofx_id, p.id pdf_id from o join p on p.data = o.data and p.valor = o.valor and p.sentido = o.sentido and p.k = o.k
  loop
    update fin.conciliacoes set movimento_id = r.ofx_id where movimento_id = r.pdf_id;
    update fin.pendencias set movimento_id = r.ofx_id where movimento_id = r.pdf_id;
    update fin.movimentos o set status = p.status
      from fin.movimentos p where o.id = r.ofx_id and p.id = r.pdf_id and p.status <> 'pendente' and o.status = 'pendente';
    insert into fin.movimentos_substituidos (id, conta_id, data, sentido, valor, descricao, documento_banco, saldo_apos, chave_dedup,
                                            importacao_id, status, criado_em, substituido_por)
    select id, conta_id, data, sentido, valor, descricao, documento_banco, saldo_apos, chave_dedup, importacao_id, status, criado_em, r.ofx_id
      from fin.movimentos where id = r.pdf_id
    on conflict (id) do nothing;
    perform set_config('fin.substituicao_ofx', 'on', true);
    delete from fin.movimentos where id = r.pdf_id;
    perform set_config('fin.substituicao_ofx', '', true);
    n := n + 1;
  end loop;
  return n;
end $$;

do $$ declare v text;
begin
  v := pg_get_functiondef('fin.importar_extrato(text,text,text,jsonb,text,numeric,numeric)'::regprocedure);
  if v !~ '_ofx_substitui' then
    -- PDF/foto: não cria a linha que um OFX já trouxe (mesmo dia, valor e sentido)
    v := replace(v, $a$    insert into fin.movimentos (conta_id, data, sentido, valor, descricao, documento_banco, saldo_apos, chave_dedup, importacao_id)$a$,
      $a$    if p_formato <> 'ofx' and (select count(*) from fin.movimentos m join fin.importacoes i on i.id = m.importacao_id
          where m.conta_id = p_conta and i.formato = 'ofx' and m.data = (l->>'data')::date and m.valor = abs(v_val)
            and m.sentido = case when v_val > 0 then 'credito' else 'debito' end) >= v_ord then
      v_dup := v_dup + 1; continue;
    end if;
    insert into fin.movimentos (conta_id, data, sentido, valor, descricao, documento_banco, saldo_apos, chave_dedup, importacao_id)$a$);
    -- OFX: ocupa o lugar das linhas lidas de PDF/foto
    v := replace(v, $a$  update fin.importacoes set novas = v_novas, duplicadas = v_dup where id = v_imp;$a$,
      $a$  if p_formato = 'ofx' then v_subst := fin._ofx_substitui(p_conta); v_novas := v_novas - v_subst; v_dup := v_dup + v_subst; end if;
  update fin.importacoes set novas = v_novas, duplicadas = v_dup where id = v_imp;$a$);
    v := replace(v, 'v_ini date; v_fim date; v_conta record;', 'v_ini date; v_fim date; v_conta record; v_subst int := 0;');
    v := replace(v, $a$return jsonb_build_object('importacao', v_imp, 'novas', v_novas, 'duplicadas', v_dup, 'ja_importado', false);$a$,
      $a$return jsonb_build_object('importacao', v_imp, 'novas', v_novas, 'duplicadas', v_dup, 'substituidas_do_pdf', v_subst, 'ja_importado', false);$a$);
    if v !~ '_ofx_substitui' or v !~ 'v_subst int' or v !~ 'substituidas_do_pdf' or v !~ 'p_formato <> ''ofx''' then
      raise exception 'importação do extrato não foi atualizada';
    end if;
    execute v;
  end if;
end $$;

revoke all on function fin._ofx_substitui(text) from public;

-- corrige as linhas em dobro que já existem (todas as contas que receberam OFX)
do $$ declare c record; n int; begin
  for c in select distinct m.conta_id from fin.movimentos m join fin.importacoes i on i.id = m.importacao_id where i.formato = 'ofx' loop
    n := fin._ofx_substitui(c.conta_id);
    if n > 0 then
      perform core.auditar(null, 'migração', 'extrato_pdf_substituido_por_ofx', 'fin.conta', c.conta_id, null, jsonb_build_object('linhas', n));
    end if;
  end loop;
end $$;

do $$ begin if to_regprocedure('cx.recalcular()') is not null then perform cx.recalcular(); end if; end $$;
