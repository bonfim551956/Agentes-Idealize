-- =============================================================================
-- Idealize AI — Agente no WhatsApp direto com a diretoria  · Migração 20261107250000 — NASCE DESLIGADO
-- Pedido do Diego (07/11): ligar o número da Z-API (11) direto com o WhatsApp dele (final 7862) para: receber os
-- resumos, ser avisado das urgências na hora, fazer perguntas, conversar sobre os avisos e mandar extratos.
--
-- Como funciona (função agente-whatsapp):
--  • O webhook "Ao receber" da Z-API passa a apontar para a função, que REPASSA TUDO, sem mudar nada, para o
--    webhook antigo (Finance AI, grupos, encaminhamento do DDD 82). Nada do que funciona hoje deixa de receber.
--  • Só mensagens no privado, vindas de um número autorizado (pessoa ativa do painel com papel em wa.papeis),
--    são tratadas aqui. Grupo e qualquer outro número: só repasse.
--  • Texto: o agente responde com os dados (consulta só de leitura, papel wa_leitura) e pode registrar a conversa
--    num aviso do Caixa. Arquivo (extrato, Stone, fatura…): entra como envio da loja dita na legenda, igual ao
--    painel; quando o agente financeiro terminar de ler, a pessoa recebe o resumo e confirma no painel.
--  • De 5 em 5 minutos (cron wa-notificar): urgências novas e retorno dos arquivos enviados, e envio da fila.
-- Travas: wa.ativo = false (nada é tratado nem enviado), wa.urgencias = false. Tudo editável pela tela.
-- =============================================================================
create schema if not exists wa;

-- valor em reais no formato brasileiro (o servidor está em en_US e não tem pt_BR): 1234.5 → 1.234,50
create or replace function core.brl(v numeric) returns text language sql immutable set search_path = pg_catalog as $$
  select translate(to_char(v, 'FM999G999G990D00'), ',.', '.,')
$$;
grant execute on function core.brl(numeric) to public;

-- Tudo para resolver mostrava "R$ 1,234.50": passa a usar o formato brasileiro
do $$ declare v text;
begin
  v := pg_get_functiondef('public.painel_central(text)'::regprocedure);
  if v ~ 'to_char\([^,]*, brl\)' then
    v := regexp_replace(v, 'to_char\(([^,]*), brl\)', 'core.brl(\1)', 'g');
    execute v;
  end if;
end $$;
revoke all on schema wa from public;

insert into core.config (chave, valor) values
  ('wa.ativo', 'false'),
  ('wa.urgencias', 'false'),
  ('wa.papeis', 'admin,diretoria'),
  ('wa.modelo', 'claude-sonnet-5-5'),
  ('wa.max_respostas_hora', '60'),
  ('wa.urgencias_desde', now()::text)
on conflict (chave) do nothing;

create table if not exists wa.mensagens (
  id           bigserial primary key,
  direcao      text not null check (direcao in ('entrada', 'saida')),
  message_id   text,                                   -- id da Z-API (entrada); dedup
  principal_id uuid references core.principais(id),
  telefone     text not null check (telefone ~ '^55[0-9]{10,11}$'),
  tipo         text not null check (tipo in ('texto', 'documento', 'imagem', 'audio', 'outro')),
  origem       text not null default 'conversa' check (origem in ('conversa', 'resposta', 'urgencia', 'arquivo', 'resumo')),
  texto        text,
  arquivo_nome text,
  envio_id     uuid,
  status       text not null check (status in ('recebida', 'respondida', 'ignorada', 'erro', 'pendente', 'enviada')),
  erro         text,
  criado_em    timestamptz not null default now(),
  tratado_em   timestamptz
);
create unique index if not exists wa_mensagens_msgid on wa.mensagens (message_id) where message_id is not null;
create index if not exists wa_mensagens_fila on wa.mensagens (criado_em) where direcao = 'saida' and status = 'pendente';
create index if not exists wa_mensagens_envio on wa.mensagens (envio_id) where envio_id is not null;
alter table wa.mensagens enable row level security; alter table wa.mensagens force row level security;
do $$ begin
  revoke all on wa.mensagens from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on wa.mensagens from anon, authenticated'; end if;
