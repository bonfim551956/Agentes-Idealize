-- =============================================================================
-- Idealize AI — painel fica aberto por mais tempo  · Migração 20261107020000
-- Pedido do Diego (07/11): o painel pedia login de novo com frequência (30 min sem uso, e a sessão sumia ao fechar
-- o navegador). Agora:
--   • painel.sessao_inatividade_horas (12): sem uso por esse tempo, o painel sai sozinho;
--   • painel.sessao_dias (7): de quanto em quanto tempo pede senha + código do autenticador de novo no mesmo aparelho.
-- O 2FA continua obrigatório. O limite de dias também é conferido aqui no banco, pelo horário em que o código do
-- autenticador foi confirmado (claim "amr" do token), e não só na tela. Os dois valores são alterados pelo próprio
-- Diego na tela Operação e integrações (painel_sessao_definir, só quem administra, com motivo e auditoria).
-- =============================================================================

insert into core.config (chave, valor) values ('painel.sessao_inatividade_horas', '12'), ('painel.sessao_dias', '7')
on conflict (chave) do nothing;

-- quando o código do autenticador foi confirmado nesta sessão (null se o token não traz a informação)
create or replace function painel._totp_em() returns timestamptz
language sql stable set search_path = pg_catalog as $$
  select to_timestamp(max((m->>'timestamp')::bigint))
    from jsonb_array_elements(case when jsonb_typeof(auth.jwt()->'amr') = 'array' then auth.jwt()->'amr' else '[]'::jsonb end) m
   where m->>'method' = 'totp' and (m->>'timestamp') ~ '^\d+$'
$$;

create or replace function painel._entrar(p_funcao text, p_alvo text default null, p_exigir_2fa boolean default true)
returns uuid
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_uid uuid := auth.uid(); v_eu uuid; v_n int; v_lim int; v_totp timestamptz; v_dias int;
begin
  if v_uid is null then raise exception 'não autenticado' using errcode = '42501'; end if;
  select id into v_eu from core.principais where auth_uid = v_uid and tipo = 'usuario' and ativo;
  if v_eu is null then raise exception 'usuário sem acesso ao painel' using errcode = '42501'; end if;
  if p_exigir_2fa and coalesce(auth.jwt()->>'aal', '') <> 'aal2' then
    raise exception 'confirme o segundo fator (2FA) para continuar' using errcode = '42501';
  end if;
  -- a cada N dias o painel pede senha + código de novo (pedido 07/11)
  v_totp := painel._totp_em();
  v_dias := greatest(coalesce(nullif(core.cfg('painel.sessao_dias', '7'), '')::int, 7), 1);
  if p_exigir_2fa and v_totp is not null and v_totp < now() - make_interval(days => v_dias) then
    raise exception 'sessão expirada: entre de novo com a senha e o código' using errcode = '28000';
  end if;
  v_lim := coalesce(nullif(core.cfg('painel.limite_por_minuto', '240'), '')::int, 240);
  perform pg_advisory_xact_lock(hashtext('painel:' || v_eu::text));
  select count(*) into v_n from core.painel_acessos where principal_id = v_eu and em > now() - interval '1 minute';
  if v_n >= v_lim then raise exception 'muitas requisições; aguarde um minuto' using errcode = '54000'; end if;
  insert into core.painel_acessos (principal_id, funcao, alvo) values (v_eu, p_funcao, p_alvo);
  if random() < 0.01 then
    delete from core.painel_acessos
     where em < now() - make_interval(days => coalesce(nullif(core.cfg('painel.retencao_acessos_dias','180'),'')::int, 180));
  end if;
  return v_eu;
end $$;

-- regras de sessão (a tela precisa saber antes de mostrar qualquer dado)
create or replace function public.painel_sessao_regras() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('sessao_regras', null, false);
  return jsonb_build_object(
    'inatividade_horas', greatest(coalesce(nullif(core.cfg('painel.sessao_inatividade_horas', '12'), '')::int, 12), 1),
    'dias', greatest(coalesce(nullif(core.cfg('painel.sessao_dias', '7'), '')::int, 7), 1),
    'pode_alterar', coalesce(auth.jwt()->>'aal', '') = 'aal2' and painel._pode(v_eu, 'administrar'));
end $$;

create or replace function public.painel_sessao_definir(p_inatividade_horas int, p_dias int, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_motivo text; v_antes jsonb;
begin
  v_eu := painel._entrar('sessao_definir', p_inatividade_horas || 'h/' || p_dias || 'd');
  perform painel._exigir(v_eu, 'administrar');
  v_motivo := painel._texto(5, p_motivo, 'motivo');
  if p_inatividade_horas is null or p_inatividade_horas not between 1 and 72 then
    raise exception 'tempo sem uso deve ficar entre 1 e 72 horas' using errcode = '22023';
  end if;
  if p_dias is null or p_dias not between 1 and 30 then
    raise exception 'pedir login de novo deve ficar entre 1 e 30 dias' using errcode = '22023';
  end if;
  v_antes := jsonb_build_object('inatividade_horas', core.cfg('painel.sessao_inatividade_horas', '12'), 'dias', core.cfg('painel.sessao_dias', '7'));
  insert into core.config (chave, valor) values ('painel.sessao_inatividade_horas', p_inatividade_horas::text), ('painel.sessao_dias', p_dias::text)
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  perform core.auditar(v_eu, null, 'painel_sessao_definida', 'config', 'painel.sessao', v_antes,
    jsonb_build_object('inatividade_horas', p_inatividade_horas, 'dias', p_dias, 'canal', 'painel'), v_motivo);
end $$;

do $$ begin
  revoke all on function painel._totp_em() from public;
  revoke all on function public.painel_sessao_regras() from public;
  revoke all on function public.painel_sessao_definir(int, int, text) from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function painel._totp_em() from anon, authenticated';
    execute 'revoke all on function public.painel_sessao_regras() from anon';
    execute 'revoke all on function public.painel_sessao_definir(int, int, text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.painel_sessao_regras() to authenticated';
    execute 'grant execute on function public.painel_sessao_definir(int, int, text) to authenticated';
  end if;
end $$;
