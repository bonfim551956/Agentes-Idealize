-- =============================================================================
-- Idealize AI — Agente Supervisor (v0.1.0)  · Migração 20261027160000
--
-- Vigia a plataforma inteira e avisa o Diego. A cada verificação:
--   • saúde de cada agente: leu no prazo? ficou ligado pela metade? fila parada, tarefa presa sem conferência?
--   • conferência reprovada pelo validador, incidentes abertos, aprovações esperando, custo perto do limite,
--     integração com problema, modo seguro ligado;
--   • auditoria: refaz a cadeia de hash; se alguém adulterou, abre incidente CRÍTICO e liga o modo seguro;
--   • amostragem na fonte: sorteia registros do espelho e compara com o sistema de origem (Asaas, Kommo, ADM),
--     separando o que mudou depois da leitura do que está realmente diferente.
-- Os problemas viram "achados", que se resolvem sozinhos quando o problema some. Avisos pelo WhatsApp:
-- urgente na hora (grave ainda não avisado) e resumo nos horários definidos. Texto só com contagens e nomes de
-- agentes/lojas — nunca cliente, telefone, CPF ou valor de pessoa.
-- Nasce PAUSADO, verificação DESLIGADA (sup.sync.ativo) e envio DESLIGADO (sup.enviar): mensagens ficam em
-- "sombra" (registradas, não enviadas). Não altera dado de nenhum agente; a única ação permitida fora do próprio
-- schema é LIGAR o modo seguro (nunca desligar).
-- =============================================================================

create schema if not exists sup;
revoke all on schema sup from public;

create or replace function sup._hoje() returns date
language sql stable set search_path = pg_catalog as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create or replace function sup._sev(p text) returns int
language sql immutable set search_path = pg_catalog as $$
  select coalesce(array_position(array['info','baixa','media','alta','critica'], p), 0)
$$;

-- Prazo máximo entre leituras de cada agente (folga sobre a frequência de agendamento) e a chave que o liga
create table sup.limites (
  agente_id   text primary key references core.agentes(id),
  chave_ativo text not null,
  max_minutos int check (max_minutos is null or max_minutos between 5 and 10080)
);

create table sup.verificacoes (
  id              uuid primary key default gen_random_uuid(),
  tarefa_id       uuid references core.tarefas(id),
  em              timestamptz not null default now(),
  abertos         int not null,
  novos           int not null,
  resolvidos      int not null,
  auditoria_ok    boolean not null,
  auditoria_falha bigint,
  modo_seguro_acionado boolean not null default false
);
create index sup_verificacoes_tarefa on sup.verificacoes (tarefa_id);
create index sup_verificacoes_em on sup.verificacoes (em desc);

create table sup.achados (
  id             bigint generated always as identity primary key,
  tipo           text not null,
  referencia     text not null,
  agente_id      text,
  severidade     text not null check (severidade in ('info','baixa','media','alta','critica')),
  titulo         text not null,
  detalhe        jsonb,
  status         text not null default 'aberto' check (status in ('aberto','resolvido')),
  aberto_em      timestamptz not null default now(),
  visto_em       timestamptz not null default now(),
  resolvido_em   timestamptz,
  notificado_em  timestamptz,
  verificacao_id uuid references sup.verificacoes(id)
);
create unique index sup_achados_aberto on sup.achados (tipo, referencia) where status = 'aberto';
create index sup_achados_status on sup.achados (status, severidade);
create index sup_achados_verificacao on sup.achados (verificacao_id);

-- Conferência por amostragem na fonte (só contagens e ids de sistema; nada pessoal)
create table sup.amostras (
  id              bigint generated always as identity primary key,
  tarefa_id       uuid references core.tarefas(id),
  agente_id       text not null references core.agentes(id),
  em              timestamptz not null default now(),
  conferidos      int not null,
  iguais          int not null,
  mudaram_depois  int not null,
  nao_encontrados int not null,
  divergentes     int not null,
  detalhe         jsonb not null default '[]',
  erro            text                       -- leitura da fonte falhou (sem conferência nesta rodada)
);
create index sup_amostras_agente on sup.amostras (agente_id, em desc);
create index sup_amostras_tarefa on sup.amostras (tarefa_id);

create table sup.mensagens (
  id         bigint generated always as identity primary key,
  chave      text not null unique,
  tipo       text not null check (tipo in ('urgente','resumo')),
  texto      text not null,
  achados    bigint[] not null default '{}',
  status     text not null check (status in ('sombra','pendente','enviada','falhou','bloqueada')),
  destinos   int not null default 0,
  tarefa_id  uuid references core.tarefas(id),
  criada_em  timestamptz not null default now(),
  enviada_em timestamptz,
  erro       text
);
create index sup_mensagens_criada on sup.mensagens (criada_em desc);
create index sup_mensagens_tarefa on sup.mensagens (tarefa_id);

insert into core.config (chave, valor) values
  ('sup.sync.ativo', 'false'),
  ('sup.enviar', 'false'),                      -- false = modo sombra: monta e registra, não envia
  ('sup.horarios_resumo', '7,12,18'),          -- horas (São Paulo) do resumo de rotina
  ('sup.destinos_papeis', 'admin'),            -- quem recebe: pessoas ativas com esse papel e telefone cadastrado
  ('sup.auto_modo_seguro', 'true'),            -- auditoria adulterada → liga o modo seguro
  ('sup.amostra_tamanho', '10'),
  ('sup.tarefa_presa_min', '30'),
  ('sup.fila_parada_min', '120'),
  ('sup.aprovacao_parada_horas', '4'),
  ('sup.custo_aviso_pct', '80'),
  ('versao_sup', '0.1.0')
on conflict (chave) do nothing;

insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('supervisor', 'Agente Supervisor', 'tecnologia', 'pausado', '0.1.0',
   'Vigia todos os agentes: leituras no prazo, falhas, conferências reprovadas, incidentes, aprovações, custo, auditoria e amostragem direto na fonte. Avisa pelo WhatsApp. Não altera dado de nenhum agente; só pode ligar o modo seguro.')
on conflict (id) do nothing;

insert into sup.limites (agente_id, chave_ativo, max_minutos)
select v.a, v.c, v.m from (values
  ('laboratorio', 'lab.sync.ativo', 60), ('comercial', 'com.sync.ativo', 60), ('marketing', 'mkt.sync.ativo', 180),
  ('caixa', 'cx.sync.ativo', 720), ('cobrancas', 'cob.sync.ativo', 1440), ('rh', 'rh.sync.ativo', 2160),
  ('atribuicao', 'atr.sync.ativo', 2160), ('financeiro', 'fin.whatsapp.ativo', null), ('supervisor', 'sup.sync.ativo', 180)) v(a, c, m)
where exists (select 1 from core.agentes where id = v.a)
on conflict (agente_id) do nothing;

insert into core.papeis (id, nome) values ('agente_supervisor', 'Agente supervisor (máquina)') on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', 'Agente Supervisor', 'supervisor' where not exists (select 1 from core.principais where agente_id = 'supervisor');
insert into core.principal_papeis (principal_id, papel_id)
select id, 'agente_supervisor' from core.principais where agente_id = 'supervisor' on conflict do nothing;
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_supervisor', v.r, v.o, 'baixo', 'automatica'
from (values ('sup.verificacao', 'sincronizar'), ('sup.notificacao', 'enviar_resumo'), ('core.plataforma', 'acionar_modo_seguro')) v(r, o)
where not exists (select 1 from core.politicas where papel_id = 'agente_supervisor' and recurso = v.r and operacao = v.o and ativo);
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_supervisor', v.r, v.o, 'alto', 'proibida'
from (values ('core.plataforma', 'desligar_modo_seguro'), ('sup.verificacao', 'alterar_agente'), ('sup.verificacao', 'alterar_politica'),
             ('sup.verificacao', 'apagar_auditoria'), ('sup.verificacao', 'alterar_dados'), ('sup.verificacao', 'excluir'),
             ('sup.notificacao', 'enviar_para_terceiros')) v(r, o)
where not exists (select 1 from core.politicas where papel_id = 'agente_supervisor' and recurso = v.r and operacao = v.o and ativo);
insert into core.integracoes (id, nome, status, credencial_leitura, observacoes) values
  ('zapi_avisos', 'Z-API — avisos do Supervisor', 'nao_verificada', 'SUP_ZAPI_INSTANCIA',
   'Só envio de texto para as pessoas cadastradas com o papel de sup.destinos_papeis. Segredos SUP_ZAPI_INSTANCIA, SUP_ZAPI_TOKEN, SUP_ZAPI_CLIENT_TOKEN.')
on conflict (id) do nothing;

create or replace function sup._cfg_int(p_chave text, p_padrao int) returns int
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(nullif(core.cfg(p_chave, p_padrao::text), '')::int, p_padrao)
$$;

create or replace function sup._principal() returns uuid
language sql stable security definer set search_path = core, pg_catalog as $$
  select id from core.principais where agente_id = 'supervisor'
$$;

-- ---------------------------------------------------------------------------
-- Saúde de cada agente
-- ---------------------------------------------------------------------------
create or replace view sup.v_ultimas as
  select 'laboratorio'::text agente_id, max(em) em from lab.sincronizacoes
  union all select 'comercial', max(em) from com.sincronizacoes
  union all select 'marketing', max(em) from mkt.sincronizacoes
  union all select 'caixa', max(em) from cx.sincronizacoes
  union all select 'cobrancas', max(em) from cob.sincronizacoes
  union all select 'rh', max(em) from rh.sincronizacoes
  union all select 'atribuicao', max(em) from atr.sincronizacoes
  union all select 'supervisor', max(em) from sup.verificacoes;

create or replace view sup.v_alertas as
  select 'laboratorio'::text agente_id, count(*)::int abertos from lab.alertas where status = 'aberto'
  union all select 'comercial', count(*)::int from com.alertas where status = 'aberto'
  union all select 'marketing', count(*)::int from mkt.alertas where status = 'aberto'
  union all select 'caixa', count(*)::int from cx.alertas where status = 'aberto'
  union all select 'cobrancas', count(*)::int from cob.alertas where status = 'aberto'
  union all select 'rh', count(*)::int from rh.alertas where status = 'aberto'
  union all select 'supervisor', count(*)::int from sup.achados where status = 'aberto';

create or replace view sup.v_saude as
  select a.id agente_id, a.nome, a.status, a.atualizado_em agente_atualizado_em,
         coalesce(core.cfg(l.chave_ativo, 'false') = 'true', false) sync_ativo, l.max_minutos limite_min,
         u.em ultima_leitura,
         case when u.em is null then null else floor(extract(epoch from now() - u.em) / 60)::int end minutos_desde,
         coalesce(al.abertos, 0) alertas_abertos,
         (select count(*)::int from core.tarefas t where t.agente_id = a.id and t.status in ('falhou','incerta','bloqueada')
           and t.atualizado_em > now() - interval '24 hours') problemas_24h,
         (select t.status from core.tarefas t where t.agente_id = a.id order by t.criado_em desc limit 1) ultima_tarefa
  from core.agentes a
  left join sup.limites l on l.agente_id = a.id
  left join sup.v_ultimas u on u.agente_id = a.id
  left join sup.v_alertas al on al.agente_id = a.id
  where a.status <> 'desativado';