end $$;

-- quem pode falar com o agente: pessoa ativa do painel, com telefone, e papel em wa.papeis
create or replace function wa.autorizado(p_telefone text) returns uuid
language sql stable security definer set search_path = core, pg_catalog as $$
  select p.id from core.principais p join core.principal_papeis pp on pp.principal_id = p.id
   where p.tipo = 'usuario' and p.ativo and p.telefone = regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g')
     and (pp.valido_ate is null or pp.valido_ate > now())
     and pp.papel_id = any(string_to_array(core.cfg('wa.papeis', 'admin,diretoria'), ','))
   limit 1
$$;

-- evento da Z-API: decide se o agente trata (só privado, de número autorizado, canal ligado) e deduplica
create or replace function wa.receber(p jsonb) returns jsonb
language plpgsql security definer set search_path = wa, core, pg_catalog as $$
declare v_tel text := regexp_replace(coalesce(p->>'phone', ''), '\D', '', 'g'); v_pid uuid; v_id bigint; v_tipo text; v_nome text;
  v_hora int;
begin
  if coalesce(p->>'type', '') <> 'ReceivedCallback' then return jsonb_build_object('acao', 'ignorar', 'motivo', 'não é mensagem recebida'); end if;
  if coalesce((p->>'isGroup')::boolean, false) or coalesce((p->>'fromMe')::boolean, false) or v_tel !~ '^55[0-9]{10,11}$' then
    return jsonb_build_object('acao', 'ignorar', 'motivo', 'grupo ou mensagem própria');
  end if;
  v_pid := wa.autorizado(v_tel);
  if v_pid is null then return jsonb_build_object('acao', 'ignorar', 'motivo', 'número não autorizado'); end if;
  if core.cfg('wa.ativo', 'false') <> 'true' then return jsonb_build_object('acao', 'ignorar', 'motivo', 'agente do WhatsApp desligado'); end if;
  if coalesce(p->>'messageId', '') = '' then return jsonb_build_object('acao', 'ignorar', 'motivo', 'sem id'); end if;
  v_tipo := case when p ? 'document' then 'documento' when p ? 'image' then 'imagem' when p ? 'audio' then 'audio'
                 when p->'text' ? 'message' then 'texto' else 'outro' end;
  v_nome := coalesce(p->'document'->>'fileName', p->'document'->>'title');
  insert into wa.mensagens (direcao, message_id, principal_id, telefone, tipo, texto, arquivo_nome, status)
  values ('entrada', p->>'messageId', v_pid, v_tel, v_tipo,
          left(coalesce(p->'text'->>'message', p->'document'->>'caption', p->'image'->>'caption'), 4000), left(v_nome, 200), 'recebida')
  on conflict (message_id) where message_id is not null do nothing
  returning id into v_id;
  if v_id is null then return jsonb_build_object('acao', 'ignorar', 'motivo', 'repetida'); end if;
  select count(*) into v_hora from wa.mensagens where direcao = 'entrada' and principal_id = v_pid and criado_em > now() - interval '1 hour';
  if v_hora > coalesce(nullif(core.cfg('wa.max_respostas_hora', '60'), '')::int, 60) then
    update wa.mensagens set status = 'ignorada', erro = 'limite por hora', tratado_em = now() where id = v_id;
    return jsonb_build_object('acao', 'ignorar', 'motivo', 'limite por hora');
  end if;
  return jsonb_build_object('acao', 'tratar', 'id', v_id, 'principal_id', v_pid, 'telefone', v_tel, 'tipo', v_tipo,
    'nome', (select nome from core.principais where id = v_pid), 'texto', coalesce(p->'text'->>'message', p->'document'->>'caption', p->'image'->>'caption'),
    'arquivo', case v_tipo when 'documento' then jsonb_build_object('url', p->'document'->>'documentUrl', 'nome', v_nome, 'mime', p->'document'->>'mimeType')
                           when 'imagem' then jsonb_build_object('url', p->'image'->>'imageUrl', 'nome', 'foto.jpg', 'mime', coalesce(p->'image'->>'mimeType', 'image/jpeg')) end,
    'historico', (select coalesce(jsonb_agg(jsonb_build_object('de', case when m.direcao = 'entrada' then 'pessoa' else 'agente' end, 'texto', left(m.texto, 1500), 'em', m.criado_em) order by m.criado_em), '[]'::jsonb)
                    from (select * from wa.mensagens m where m.telefone = v_tel and m.id <> v_id and m.texto is not null
                            and m.criado_em > now() - interval '6 hours' order by m.criado_em desc limit 10) m),
    'unidades', (select jsonb_agg(jsonb_build_object('id', id, 'nome', nome)) from core.unidades));
