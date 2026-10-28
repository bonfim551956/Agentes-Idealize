-- =============================================================================
-- Idealize AI — Atribuição: leitura da Kommo em partes  · Migração 20261028010000
-- Achado na 1ª leitura (28/10): ~30 mil leads em 120 dias; ler tudo de uma vez estoura o tempo da função.
-- Agora cada leitura traz:
--   • o que MUDOU na Kommo desde a última leitura (por data de atualização, com 15 min de folga);
--   • mais um pedaço de 15 dias do histórico (do mais novo para o mais velho), até completar 120 dias.
-- Os leads são acrescentados/atualizados (nunca apagados em massa); lead com mais de 180 dias sai do espelho.
-- O cursor só avança quando a leitura grava com sucesso (mesma transação).
-- =============================================================================
insert into core.config (chave, valor) values
  ('atr.carga_pedaco_dias', '15')
on conflict (chave) do nothing;

-- {ate, atualizados_desde|null, carga_de|null, carga_ate|null}  (epoch em segundos)
create or replace function atr.janela() returns jsonb
language plpgsql stable security definer set search_path = atr, core, pg_catalog as $$
declare v_ate bigint := floor(extract(epoch from now()))::bigint;
  v_cursor bigint := nullif(core.cfg('atr.cursor_leads', ''), '')::bigint;
  v_carga bigint := nullif(core.cfg('atr.carga_ate', ''), '')::bigint;
  v_limite bigint := floor(extract(epoch from (atr._hoje() - atr._cfg_int('atr.leads_janela_dias', 120))::timestamptz))::bigint;
  v_pedaco bigint := atr._cfg_int('atr.carga_pedaco_dias', 15) * 86400;
  v_de bigint; v_ate_carga bigint;
begin
  v_ate_carga := coalesce(v_carga, v_ate);
  if v_ate_carga > v_limite then v_de := greatest(v_ate_carga - v_pedaco, v_limite); end if;
  return jsonb_build_object('ate', v_ate,
    'atualizados_desde', case when v_cursor is not null then v_cursor - 900 end,
    'carga_de', v_de, 'carga_ate', case when v_de is not null then v_ate_carga end,
    'carga_completa', v_de is null);
end $$;