-- ---------------------------------------------------------------------------
-- Amostragem na fonte
--   sup.amostra_pedir: sorteia ids do espelho;  sup.amostra_registrar: compara o que a fonte devolveu com o espelho
--   (a comparação é feita AQUI, no banco, e não pela função que leu a fonte).
-- ---------------------------------------------------------------------------
create or replace function sup.amostra_pedir(p_agente text, p_n int default null) returns jsonb
language plpgsql security definer set search_path = sup, core, pg_catalog as $$
declare n int := least(greatest(coalesce(p_n, sup._cfg_int('sup.amostra_tamanho', 10)), 1), 50);
begin
  if p_agente = 'cobrancas' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'unidade_id', unidade_id)), '[]') from (select id, unidade_id from cob.asaas order by random() limit n) x);
  elsif p_agente = 'comercial' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', id)), '[]') from (select id from com.leads where not excluido order by random() limit n) x);
  elsif p_agente = 'laboratorio' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id', id_origem)), '[]') from (select id_origem from lab.os order by random() limit n) x);
  end if;
  raise exception 'agente % sem conferência na fonte', p_agente;
end $$;

-- p_itens: [{id, encontrado, campos:{...}}]
--   cobrancas:   campos {status, valor, pagamento(AAAA-MM-DD)}
--   comercial:   campos {funil_id, etapa_id, responsavel_id, valor, atualizado_em(epoch s)}
--   laboratorio: campos {col, cancelado, nao_retirado, ts(epoch ms)}
create or replace function sup.amostra_registrar(p_tarefa uuid, p_agente text, p_itens jsonb) returns jsonb
language plpgsql security definer set search_path = sup, core, pg_catalog as $$
declare it jsonb; c jsonb; v_id text; r text; dif text[]; det jsonb := '[]';
  n_conf int := 0; n_ig int := 0; n_dep int := 0; n_nao int := 0; n_div int := 0;
  m_cob record; m_com record; m_lab record; v_sync timestamptz;
begin
  if p_agente not in ('cobrancas','comercial','laboratorio') then raise exception 'agente % sem conferência na fonte', p_agente; end if;
  if jsonb_typeof(p_itens) is distinct from 'array' or jsonb_array_length(p_itens) > 50 then
    raise exception 'amostra inválida (lista de até 50 itens)';
  end if;
  for it in select * from jsonb_array_elements(p_itens) loop
    v_id := it->>'id'; c := coalesce(it->'campos', '{}'); dif := '{}'; r := null;
    if v_id is null or v_id !~ '^[A-Za-z0-9_:-]{1,80}$' then continue; end if;

    if p_agente = 'cobrancas' then
      select a.*, s.em sync_em into m_cob from cob.asaas a left join cob.sincronizacoes s on s.id = a.sincronizacao_id where a.id = v_id;
      if not found then continue; end if;
      if coalesce((it->>'encontrado')::boolean, false) is false then r := 'nao_encontrado';
      else
        if abs(coalesce((c->>'valor')::numeric, -1) - m_cob.valor) > 0.01 then dif := array_append(dif, 'valor'); end if;
        if c->>'status' is distinct from m_cob.status then
          if (m_cob.status in ('PENDING','OVERDUE') and c->>'status' in ('RECEIVED','CONFIRMED','RECEIVED_IN_CASH')
                and (c->>'pagamento' is null or (c->>'pagamento')::date >= coalesce(m_cob.sync_em, now())::date - 1))
             or (m_cob.status = 'PENDING' and c->>'status' = 'OVERDUE' and m_cob.vencimento < sup._hoje())
             or (m_cob.status = 'CONFIRMED' and c->>'status' = 'RECEIVED') then
            if cardinality(dif) = 0 then r := 'mudou_depois'; end if;
          else dif := array_append(dif, 'status'); end if;
        end if;
      end if;

    elsif p_agente = 'comercial' then
      begin v_id := (v_id::bigint)::text; exception when others then continue; end;
      select * into m_com from com.leads where id = v_id::bigint;
      if not found then continue; end if;
      if coalesce((it->>'encontrado')::boolean, false) is false then r := 'nao_encontrado';
      elsif (c->>'atualizado_em') ~ '^[0-9]{9,11}$' and to_timestamp((c->>'atualizado_em')::bigint) > m_com.atualizado_em then r := 'mudou_depois';
      else
        if (c->>'funil_id')::bigint is distinct from m_com.funil_id then dif := array_append(dif, 'funil'); end if;
        if (c->>'etapa_id')::bigint is distinct from m_com.etapa_id then dif := array_append(dif, 'etapa'); end if;
        if nullif((c->>'responsavel_id')::bigint, 0) is distinct from m_com.responsavel_id then dif := array_append(dif, 'responsavel'); end if;
        if abs(coalesce((c->>'valor')::numeric, 0) - coalesce(m_com.valor, 0)) > 0.01 then dif := array_append(dif, 'valor'); end if;
      end if;

    else
      select * into m_lab from lab.os where id_origem = v_id;
      if not found then continue; end if;
      if coalesce((it->>'encontrado')::boolean, false) is false then r := 'nao_encontrado';
      elsif (c->>'ts') ~ '^[0-9]{10,14}$' and m_lab.ultima_mov is not null
            and (c->>'ts')::bigint > floor(extract(epoch from m_lab.ultima_mov) * 1000)::bigint + 999 then r := 'mudou_depois';
      else
        if (c->>'col')::int is distinct from m_lab.col then dif := array_append(dif, 'etapa'); end if;
        if coalesce((c->>'cancelado')::boolean, false) is distinct from m_lab.cancelado then dif := array_append(dif, 'cancelado'); end if;
        if coalesce((c->>'nao_retirado')::boolean, false) is distinct from m_lab.nao_retirado then dif := array_append(dif, 'nao_retirado'); end if;
      end if;
    end if;

    n_conf := n_conf + 1;
    if r is null then r := case when cardinality(dif) > 0 then 'divergente' else 'igual' end; end if;
    case r when 'igual' then n_ig := n_ig + 1; when 'mudou_depois' then n_dep := n_dep + 1;
           when 'nao_encontrado' then n_nao := n_nao + 1; else n_div := n_div + 1; end case;
    if r in ('divergente','nao_encontrado') and jsonb_array_length(det) < 20 then
      det := det || jsonb_build_object('id', v_id, 'resultado', r, 'campos', to_jsonb(dif));
    end if;
  end loop;
  insert into sup.amostras (tarefa_id, agente_id, conferidos, iguais, mudaram_depois, nao_encontrados, divergentes, detalhe)
  values (p_tarefa, p_agente, n_conf, n_ig, n_dep, n_nao, n_div, det);
  return jsonb_build_object('agente', p_agente, 'conferidos', n_conf, 'iguais', n_ig, 'mudaram_depois', n_dep,
    'nao_encontrados', n_nao, 'divergentes', n_div);