end $$;

-- resposta do agente (vai para a fila e é enviada pela função na mesma hora)
create or replace function wa.responder(p_entrada bigint, p_texto text, p_erro text default null) returns bigint
language plpgsql security definer set search_path = wa, core, pg_catalog as $$
declare e wa.mensagens; v_id bigint;
begin
  select * into e from wa.mensagens where id = p_entrada and direcao = 'entrada' for update;
  if not found then raise exception 'mensagem % não encontrada', p_entrada; end if;
  update wa.mensagens set status = case when p_erro is null then 'respondida' else 'erro' end, erro = left(p_erro, 300), tratado_em = now() where id = p_entrada;
  if length(btrim(coalesce(p_texto, ''))) < 1 then return null; end if;
  insert into wa.mensagens (direcao, principal_id, telefone, tipo, origem, texto, status)
  values ('saida', e.principal_id, e.telefone, 'texto', 'resposta', left(p_texto, 4000), 'pendente') returning id into v_id;
  return v_id;
end $$;

create or replace function wa.marcar_envio(p_id bigint, p_ok boolean, p_erro text default null) returns void
language sql security definer set search_path = wa, pg_catalog as $$
  update wa.mensagens set status = case when p_ok then 'enviada' else 'erro' end, erro = left(p_erro, 300), tratado_em = now()
   where id = p_id and direcao = 'saida' and status = 'pendente'
$$;

-- arquivo mandado pelo WhatsApp entra como envio da loja (mesmas regras do painel, sem login: a permissão é da pessoa)
create or replace function wa.envio_iniciar(p_entrada bigint, p_unidade text, p_nome text, p_mime text, p_tamanho int, p_sha256 text) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare e wa.mensagens; v_id uuid := gen_random_uuid(); v_ext text := fin._envio_ext(p_nome); x record;
  v_max int := coalesce(nullif(core.cfg('fin.envios.max_mb', '20'), '')::int, 20);