-- Lote: {ate, carga_de?, leads:[{id,funil_id,responsavel_id,criado_em,tel_hash,origem}], vendas:[...]}
create or replace function atr.aplicar_lote(p_tarefa uuid, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = atr, com, core, pg_catalog as $$
declare v_s uuid := gen_random_uuid(); n_l int; n_lt int; n_v int; n_c int; n_ign int; n_velhos int;
  v_tipos text[] := string_to_array(core.cfg('atr.tipos_venda', 'venda,hora,avulsa'), ',');
begin
  if jsonb_typeof(p_lote) is distinct from 'object' or jsonb_typeof(p_lote->'leads') is distinct from 'array'
     or jsonb_typeof(p_lote->'vendas') is distinct from 'array' then
    raise exception 'lote sem leads ou vendas';
  end if;
  if jsonb_array_length(p_lote->'vendas') = 0 and exists (select 1 from atr.vendas) then
    raise exception 'lote veio sem vendas e o espelho tem vendas: leitura suspeita, nada foi apagado';
  end if;
  -- nenhum telefone em claro pode entrar: só códigos de 64 hexadecimais
  if exists (select 1 from jsonb_array_elements(p_lote->'leads') x where coalesce(x->>'tel_hash', '') !~ '^([0-9a-f]{64})?$')
     or exists (select 1 from jsonb_array_elements(p_lote->'vendas') x where coalesce(x->>'tel_hash', '') !~ '^([0-9a-f]{64})?$') then
    raise exception 'lote com telefone fora do formato de código: recusado';
  end if;
  if coalesce(p_lote->>'ate', '') !~ '^[0-9]{9,11}$' then raise exception 'lote sem a data da leitura (ate)'; end if;

  -- leads: acrescenta/atualiza (a leitura vem em partes; nada é apagado em massa)
  insert into atr.leads (id, funil_id, unidade_id, responsavel_id, criado_em, tel_hash, origem, sincronizacao_id)
  select distinct on (r.id) r.id, r.funil_id, (select f.unidade_id from com.funis f where f.id = r.funil_id), nullif(r.responsavel_id, 0),
         to_timestamp(r.criado_em), nullif(r.tel_hash, ''), left(nullif(btrim(r.origem), ''), 300), v_s
  from jsonb_to_recordset(p_lote->'leads') r(id bigint, funil_id bigint, responsavel_id bigint, criado_em bigint, tel_hash text, origem text)
  where r.id is not null and r.criado_em > 0
  on conflict (id) do update set funil_id = excluded.funil_id, unidade_id = excluded.unidade_id, responsavel_id = excluded.responsavel_id,
    criado_em = excluded.criado_em,
    tel_hash = excluded.tel_hash, origem = excluded.origem, sincronizacao_id = excluded.sincronizacao_id;
  get diagnostics n_l = row_count;
  select count(*) into n_lt from atr.leads where sincronizacao_id = v_s and tel_hash is not null;
  delete from atr.leads where criado_em < now() - interval '180 days';
  get diagnostics n_velhos = row_count;

  delete from atr.conversoes;
  delete from atr.vendas;
  insert into atr.vendas (id, unidade_id, dia, tipo, valor, tel_hash, sincronizacao_id)
  select r.id, o.unidade_id, r.dia, left(r.tipo, 30), round(coalesce(r.valor, 0), 2), nullif(r.tel_hash, ''), v_s
  from jsonb_to_recordset(p_lote->'vendas') r(id text, unidade text, dia date, tipo text, valor numeric, tel_hash text)
  join atr.unidades_origem o on o.origem = r.unidade
  where coalesce(r.id, '') <> '' and r.dia is not null and lower(coalesce(r.tipo, '')) = any(v_tipos)
  on conflict (id) do nothing;
  get diagnostics n_v = row_count;
  n_ign := jsonb_array_length(p_lote->'leads') - n_l + jsonb_array_length(p_lote->'vendas') - n_v;

  n_c := atr.recalcular();
  insert into atr.sincronizacoes (id, tarefa_id, leads, leads_com_telefone, vendas, conversoes, ignoradas, hash_lote)
  values (v_s, p_tarefa, n_l, n_lt, n_v, n_c, n_ign, md5(p_lote::text));

  -- avança os cursores (só aqui, depois de gravar tudo)
  insert into core.config (chave, valor) values ('atr.cursor_leads', p_lote->>'ate')
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  if coalesce(p_lote->>'carga_de', '') ~ '^[0-9]{9,11}$' then
    insert into core.config (chave, valor) values ('atr.carga_ate', p_lote->>'carga_de')
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  end if;

  return jsonb_build_object('sincronizacao', v_s, 'leads', n_l, 'leads_com_telefone', n_lt, 'vendas', n_v, 'conversoes', n_c,
    'ignoradas', n_ign, 'leads_antigos_removidos', n_velhos, 'leads_no_espelho', (select count(*) from atr.leads),
    'carga_completa', (atr.janela()->>'carga_completa')::boolean, 'hash_lote', md5(p_lote::text));
end $$;

-- uma tarefa por minuto (a carga do histórico pode rodar várias vezes seguidas; o agendamento diário continua 1×/dia)
create or replace function atr.agendar_sincronizacao() returns uuid
language plpgsql security definer set search_path = atr, core, pg_catalog as $$
declare v_p uuid;
begin
  if core.cfg('atr.sync.ativo', 'false') <> 'true' then return null; end if;
  select id into v_p from core.principais where agente_id = 'atribuicao';
  return core.criar_tarefa(v_p, 'atribuicao', 'atr_sincronizacao', 'atr.cruzamento', 'sincronizar', null,
    jsonb_build_object('origem', 'kommo+adm'), 'atr:sync:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDDHH24MI'), null, 6);
end $$;

do $$ declare f text;
begin
  foreach f in array array['atr.janela()', 'atr.aplicar_lote(uuid, jsonb)', 'atr.agendar_sincronizacao()'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon, authenticated', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('grant execute on function %s to service_role', f); end if;
  end loop;
end $$;