end $$;

-- ---------------------------------------------------------------------------
-- Verificação completa
-- ---------------------------------------------------------------------------
create or replace function sup.verificar(p_tarefa uuid) returns jsonb
language plpgsql security definer set search_path = sup, core, pg_catalog as $$
declare v_id uuid := gen_random_uuid(); v_aud bigint; n_novos int; n_resolv int; n_abertos int; v_modo boolean := false;
  v_presa int := sup._cfg_int('sup.tarefa_presa_min', 30); v_fila int := sup._cfg_int('sup.fila_parada_min', 120);
  v_aprov int := sup._cfg_int('sup.aprovacao_parada_horas', 4); v_custo int := sup._cfg_int('sup.custo_aviso_pct', 80);
begin
  v_aud := core.verificar_auditoria();
  insert into sup.verificacoes (id, tarefa_id, abertos, novos, resolvidos, auditoria_ok, auditoria_falha)
  values (v_id, p_tarefa, 0, 0, 0, v_aud is null, v_aud);

  drop table if exists _sup_atual;
  create temp table _sup_atual (tipo text, referencia text, agente_id text, severidade text, titulo text, detalhe jsonb) on commit drop;

  -- 0. auditoria adulterada (antes de tudo: o incidente que ela abre entra nesta mesma verificação) → crítico e modo seguro
  if v_aud is not null then
    insert into _sup_atual values ('auditoria_adulterada', 'cadeia', null, 'critica',
      'Auditoria: registro ' || v_aud || ' foi alterado ou apagado (cadeia de hash quebrada)', jsonb_build_object('registro', v_aud));
    if core.cfg('sup.auto_modo_seguro', 'true') = 'true' and core.cfg('plataforma_pausada', 'false') <> 'true'
       and (core.autorizar(sup._principal(), 'core.plataforma', 'acionar_modo_seguro', null)).categoria = 'automatica' then
      insert into core.config (chave, valor) values ('plataforma_pausada', 'true')
      on conflict (chave) do update set valor = 'true', atualizado_em = now();
      perform core.auditar(sup._principal(), 'supervisor', 'modo_seguro_acionado', 'config', 'plataforma_pausada',
        jsonb_build_object('valor', 'false'), jsonb_build_object('valor', 'true'), 'auditoria adulterada no registro ' || v_aud);
      perform core.abrir_incidente('auditoria:adulterada', 'critica', 'Auditoria adulterada: modo seguro ligado pelo Supervisor',
        'supervisor', null, p_tarefa, jsonb_build_object('registro', v_aud));
      v_modo := true;
    end if;
  end if;

  -- 1. agente ligado sem ler no prazo
  insert into _sup_atual
  select 'agente_atrasado', s.agente_id, s.agente_id, 'alta',
         s.nome || case when s.ultima_leitura is null then ': ainda não leu nenhuma vez'
                        else ': sem leitura há ' || case when s.minutos_desde >= 120 then (s.minutos_desde / 60) || ' h' else s.minutos_desde || ' min' end end
                || ' (limite ' || case when s.limite_min >= 120 then (s.limite_min / 60) || ' h' else s.limite_min || ' min' end || ')',
         jsonb_build_object('ultima_leitura', s.ultima_leitura, 'limite_min', s.limite_min)
  from sup.v_saude s
  where s.status = 'ativo' and s.sync_ativo and s.limite_min is not null and s.agente_id <> 'supervisor'
    and coalesce(s.ultima_leitura, s.agente_atualizado_em) < now() - make_interval(mins => s.limite_min);

  -- 2. ligado pela metade (agente ativo e leitura desligada, ou o contrário)
  insert into _sup_atual
  select 'ligado_pela_metade', s.agente_id, s.agente_id, 'media',
         s.nome || case when s.status = 'ativo' then ': agente ativo, mas a leitura está desligada' else ': leitura ligada, mas o agente está ' || s.status end,
         jsonb_build_object('agente', s.status, 'leitura', s.sync_ativo)
  from sup.v_saude s join sup.limites l on l.agente_id = s.agente_id
  where (s.status = 'ativo') <> s.sync_ativo and s.agente_id <> 'supervisor';

  -- 3. conferência reprovada (o validador independente bloqueou o resultado)
  insert into _sup_atual
  select 'conferencia_reprovada', t.id::text, t.agente_id, 'alta',
         coalesce((select nome from core.agentes where id = t.agente_id), t.agente_id) || ': o conferente reprovou uma leitura',
         jsonb_build_object('tarefa', t.id, 'motivo', left(t.motivo, 300), 'em', t.atualizado_em)
  from core.tarefas t
  where t.status = 'bloqueada' and t.motivo like 'validação rejeitada%' and t.atualizado_em > now() - interval '7 days';

  -- 4. tarefa presa: executou e ninguém conferiu, travou no meio, ou fila parada
  insert into _sup_atual
  select 'tarefa_presa', t.id::text, t.agente_id, case when t.status = 'pronta' then 'media' else 'alta' end,
         coalesce((select nome from core.agentes where id = t.agente_id), t.agente_id) || case t.status
           when 'validando' then ': leitura feita e não conferida'
           when 'executando' then ': tarefa travou no meio da execução'
           else ': fila parada (tarefa pronta e ninguém pegou)' end,
         jsonb_build_object('tarefa', t.id, 'status', t.status, 'desde', t.atualizado_em)
  from core.tarefas t join core.agentes a on a.id = t.agente_id
  where t.id is distinct from p_tarefa and (
        (t.status = 'validando' and t.atualizado_em < now() - make_interval(mins => v_presa))
     or (t.status = 'executando' and t.lease_ate < now() - interval '5 minutes')
     or (t.status = 'pronta' and a.status = 'ativo' and t.proximo_em < now() - make_interval(mins => v_fila)));

  -- 5. incidentes abertos (falhas repetidas, tarefas incertas, custo, envio etc.)
  insert into _sup_atual
  select 'incidente', i.id::text, i.agente_id, i.severidade, i.titulo,
         jsonb_build_object('incidente', i.id, 'ocorrencias', i.ocorrencias, 'desde', i.primeira_em, 'ultima', i.ultima_em)
  from core.incidentes i where i.status <> 'resolvido';

  -- 6. aprovação esperando há muito tempo
  insert into _sup_atual
  select 'aprovacao_parada', t.id::text, t.agente_id, 'media',
         coalesce((select nome from core.agentes where id = t.agente_id), t.agente_id) || ': pedido esperando aprovação há '
           || floor(extract(epoch from now() - t.criado_em) / 3600) || ' h',
         jsonb_build_object('tarefa', t.id, 'desde', t.criado_em)
  from core.tarefas t where t.status = 'aguardando_aprovacao' and t.criado_em < now() - make_interval(hours => v_aprov);

  -- 7. custo do mês perto do limite
  insert into _sup_atual
  select 'custo', a.id, a.id, case when core.custo_mes(a.id) >= a.limite_custo_mensal then 'alta' else 'media' end,
         a.nome || ': ' || round(100 * core.custo_mes(a.id) / a.limite_custo_mensal) || '% do limite de custo do mês',
         jsonb_build_object('gasto', core.custo_mes(a.id), 'limite', a.limite_custo_mensal)
  from core.agentes a where a.limite_custo_mensal > 0 and core.custo_mes(a.id) >= a.limite_custo_mensal * v_custo / 100.0;

  -- 8. integração com problema
  insert into _sup_atual
  select 'integracao', g.id, null, 'alta', g.nome || ': integração ' || g.status, jsonb_build_object('status', g.status)
  from core.integracoes g where g.status in ('degradada','indisponivel','isolada');

  -- 9. amostragem na fonte com diferença (última amostra de cada agente nas últimas 48 h)
  insert into _sup_atual
  select 'fonte_diverge', m.agente_id, m.agente_id, 'alta',
         coalesce((select nome from core.agentes where id = m.agente_id), m.agente_id) || ': ' || (m.divergentes + m.nao_encontrados)
           || ' de ' || m.conferidos || ' registros conferidos na fonte não batem com o espelho',
         jsonb_build_object('amostra', m.id, 'divergentes', m.divergentes, 'nao_encontrados', m.nao_encontrados, 'itens', m.detalhe)
  from (select distinct on (agente_id) * from sup.amostras where em > now() - interval '48 hours' and erro is null order by agente_id, em desc, id desc) m
  where m.divergentes > 0 or m.nao_encontrados * 2 > greatest(m.conferidos, 1);

  -- 10. não conseguiu conferir na fonte (última tentativa de cada agente falhou)
  insert into _sup_atual
  select 'amostra_falhou', m.agente_id, m.agente_id, 'media',
         coalesce((select nome from core.agentes where id = m.agente_id), m.agente_id) || ': não consegui conferir na fonte (' || left(m.erro, 120) || ')',
         jsonb_build_object('amostra', m.id, 'em', m.em)
  from (select distinct on (agente_id) * from sup.amostras where em > now() - interval '48 hours' order by agente_id, em desc, id desc) m
  where m.erro is not null;

  -- 11. modo seguro ligado (tudo parado, menos monitoramento)
  insert into _sup_atual
  select 'modo_seguro', 'plataforma', null, 'alta', 'Modo seguro ligado: os agentes estão parados', null
  where core.cfg('plataforma_pausada', 'false') = 'true';

  -- consolida: novos entram, existentes atualizam (subiu de gravidade → avisa de novo), sumidos se resolvem
  insert into sup.achados (tipo, referencia, agente_id, severidade, titulo, detalhe, verificacao_id)
  select distinct on (a.tipo, a.referencia) a.tipo, a.referencia, a.agente_id, a.severidade, left(a.titulo, 300), a.detalhe, v_id
  from _sup_atual a
  where not exists (select 1 from sup.achados x where x.status = 'aberto' and x.tipo = a.tipo and x.referencia = a.referencia);
  get diagnostics n_novos = row_count;

  update sup.achados x set
    notificado_em = case when sup._sev(a.severidade) > sup._sev(x.severidade) then null else x.notificado_em end,
    severidade = a.severidade, titulo = left(a.titulo, 300), detalhe = a.detalhe, visto_em = now()
  from _sup_atual a
  where x.status = 'aberto' and x.tipo = a.tipo and x.referencia = a.referencia and x.verificacao_id is distinct from v_id;

  update sup.achados x set status = 'resolvido', resolvido_em = now()
  where x.status = 'aberto' and not exists (select 1 from _sup_atual a where a.tipo = x.tipo and a.referencia = x.referencia);
  get diagnostics n_resolv = row_count;

  select count(*) into n_abertos from sup.achados where status = 'aberto';
  update sup.verificacoes set abertos = n_abertos, novos = n_novos, resolvidos = n_resolv, modo_seguro_acionado = v_modo where id = v_id;
  return jsonb_build_object('verificacao', v_id, 'abertos', n_abertos, 'novos', n_novos, 'resolvidos', n_resolv,
    'auditoria_ok', v_aud is null, 'modo_seguro_acionado', v_modo);