begin
  select * into e from wa.mensagens where id = p_entrada and direcao = 'entrada';
  if not found then raise exception 'mensagem não encontrada'; end if;
  if not exists (select 1 from core.unidades where id = p_unidade) then raise exception 'loja inválida' using errcode = '22023'; end if;
  if not painel._pode(e.principal_id, 'enviar_documento', p_unidade) then raise exception 'sem permissão para enviar arquivo desta loja' using errcode = '42501'; end if;
  if coalesce(v_ext, '') not in ('pdf','jpg','jpeg','png','webp','csv','txt','xls','xlsx','ofx') then
    raise exception 'formato não aceito: envie PDF, foto, planilha ou OFX' using errcode = '22023';
  end if;
  if p_tamanho is null or p_tamanho < 1 or p_tamanho > v_max * 1048576 then raise exception 'arquivo acima de % MB', v_max using errcode = '22023'; end if;
  if coalesce(p_sha256, '') !~ '^[0-9a-f]{64}$' then raise exception 'hash inválido' using errcode = '22023'; end if;
  select * into x from fin.envios where unidade_id = p_unidade and sha256 = p_sha256 and status not in ('descartado','erro');
  if x.id is not null then
    update wa.mensagens set envio_id = x.id where id = p_entrada;
    return jsonb_build_object('duplicado', true, 'id', x.id, 'status', x.status);
  end if;
  insert into fin.envios (id, unidade_id, conta_id, tipo_declarado, nome_arquivo, mime, tamanho, sha256, caminho, enviado_por)
  values (v_id, p_unidade, null, 'auto', left(regexp_replace(p_nome, '[/\\]', '_', 'g'), 200), left(coalesce(p_mime, 'application/octet-stream'), 100),
    p_tamanho, p_sha256, p_unidade || '/' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM') || '/' || v_id || '.' || v_ext, e.principal_id);
  update wa.mensagens set envio_id = v_id where id = p_entrada;
  perform core.auditar(e.principal_id, 'whatsapp', 'envio_iniciado', 'fin.envio', v_id::text, null,
    jsonb_build_object('unidade', p_unidade, 'nome', left(p_nome, 200), 'tamanho', p_tamanho, 'canal', 'whatsapp'));
  return jsonb_build_object('duplicado', false, 'id', v_id, 'caminho', (select caminho from fin.envios where id = v_id));
end $$;

-- o que mandar agora: urgências novas (se ligado) e retorno dos arquivos mandados pelo WhatsApp
create or replace function wa.preparar_avisos() returns int
language plpgsql security definer set search_path = wa, core, pg_catalog as $$
declare v_desde timestamptz := coalesce(nullif(core.cfg('wa.urgencias_desde', ''), '')::timestamptz, now()); v_txt text; n int := 0; r record;
begin
  if core.cfg('wa.ativo', 'false') <> 'true' then return 0; end if;

  -- retorno dos arquivos: o agente financeiro terminou de ler (para conferir) ou deu erro
  for r in select m.id, m.principal_id, m.telefone, e.nome_arquivo, e.status, e.motivo, e.unidade_id, e.checagens
             from wa.mensagens m join fin.envios e on e.id = m.envio_id
            where m.direcao = 'entrada' and e.status in ('conferir', 'erro', 'lancado')
              and not exists (select 1 from wa.mensagens s where s.direcao = 'saida' and s.origem = 'arquivo' and s.envio_id = m.envio_id) loop
    insert into wa.mensagens (direcao, principal_id, telefone, tipo, origem, texto, envio_id, status)
    values ('saida', r.principal_id, r.telefone, 'texto', 'arquivo',
      case r.status when 'erro' then format('Não consegui ler o arquivo %s: %s. Mande de novo ou suba pelo painel em Enviar arquivos.', r.nome_arquivo, coalesce(r.motivo, 'erro na leitura'))
                    when 'lancado' then format('O arquivo %s já está lançado e o caixa foi conferido de novo.', r.nome_arquivo)
                    else format('Li o arquivo %s (%s): %s linha(s). Confira e lance no painel em Enviar arquivos: https://idealize-ai-painel.vercel.app/enviar%s',
                           r.nome_arquivo, r.unidade_id, coalesce(r.checagens->>'itens', '?'),
                           coalesce(E'\nAtenção: ' || (select string_agg(a, ' ') from jsonb_array_elements_text(coalesce(r.checagens->'avisos', '[]')) a), '')) end,
      (select envio_id from wa.mensagens where id = r.id), 'pendente');
    n := n + 1;
  end loop;

  -- urgências novas desde o último aviso
  if core.cfg('wa.urgencias', 'false') = 'true' then
    with u(t, em) as (
      select '• Caixa ' || coalesce((select nome from core.unidades u where u.id = a.unidade_id), 'rede') || coalesce(' ' || to_char(a.dia, 'DD/MM'), '') || ': ' ||
             case a.tipo when 'nao_encontrado' then format('%s de R$ %s não achado no extrato', a.detalhe->>'rotulo', core.brl((a.detalhe->>'valor')::numeric))
                         when 'sem_registro_no_caixa' then format('%s de R$ %s entrou e não está no caixa', a.detalhe->>'rotulo', core.brl((a.detalhe->>'valor')::numeric))
                         when 'caixa_nao_fechado' then 'caixa não fechado'
                         when 'deposito_nao_encontrado' then format('R$ %s em dinheiro sem depósito', core.brl((a.detalhe->>'dinheiro')::numeric))
                         when 'multi_sem_caixa' then format('venda %s do Multicrediário fora do caixa', a.detalhe->>'venda')
                         when 'multi_valor_diferente' then format('venda %s: Multi R$ %s × caixa R$ %s', a.detalhe->>'venda',
                              core.brl((a.detalhe->>'valor_multi')::numeric), core.brl((a.detalhe->>'valor_caixa')::numeric))
                         else a.tipo end, a.aberto_em
        from cx.alertas a
       where a.status = 'aberto' and a.aberto_em > v_desde
         and a.tipo in ('nao_encontrado','sem_registro_no_caixa','caixa_nao_fechado','deposito_nao_encontrado','multi_sem_caixa','multi_valor_diferente')
      union all
      select '• Cobranças ' || coalesce((select nome from core.unidades u where u.id = a.unidade_id), '') || ': ' ||
             case a.tipo when 'pago_sem_baixa' then 'pago no Asaas e não baixado' when 'baixa_sem_pagamento' then 'baixado sem pagamento no Asaas'
                         else 'cobrança ativa sem parcela' end || coalesce(' (OS ' || (a.detalhe->>'os') || ')', ''), a.aberto_em
        from cob.alertas a where a.status = 'aberto' and a.aberto_em > v_desde and a.tipo in ('pago_sem_baixa','baixa_sem_pagamento','cobranca_sem_parcela')
      union all
      select '• Plataforma: ' || i.titulo, i.primeira_em from core.incidentes i where i.primeira_em > v_desde and i.severidade in ('critica','alta')
      union all
      select '• Arquivo com erro: ' || e.nome_arquivo, e.atualizado_em from fin.envios e where e.status = 'erro' and e.atualizado_em > v_desde
         and not exists (select 1 from wa.mensagens m where m.envio_id = e.id))
    select (select string_agg(t, E'\n' order by em desc) from (select * from u order by em desc limit 12) x)
           || case when (select count(*) from u) > 12 then E'\n• e mais ' || ((select count(*) from u) - 12) || ' no painel' else '' end
      into v_txt;
    update core.config set valor = now()::text, atualizado_em = now() where chave = 'wa.urgencias_desde';
    if v_txt is not null then
      insert into wa.mensagens (direcao, principal_id, telefone, tipo, origem, texto, status)
      select 'saida', p.id, p.telefone, 'texto', 'urgencia',
             E'⚠️ Urgente na Idealize AI\n' || v_txt || E'\n\nVer tudo: https://idealize-ai-painel.vercel.app/central', 'pendente'
        from core.principais p
       where p.tipo = 'usuario' and p.ativo and p.telefone ~ '^55[0-9]{10,11}$' and wa.autorizado(p.telefone) = p.id;
      get diagnostics n = row_count;
    end if;
  end if;
  return n;
end $$;

create or replace function wa.fila(p_limite int default 20) returns jsonb
language sql stable security definer set search_path = wa, pg_catalog as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'telefone', telefone, 'texto', texto) order by id), '[]'::jsonb)
    from (select * from wa.mensagens where direcao = 'saida' and status = 'pendente' order by id limit least(greatest(coalesce(p_limite, 20), 1), 100)) q
