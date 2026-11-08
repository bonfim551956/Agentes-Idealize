-- =============================================================================
-- Idealize AI — Garantia de que tudo está rodando  · Migração 20261108100000
-- Pedido do Diego (08/11): "a impressão que tenho é que não está rodando 100% nada do que construímos, preciso que
-- você garanta isso". Achados da auditoria de 08/11 e correções:
--  1. Agente do WhatsApp respondia "as tabelas do caixa estão vazias": o papel de leitura batia na segurança por linha
--     (RLS) e via zero linhas. Agora o papel de leitura enxerga os dados (continua sem poder alterar nada).
--  2. "Falar com o agente" do painel respondia só de hora em hora: passa a responder em até 5 minutos (cron
--     wa-notificar), e na hora em que a mensagem é escrita.
--  3. core.saude(): para cada agente/robô, quando rodou pela última vez com sucesso e se está atrasado em relação ao
--     combinado (só no horário em que ele deveria rodar). O que estiver atrasado aparece em "Tudo para resolver"
--     (área Plataforma) e na página inicial.
-- =============================================================================

-- 1. leitura do agente do WhatsApp enxerga os dados (sem poder alterar: só SELECT e transação somente leitura)
alter role wa_leitura bypassrls;

-- 2. respostas do "Falar com o agente" em minutos: a função do WhatsApp atende as mensagens pendentes dos avisos
alter table core.avisos_conversa add column if not exists pego_em timestamptz;

-- o agente "pega" as mensagens antes de responder (evita resposta dobrada entre o cron e o disparo na hora)
create or replace function public.agente_avisos_pegar(p_limite int default 10) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_ids bigint[];
begin
  with p as (
    select m.id from core.avisos_conversa m
     where m.papel = 'pessoa' and not m.respondida and (m.pego_em is null or m.pego_em < now() - interval '10 minutes')
     order by m.criado_em limit least(greatest(coalesce(p_limite, 10), 1), 50) for update skip locked),
  u as (update core.avisos_conversa c set pego_em = now() from p where c.id = p.id returning c.id)
  select array_agg(id) into v_ids from u;
  return (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(public.agente_avisos_pendentes(100)) x where (x->>'id')::bigint = any(coalesce(v_ids, '{}')));
end $$;
revoke all on function public.agente_avisos_pegar(int) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on function public.agente_avisos_pegar(int) from anon, authenticated'; end if;
end $$;

create or replace function public.agente_avisos_chamar() returns trigger
language plpgsql security definer set search_path = core, pg_catalog as $$
begin
  if new.papel = 'pessoa' and not new.respondida then
    begin
      perform core.chamar_agente('agente-whatsapp', 'sup_worker_secret', 120000);
    exception when others then null;   -- sem Vault/pg_net (teste local): o cron de 5 minutos responde
    end;
  end if;
  return null;
end $$;
drop trigger if exists avisos_conversa_chamar on core.avisos_conversa;
create trigger avisos_conversa_chamar after insert on core.avisos_conversa for each row execute function public.agente_avisos_chamar();
revoke all on function public.agente_avisos_chamar() from public;

-- 3. saúde de cada agente e robô
insert into core.config (chave, valor) values ('saude.ativo', 'true') on conflict (chave) do nothing;

create or replace function core.saude() returns table (id text, nome text, ultima timestamptz, limite_min int, no_horario boolean, atrasado boolean, detalhe text)
language plpgsql stable security definer set search_path = core, pg_catalog as $$
declare h int := extract(hour from now() at time zone 'America/Sao_Paulo')::int;
  dow int := extract(dow from now() at time zone 'America/Sao_Paulo')::int;
  comercial boolean := h between 8 and 20;