end $$;

-- ---------------------------------------------------------------------------
-- Textos dos avisos (só contagens e nomes de agentes/lojas)
-- ---------------------------------------------------------------------------
create or replace function sup.texto_resumo() returns text
language plpgsql stable security definer set search_path = sup, core, pg_catalog as $$
declare v text; n_dia int; n_atr int; n_desl int; n_grave int; n_aten int; v_alertas text; v_lista text; v_aprov int; v_aud boolean;
begin
  select count(*) filter (where status = 'ativo' and not exists (select 1 from sup.achados x where x.status = 'aberto' and x.tipo = 'agente_atrasado' and x.referencia = s.agente_id)),
         count(*) filter (where status = 'ativo' and exists (select 1 from sup.achados x where x.status = 'aberto' and x.tipo = 'agente_atrasado' and x.referencia = s.agente_id)),
         count(*) filter (where status <> 'ativo')
    into n_dia, n_atr, n_desl
  from sup.v_saude s where s.agente_id <> 'supervisor';
  select count(*) filter (where sup._sev(severidade) >= 4), count(*) filter (where sup._sev(severidade) between 2 and 3)
    into n_grave, n_aten from sup.achados where status = 'aberto';
  select string_agg(s.nome || ' ' || s.alertas_abertos, ' · ' order by s.alertas_abertos desc)
    into v_alertas from sup.v_saude s where s.alertas_abertos > 0 and s.agente_id <> 'supervisor';
  select string_agg('• ' || titulo, E'\n' order by sup._sev(severidade) desc, aberto_em) into v_lista
    from (select titulo, severidade, aberto_em from sup.achados where status = 'aberto' order by sup._sev(severidade) desc, aberto_em limit 6) x;
  select count(*) into v_aprov from core.tarefas where status = 'aguardando_aprovacao';
  select auditoria_ok into v_aud from sup.verificacoes order by em desc limit 1;

  v := 'Idealize AI — resumo das ' || extract(hour from now() at time zone 'America/Sao_Paulo') || 'h' || E'\n\n'
    || 'Agentes: ' || n_dia || ' em dia' || case when n_atr > 0 then ', ' || n_atr || ' atrasado(s)' else '' end
    || case when n_desl > 0 then ', ' || n_desl || ' desligado(s)' else '' end || E'\n'
    || 'Problemas abertos: ' || case when n_grave + n_aten = 0 then 'nenhum' else n_grave || ' grave(s), ' || n_aten || ' de atenção' end || E'\n'
    || 'Alertas dos agentes: ' || coalesce(v_alertas, 'nenhum') || E'\n'
    || 'Aprovações esperando: ' || v_aprov || E'\n'
    || 'Auditoria: ' || case when v_aud is false then 'ADULTERADA' when v_aud then 'íntegra' else 'ainda não conferida' end
    || coalesce(E'\n\n' || v_lista, '')
    || E'\n\nDetalhes no painel, tela Supervisor.';
  return left(v, 3500);