$$;

-- conversa sobre um aviso do Caixa vinda do WhatsApp: fica registrada no aviso, igual ao painel
create or replace function wa.aviso_conversar(p_entrada bigint, p_tipo text, p_ref text, p_texto_pessoa text, p_resposta text, p_explicar boolean default false)
returns jsonb language plpgsql security definer set search_path = core, pg_catalog as $$
declare e wa.mensagens; a record; v_nome text;
begin
  select * into e from wa.mensagens where id = p_entrada and direcao = 'entrada';
  if not found then raise exception 'mensagem não encontrada'; end if;
  select * into a from cx.alertas where tipo = p_tipo and referencia = p_ref order by id desc limit 1;
  if not found then raise exception 'aviso não encontrado' using errcode = 'P0002'; end if;
  if not painel._pode(e.principal_id, 'consultar', a.unidade_id) then raise exception 'sem permissão' using errcode = '42501'; end if;
  select nome into v_nome from core.principais where id = e.principal_id;
  insert into core.avisos_conversa (area, tipo, referencia, unidade_id, papel, autor_id, autor_nome, texto, acao, respondida)
  values ('caixa', p_tipo, p_ref, a.unidade_id, 'pessoa', e.principal_id, coalesce(v_nome, 'WhatsApp') || ' (WhatsApp)', left(btrim(p_texto_pessoa), 2000),
          case when p_explicar then 'explicar' else 'comentar' end, true);
  if length(btrim(coalesce(p_resposta, ''))) >= 2 then
    insert into core.avisos_conversa (area, tipo, referencia, unidade_id, papel, autor_nome, texto, acao)
    values ('caixa', p_tipo, p_ref, a.unidade_id, 'agente', 'Agente do caixa (WhatsApp)', left(btrim(p_resposta), 2000), 'responder');
  end if;
  if p_explicar and a.status = 'aberto' then
    if not painel._pode(e.principal_id, 'administrar') then raise exception 'só a diretoria marca como explicado' using errcode = '42501'; end if;
    update cx.alertas set status = 'explicado', resolvido_em = now(), resolvido_por = 'explicado por ' || coalesce(v_nome, 'WhatsApp') || ' (WhatsApp)' where id = a.id;
  end if;
  perform core.auditar(e.principal_id, 'whatsapp', case when p_explicar then 'aviso_explicar' else 'aviso_comentar' end, 'cx.alertas', a.id::text,
    jsonb_build_object('status', a.status), null, left(btrim(p_texto_pessoa), 500));
  return jsonb_build_object('ok', true, 'explicado', p_explicar and a.status = 'aberto');