begin
  return query
  with s(id, nome, ultima, limite_min, no_horario, detalhe) as (
    select 'caixa', 'Agente de Caixa', (select max(em) from cx.sincronizacoes), 90, comercial, 'confere de hora em hora, 8h às 20h'
    union all select 'cobrancas', 'Agente de Cobranças', (select max(atualizado_em) from core.tarefas where agente_id = 'cobrancas' and status = 'concluida'), 90, comercial, 'Asaas × carnês, de hora em hora'
    union all select 'multicrediario', 'Conferência do Multicrediário', (select max(em) from intel.sincronizacoes where agente_id = 'multicrediario'), 90, comercial, 'Multicrediário × ADM, de hora em hora'
    union all select 'robo_multicrediario', 'Robô do Multicrediário (leitura)', (select max(capturado_em) from multi.capturas), 180, comercial and dow between 1 and 6, 'lê o Multicrediário pelo GitHub, de hora em hora'
    union all select 'comercial', 'Agente Comercial', (select max(atualizado_em) from core.tarefas where agente_id = 'comercial' and status = 'concluida'), 45, true, 'Kommo a cada 15 min'
    union all select 'laboratorio', 'Agente de Laboratório', (select max(atualizado_em) from core.tarefas where agente_id = 'laboratorio' and status = 'concluida'), 45, true, 'a cada 15 min'
    union all select 'marketing', 'Agente de Marketing', (select max(atualizado_em) from core.tarefas where agente_id = 'marketing' and status = 'concluida'), 150, true, 'Meta Ads de hora em hora'
    union all select 'supervisor', 'Agente Supervisor', (select max(atualizado_em) from core.tarefas where agente_id = 'supervisor' and status = 'concluida'), 150, true, 'verificação de hora em hora'
    union all select 'atribuicao', 'Agente de Atribuição', (select max(atualizado_em) from core.tarefas where agente_id = 'atribuicao' and status = 'concluida'), 150, comercial, 'de hora em hora, 8h às 20h'
    union all select 'rh', 'Agente de RH', (select max(atualizado_em) from core.tarefas where agente_id = 'rh' and status = 'concluida'), 26 * 60, true, '1 vez por dia'
    union all select 'radar', 'Radar do Mercado', (select max(atualizado_em) from core.tarefas where agente_id = 'radar' and status = 'concluida'), 26 * 60, h >= 8, '1 vez por dia, de manhã'
    union all select 'concorrentes', 'Concorrentes', (select max(atualizado_em) from core.tarefas where agente_id = 'concorrentes' and status = 'concluida'), 26 * 60, h >= 8, '1 vez por dia, de manhã'
    union all select 'conteudo', 'Conteúdo do dia', (select max(atualizado_em) from core.tarefas where agente_id = 'conteudo_roteirista' and status = 'concluida'), 26 * 60, h >= 8, 'ideias, avaliação e roteiros 1 vez por dia'
    union all select 'relatorio', 'Relatório do dia', (select max(gerado_em) from rel.relatorios), 26 * 60, h >= 8, 'gerado às 7h'
    union all select 'financeiro', 'Agente Financeiro (leitura de arquivos)',
      (select coalesce(max(e.atualizado_em), now()) from fin.envios e where e.status in ('aguardando_arquivo', 'lendo') and e.atualizado_em < now() - interval '20 minutes'), 0,
      exists (select 1 from fin.envios e where e.status in ('aguardando_arquivo', 'lendo') and e.atualizado_em < now() - interval '20 minutes'), 'arquivo parado há mais de 20 min sem leitura'
    union all select 'conversoes', 'Conferência de conversões', (select max(em) from intel.sincronizacoes where agente_id = 'conversoes'), 180, h between 10 and 20 and dow between 1 and 6, 'de hora em hora, segunda a sábado'
    union all select 'robo_kommo', 'Robô da Kommo (conversas para auditoria)', (select max(capturado_em) from aud.conversas), 26 * 60, h >= 9, 'lê as conversas das operadoras 1 vez por dia'
    union all select 'auditor_atendimento', 'Auditor de Atendimento', (select max(avaliado_em) from aud.avaliacoes), 26 * 60, h >= 9 and exists (select 1 from aud.conversas), 'avalia as conversas 1 vez por dia'
    union all select 'avisos_conversa', 'Agente do caixa (respostas no painel)',
      (select min(m.criado_em) from core.avisos_conversa m where m.papel = 'pessoa' and not m.respondida), 30,
      exists (select 1 from core.avisos_conversa m where m.papel = 'pessoa' and not m.respondida), 'mensagem de "Falar com o agente" sem resposta'
    union all select 'whatsapp', 'Agente no WhatsApp',
      (select min(m.criado_em) from wa.mensagens m where (m.direcao = 'entrada' and m.status = 'recebida') or (m.direcao = 'saida' and m.status in ('pendente', 'erro'))), 10,
      core.cfg('wa.ativo', 'false') = 'true' and exists (select 1 from wa.mensagens m where m.criado_em > now() - interval '1 day'
        and ((m.direcao = 'entrada' and m.status = 'recebida') or (m.direcao = 'saida' and m.status in ('pendente', 'erro')))), 'mensagem sem resposta ou que não saiu'
  )
  select s.id, s.nome, s.ultima, s.limite_min, s.no_horario,
         s.no_horario and (s.ultima is null or s.ultima < now() - make_interval(mins => s.limite_min)),
         s.detalhe
    from s;
end $$;
revoke all on function core.saude() from public;

create or replace function public.painel_saude() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('saude');
  if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(s) order by s.atrasado desc, s.nome), '[]'::jsonb) from core.saude() s);
end $$;
do $$ begin
  revoke all on function public.painel_saude() from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on function public.painel_saude() from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'grant execute on function public.painel_saude() to authenticated'; end if;
end $$;

-- o que está atrasado aparece em "Tudo para resolver" (área Plataforma, só para quem vê a rede toda)
do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_central(text)'::regprocedure);
  if v !~ 'core.saude' then
    v := replace(v, $a$  if painel._pode(v_eu, 'consultar') then
    insert into _it
    select 'Plataforma', 'Incidente '$a$, $a$  if painel._pode(v_eu, 'consultar') then
    insert into _it (area, tipo, gravidade, unidade_id, dia, titulo, texto, link, desde)
    select 'Plataforma', 'Agente atrasado', 1, null, (now() at time zone 'America/Sao_Paulo')::date, s.nome || ' não rodou no horário',
           s.detalhe || '. Última vez: ' || coalesce(to_char(s.ultima at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), 'nunca') || '.', '/', coalesce(s.ultima, now())
      from core.saude() s where s.atrasado;
    insert into _it
    select 'Plataforma', 'Incidente '$a$);
    if v !~ 'core.saude' then raise exception 'central não foi atualizada'; end if;
    execute v;
  end if;
end $$;

-- página inicial: cada agente leva o seu estado de saúde
do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_inicio()'::regprocedure);
  if v !~ 'core.saude' then
    v := replace(v, $a$'tarefas', (select coalesce(jsonb_agg($a$, $a$'atrasado', (select bool_or(s.atrasado) from core.saude() s where s.id = a.id or (a.id like 'conteudo%' and s.id = 'conteudo')),
      'tarefas', (select coalesce(jsonb_agg($a$);
    if v !~ 'core.saude' then raise exception 'início não foi atualizado'; end if;
    execute v;
  end if;
end $$;