end $$;

create or replace function sup.texto_urgente(p_ids bigint[]) returns text
language sql stable security definer set search_path = sup, core, pg_catalog as $$
  select left('Idealize AI — ATENÇÃO' || E'\n\n' ||
    string_agg('• ' || case when severidade = 'critica' then '[CRÍTICO] ' else '' end || titulo, E'\n' order by sup._sev(severidade) desc, id)
    || E'\n\nDetalhes no painel, tela Supervisor.', 3500)
  from sup.achados where id = any(p_ids)
$$;

-- quem recebe: pessoas ativas, com papel em sup.destinos_papeis e telefone cadastrado (só para o envio)
create or replace function sup.destinos() returns text[]
language sql stable security definer set search_path = core, pg_catalog as $$
  select coalesce(array_agg(distinct p.telefone order by p.telefone), '{}')
  from core.principais p join core.principal_papeis pp on pp.principal_id = p.id
  where p.tipo = 'usuario' and p.ativo and p.telefone ~ '^55[0-9]{10,11}$'
    and (pp.valido_ate is null or pp.valido_ate > now())
    and pp.papel_id = any(string_to_array(core.cfg('sup.destinos_papeis', 'admin'), ','))
$$;

-- Monta os avisos da verificação. Devolve só os que devem ser enviados agora (status pendente).
create or replace function sup.preparar_mensagens(p_tarefa uuid) returns jsonb
language plpgsql security definer set search_path = sup, core, pg_catalog as $$
declare v_ids bigint[]; v_status text; n_dest int := cardinality(sup.destinos()); v_hora int;
  v_horas int[]; v_chave text;