end $$;

-- papel só de leitura para as perguntas (o agente monta a consulta; o banco garante que nada é alterado)
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'wa_leitura') then execute 'create role wa_leitura nologin'; end if;
end $$;
do $$ declare s text; begin
  foreach s in array array['cx', 'cob', 'multi', 'lab', 'mkt', 'rel', 'intel', 'cont', 'sup'] loop
    if exists (select 1 from pg_namespace where nspname = s) then
      execute format('grant usage on schema %I to wa_leitura', s);
      execute format('grant select on all tables in schema %I to wa_leitura', s);
    end if;
  end loop;
  execute 'grant usage on schema fin, core to wa_leitura';
  execute 'grant select on fin.movimentos, fin.contas, fin.envios, fin.pendencias, fin.lancamentos to wa_leitura';
  execute 'grant select on core.unidades, core.agentes, core.incidentes, core.avisos_conversa to wa_leitura';
  execute 'grant select (id, agente_id, tipo, operacao, unidade_id, status, motivo, criado_em, atualizado_em) on core.tarefas to wa_leitura';
  -- dado pessoal cru (CPF nas capturas do Multicrediário) fica fora; as views do Multicrediário já trazem só o necessário
  if to_regclass('multi.capturas') is not null then execute 'revoke all on multi.capturas from wa_leitura'; end if;
exception when undefined_table then null;
end $$;
do $$ begin
  -- o papel de conexão das funções (postgres) precisa poder assumir wa_leitura
  execute 'grant wa_leitura to postgres';