begin
  v_status := case when core.cfg('sup.enviar', 'false') = 'true' and n_dest > 0
                    and (core.autorizar(sup._principal(), 'sup.notificacao', 'enviar_resumo', null)).categoria = 'automatica'
                   then 'pendente' else 'sombra' end;

  select array_agg(id order by id) into v_ids from sup.achados
   where status = 'aberto' and sup._sev(severidade) >= 4 and notificado_em is null;
  if v_ids is not null then
    insert into sup.mensagens (chave, tipo, texto, achados, status, destinos, tarefa_id)
    values ('urgente:' || p_tarefa, 'urgente', sup.texto_urgente(v_ids), v_ids, v_status, case when v_status = 'pendente' then n_dest else 0 end, p_tarefa)
    on conflict (chave) do nothing;
    update sup.achados set notificado_em = now() where id = any(v_ids);
  end if;

  v_hora := extract(hour from now() at time zone 'America/Sao_Paulo');
  begin
    v_horas := string_to_array(replace(core.cfg('sup.horarios_resumo', '7,12,18'), ' ', ''), ',')::int[];
  exception when others then v_horas := array[7,12,18];
  end;
  if v_hora = any(v_horas) then
    v_chave := 'resumo:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDDHH24');
    insert into sup.mensagens (chave, tipo, texto, status, destinos, tarefa_id)
    values (v_chave, 'resumo', sup.texto_resumo(), v_status, case when v_status = 'pendente' then n_dest else 0 end, p_tarefa)
    on conflict (chave) do nothing;
  end if;

  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'texto', texto) order by id), '[]')
          from sup.mensagens where tarefa_id = p_tarefa and status = 'pendente');
end $$;

create or replace function sup.mensagem_resultado(p_id bigint, p_ok boolean, p_erro text default null) returns text
language plpgsql security definer set search_path = sup, core, pg_catalog as $$
declare v text;
begin
  update sup.mensagens set status = case when p_ok then 'enviada' else 'falhou' end,
    enviada_em = case when p_ok then now() end, erro = left(p_erro, 300)
  where id = p_id and status = 'pendente' returning status into v;
  if v is null then raise exception 'mensagem % não está pendente', p_id; end if;
  if not p_ok then
    perform core.abrir_incidente('sup:envio', 'alta', 'Supervisor não conseguiu enviar o aviso pelo WhatsApp', 'supervisor', 'zapi_avisos',
      null, jsonb_build_object('mensagem', p_id, 'erro', left(p_erro, 300)));
  else
    update core.integracoes set status = 'ok', ultimo_ok_em = now() where id = 'zapi_avisos';
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Ciclo: agendar → (amostras) → concluir → validar → enviar
-- ---------------------------------------------------------------------------
create or replace function sup.agendar_verificacao() returns uuid
language plpgsql security definer set search_path = sup, core, pg_catalog as $$
begin
  if core.cfg('sup.sync.ativo', 'false') <> 'true' then return null; end if;
  -- monitoramento: continua rodando mesmo com o modo seguro ligado
  return core.criar_tarefa(sup._principal(), 'supervisor', 'sup_verificacao', 'sup.verificacao', 'sincronizar', null,
    jsonb_build_object('origem', 'plataforma'), 'sup:verif:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDDHH24'),
    null, 2, null, '{}', null, true);
end $$;

-- p_amostras: {"cobrancas":[itens], "comercial":[itens], "laboratorio":[itens]} (cada lista opcional)
-- p_falhas:   {"agente": "motivo"} — fonte que não pôde ser lida nesta rodada
create or replace function sup.concluir_verificacao(p_tarefa uuid, p_executor text, p_amostras jsonb default '{}', p_falhas jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = sup, core, pg_catalog as $$
declare t record; v jsonb; k text; am jsonb := '[]';
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.agente_id is distinct from 'supervisor' or t.tipo is distinct from 'sup_verificacao' then raise exception 'tarefa não é verificação do supervisor'; end if;
  if p_amostras is not null and jsonb_typeof(p_amostras) <> 'object' then raise exception 'amostras inválidas'; end if;
  for k in select jsonb_object_keys(coalesce(p_amostras, '{}')) loop
    am := am || sup.amostra_registrar(p_tarefa, k, p_amostras->k);
  end loop;
  if p_falhas is not null and jsonb_typeof(p_falhas) = 'object' then
    insert into sup.amostras (tarefa_id, agente_id, conferidos, iguais, mudaram_depois, nao_encontrados, divergentes, erro)
    select p_tarefa, f.key, 0, 0, 0, 0, 0, left(regexp_replace(f.value #>> '{}', '[0-9]{10,13}', '#', 'g'), 200)
    from jsonb_each(p_falhas) f where f.key in ('cobrancas','comercial','laboratorio');
  end if;
  v := sup.verificar(p_tarefa) || jsonb_build_object('amostras', am);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', null, v);
  return v;
end $$;

-- Validador independente: refaz as contas a partir das tabelas, sem usar o que o executor devolveu
create or replace function sup.validar_verificacao(p_tarefa uuid, p_validador text) returns text
language plpgsql security definer set search_path = sup, core, pg_catalog as $$
declare t record; v record; e text[] := '{}'; n int; r text;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  select * into v from sup.verificacoes where tarefa_id = p_tarefa order by em desc limit 1;
  if v.id is null then
    e := array_append(e, 'verificação sem registro');
  else
    select count(*) into n from sup.achados where status = 'aberto';
    if n <> v.abertos then e := e || format('%s achados abertos, registro diz %s', n, v.abertos); end if;
    if (core.verificar_auditoria() is null) <> v.auditoria_ok then e := array_append(e, 'resultado da auditoria não confere'); end if;
    if v.auditoria_ok is false and not exists (select 1 from sup.achados where status = 'aberto' and tipo = 'auditoria_adulterada') then
      e := array_append(e, 'auditoria adulterada sem achado aberto');
    end if;
    select count(*) into n from core.incidentes i where i.status <> 'resolvido'
      and not exists (select 1 from sup.achados a where a.status = 'aberto' and a.tipo = 'incidente' and a.referencia = i.id::text);
    if n > 0 then e := e || format('%s incidentes abertos sem achado', n); end if;
    select count(*) into n from sup.achados a where a.status = 'aberto' and a.tipo = 'incidente'
      and not exists (select 1 from core.incidentes i where i.id::text = a.referencia and i.status <> 'resolvido');
    if n > 0 then e := e || format('%s achados de incidente já resolvido', n); end if;
    select count(*) into n from sup.amostras where tarefa_id = p_tarefa
      and conferidos <> iguais + mudaram_depois + nao_encontrados + divergentes;
    if n > 0 then e := array_append(e, 'contagem de amostra não fecha'); end if;
    -- nenhum aviso pode levar telefone, CPF ou e-mail
    select count(*) into n from sup.mensagens where tarefa_id = p_tarefa
      and (texto ~ '(^|[^0-9])[0-9]{10,13}([^0-9]|$)' or texto ~ '[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}' or texto ~ '[^ @]+@[^ @]+\.[a-z]{2,}');
    if n > 0 then e := e || format('%s avisos com possível dado pessoal', n); end if;
  end if;
  if array_length(e, 1) is null then
    return core.registrar_validacao(p_tarefa, p_validador, true, null, jsonb_build_object('verificacao', v.id));
  end if;
  update sup.mensagens set status = 'bloqueada', erro = 'conferência reprovada' where tarefa_id = p_tarefa and status = 'pendente';
  r := core.registrar_validacao(p_tarefa, p_validador, false, array_to_string(e, '; '),
    jsonb_build_object('verificacao', v.id, 'erros', to_jsonb(e)));
  perform core.abrir_incidente('sup:validacao', 'critica', 'Conferência do Supervisor reprovada', 'supervisor', null, p_tarefa,
    jsonb_build_object('erros', to_jsonb(e)));
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- Painel (só escopo global: é a visão da plataforma inteira)
-- ---------------------------------------------------------------------------
create or replace function public.painel_supervisor() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('supervisor');
  perform painel._exigir(v_eu, 'consultar', null);
  return jsonb_build_object(
    'config', jsonb_build_object('ativo', core.cfg('sup.sync.ativo', 'false') = 'true',
       'agente', (select status from core.agentes where id = 'supervisor'),
       'enviar', core.cfg('sup.enviar', 'false') = 'true', 'destinos', cardinality(sup.destinos()),
       'horarios', core.cfg('sup.horarios_resumo', '7,12,18'), 'modo_seguro', core.cfg('plataforma_pausada', 'false') = 'true',
       'auto_modo_seguro', core.cfg('sup.auto_modo_seguro', 'true') = 'true'),
    'ultima', (select jsonb_build_object('em', em, 'abertos', abertos, 'novos', novos, 'resolvidos', resolvidos,
                 'auditoria_ok', auditoria_ok) from sup.verificacoes order by em desc limit 1),
    'agentes', (select coalesce(jsonb_agg(jsonb_build_object('agente_id', s.agente_id, 'nome', s.nome, 'status', s.status,
                  'leitura_ligada', s.sync_ativo, 'ultima_leitura', s.ultima_leitura, 'minutos_desde', s.minutos_desde,
                  'limite_min', s.limite_min, 'alertas_abertos', s.alertas_abertos, 'problemas_24h', s.problemas_24h,
                  'atrasado', exists (select 1 from sup.achados x where x.status = 'aberto' and x.tipo = 'agente_atrasado' and x.referencia = s.agente_id),
                  'amostra', (select jsonb_build_object('em', m.em, 'conferidos', m.conferidos, 'iguais', m.iguais, 'mudaram_depois', m.mudaram_depois,
                                'divergentes', m.divergentes, 'nao_encontrados', m.nao_encontrados)
                              from sup.amostras m where m.agente_id = s.agente_id order by m.em desc, m.id desc limit 1))
                  order by s.nome), '[]') from sup.v_saude s),
    'achados', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'agente_id', agente_id, 'severidade', severidade,
                  'titulo', titulo, 'aberto_em', aberto_em, 'notificado_em', notificado_em)
                  order by sup._sev(severidade) desc, aberto_em), '[]') from sup.achados where status = 'aberto'),
    'resolvidos', (select coalesce(jsonb_agg(x order by x->>'resolvido_em' desc), '[]') from (
                  select jsonb_build_object('id', id, 'tipo', tipo, 'severidade', severidade, 'titulo', titulo,
                    'aberto_em', aberto_em, 'resolvido_em', resolvido_em) x
                  from sup.achados where status = 'resolvido' order by resolvido_em desc limit 20) q),
    'mensagens', (select coalesce(jsonb_agg(x order by (x->>'id')::bigint desc), '[]') from (
                  select jsonb_build_object('id', id, 'tipo', tipo, 'status', status, 'texto', texto, 'criada_em', criada_em,
                    'enviada_em', enviada_em, 'erro', erro) x
                  from sup.mensagens order by id desc limit 10) q),
    'previa', sup.texto_resumo());
end $$;

-- ---------------------------------------------------------------------------
-- Endurecimento
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'sup' loop
    execute format('alter table sup.%I enable row level security', r.tablename);
    execute format('alter table sup.%I force row level security', r.tablename);
    execute format('revoke all on sup.%I from public', r.tablename);
  end loop;
  for r in select viewname from pg_views where schemaname = 'sup' loop
    execute format('revoke all on sup.%I from public', r.viewname);
  end loop;
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'sup' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', r.sig);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema sup from anon, authenticated';
    execute 'revoke all on function public.painel_supervisor() from public, anon';
    execute 'grant execute on function public.painel_supervisor() to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema sup to service_role';
    execute 'grant select on all tables in schema sup to service_role';
    execute 'grant execute on function public.painel_supervisor() to service_role';
  end if;
end $$;