exception when others then null;
end $$;

-- tela: ligar/desligar e ver as últimas mensagens (diretoria)
create or replace function public.painel_whatsapp() returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid;
begin
  v_eu := painel._entrar('whatsapp');
  perform painel._exigir(v_eu, 'administrar');
  return jsonb_build_object(
    'ativo', core.cfg('wa.ativo', 'false') = 'true', 'urgencias', core.cfg('wa.urgencias', 'false') = 'true',
    'resumos', core.cfg('sup.enviar', 'false') = 'true', 'horarios_resumo', core.cfg('sup.horarios_resumo', '7,12,18'),
    'papeis', core.cfg('wa.papeis', 'admin,diretoria'),
    'autorizados', (select coalesce(jsonb_agg(jsonb_build_object('nome', p.nome, 'final', right(p.telefone, 4))), '[]'::jsonb)
                      from core.principais p where p.tipo = 'usuario' and p.ativo and p.telefone ~ '^55[0-9]{10,11}$' and wa.autorizado(p.telefone) = p.id),
    'mensagens', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'direcao', m.direcao, 'tipo', m.tipo, 'origem', m.origem, 'texto', left(m.texto, 500),
                    'arquivo', m.arquivo_nome, 'status', m.status, 'erro', m.erro, 'em', m.criado_em, 'final', right(m.telefone, 4)) order by m.id desc), '[]'::jsonb)
                    from (select * from wa.mensagens order by id desc limit 50) m));
end $$;

create or replace function public.painel_whatsapp_salvar(p_ativo boolean, p_urgencias boolean, p_resumos boolean, p_motivo text default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_antes jsonb;
begin
  v_eu := painel._entrar('whatsapp_salvar');
  perform painel._exigir(v_eu, 'administrar');
  v_antes := jsonb_build_object('ativo', core.cfg('wa.ativo', 'false'), 'urgencias', core.cfg('wa.urgencias', 'false'), 'resumos', core.cfg('sup.enviar', 'false'));
  insert into core.config (chave, valor) values ('wa.ativo', coalesce(p_ativo, false)::text), ('wa.urgencias', coalesce(p_urgencias, false)::text),
    ('sup.enviar', coalesce(p_resumos, false)::text)
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  if coalesce(p_urgencias, false) and v_antes->>'urgencias' <> 'true' then
    update core.config set valor = now()::text, atualizado_em = now() where chave = 'wa.urgencias_desde';  -- só o que surgir daqui para frente
  end if;
  perform core.auditar(v_eu, null, 'whatsapp_ajustado', 'core.config', 'wa', v_antes,
    jsonb_build_object('ativo', p_ativo, 'urgencias', p_urgencias, 'resumos', p_resumos), nullif(btrim(coalesce(p_motivo, '')), ''));
  return public.painel_whatsapp();
end $$;

do $$ declare f text; begin
  foreach f in array array['wa.autorizado(text)', 'wa.receber(jsonb)', 'wa.responder(bigint,text,text)', 'wa.marcar_envio(bigint,boolean,text)',
     'wa.envio_iniciar(bigint,text,text,text,int,text)', 'wa.preparar_avisos()', 'wa.fila(int)', 'wa.aviso_conversar(bigint,text,text,text,text,boolean)',
     'public.painel_whatsapp()', 'public.painel_whatsapp_salvar(boolean,boolean,boolean,text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon, authenticated', f); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.painel_whatsapp() to authenticated';
    execute 'grant execute on function public.painel_whatsapp_salvar(boolean,boolean,boolean,text) to authenticated';
  end if;
end $$;

-- de 5 em 5 minutos: urgências, retorno dos arquivos e envio da fila (a função não faz nada com wa.ativo = false)
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'wa-notificar') then
      perform cron.schedule('wa-notificar', '*/5 * * * *', $c$select core.chamar_agente('agente-whatsapp','sup_worker_secret',60000)$c$);
    end if;
  end if;
end $$;
