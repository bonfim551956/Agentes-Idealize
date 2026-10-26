-- =============================================================================
-- Idealize AI — Etapa G: canal WhatsApp do agente financeiro (v0.4.0) — NASCE DESLIGADO
--
-- Três travas, todas fechadas na instalação:
--   1. core.config fin.whatsapp.ativo = false  → webhook responde "desligado" e não grava nada
--   2. core.agentes 'financeiro' = pausado     → tarefas nascem bloqueadas e o worker não reivindica
--   3. sem agendamento do worker (pg_cron)     → nada processa sozinho
-- Modo sombra: fin.whatsapp.responder = false → o robô nunca escreve no WhatsApp.
--
-- Fluxo: webhook → fin.receber_whatsapp (valida grupo, remetente e permissão; deduplica; cria
-- tarefa no core) → worker reivindica → baixa mídia (allowlist, limite, tipo real pelos bytes) →
-- Claude extrai → fin.aplicar_extracao (regras determinísticas, na mesma transação que o resultado
-- da execução) → fin.validar_registro_whatsapp (validador independente, outro executor).
-- Escopo desta fase: comprovantes, boletos e documentos fiscais em imagem/PDF.
-- Texto puro e áudio ficam registrados como fora de escopo (o Finance AI atual segue cuidando deles).
-- =============================================================================

insert into core.config (chave, valor) values
  ('fin.whatsapp.ativo', 'false'),
  ('fin.whatsapp.responder', 'false'),
  ('fin.whatsapp.modelo', 'claude-sonnet-5-5'),
  ('fin.whatsapp.max_midia_mb', '16'),
  ('fin.whatsapp.midia_hosts', 'z-api.io,backblazeb2.com,whatsapp.net,amazonaws.com,storage.googleapis.com'),
  ('fin.whatsapp.confianca_minima', '0.8')
on conflict (chave) do nothing;

alter table fin.pendencias drop constraint pendencias_tipo_check;
alter table fin.pendencias add constraint pendencias_tipo_check check (tipo in (
  'divergencia','ambiguidade','sem_classificacao','sem_comprovante','duplicidade_suspeita','rateio_desbalanceado',
  'transferencia_sem_par','fatura_divergente','saldo_divergente','comprovante_sem_pagamento','revisao_extracao'));

create table fin.grupos_whatsapp (
  chat_id    text primary key check (chat_id ~ '^[0-9]{10,25}-group$'),
  unidade_id text not null references core.unidades(id),
  nome       text,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

create table fin.whatsapp_mensagens (
  id                  uuid primary key default gen_random_uuid(),
  provider            text not null default 'zapi',
  provider_message_id text not null,
  chat_id             text not null,
  unidade_id          text not null references core.unidades(id),
  principal_id        uuid not null references core.principais(id),
  tipo                text not null check (tipo in ('texto','imagem','documento','audio','outro')),
  texto               text,
  media_url           text,
  media_mime          text,
  media_nome          text,
  payload             jsonb not null,
  status              text not null default 'recebida'
                      check (status in ('recebida','tarefa','fora_de_escopo','registrada','sem_registro','erro')),
  motivo              text,
  tarefa_id           uuid references core.tarefas(id),
  recebido_em         timestamptz not null default now(),
  unique (provider, provider_message_id)
);
create index whatsapp_mensagens_tarefa on fin.whatsapp_mensagens (tarefa_id) where tarefa_id is not null;

alter table fin.documentos add column mensagem_id uuid references fin.whatsapp_mensagens(id);
alter table fin.documentos add column tarefa_id uuid references core.tarefas(id);
create index documentos_tarefa on fin.documentos (tarefa_id) where tarefa_id is not null;

-- ---------------------------------------------------------------------------
-- Telefone BR com e sem o 9º dígito (contas antigas chegam sem ele) — mesma regra do Finance AI
-- ---------------------------------------------------------------------------
create or replace function fin.tel_variantes(p text) returns text[]
language plpgsql immutable set search_path = pg_catalog as $$
declare t text := regexp_replace(coalesce(p,''), '\D', '', 'g');
begin
  if length(t) in (10, 11) then t := '55' || t; end if;
  if t like '55%' and length(t) = 13 and substr(t, 5, 1) = '9' then return array[t, substr(t,1,4) || substr(t,6)]; end if;
  if t like '55%' and length(t) = 12 and substr(t, 5, 1) in ('6','7','8','9') then return array[substr(t,1,4) || '9' || substr(t,5), t]; end if;
  return array[t];
end $$;

-- ---------------------------------------------------------------------------
-- Entrada: só grava se o canal estiver ligado; só grupos cadastrados; só pessoas com permissão na unidade
-- ---------------------------------------------------------------------------
create or replace function fin.receber_whatsapp(p jsonb) returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare v_msg text; v_chat text; v_tel text; v_un text; v_pr uuid; v_tipo text; v_texto text; v_url text; v_mime text; v_nome text;
  v_id uuid; v_tar uuid; v_status text;
begin
  if core.cfg('fin.whatsapp.ativo', 'false') <> 'true' then
    return jsonb_build_object('status', 'desligado');
  end if;
  if coalesce(p->>'type','') <> 'ReceivedCallback' then return jsonb_build_object('ignorado','tipo'); end if;
  if coalesce((p->>'fromMe')::boolean, false) or coalesce((p->>'broadcast')::boolean, false)
     or coalesce((p->>'isNewsletter')::boolean, false) or coalesce((p->>'isStatusReply')::boolean, false)
     or coalesce((p->>'isEdit')::boolean, false) then
    return jsonb_build_object('ignorado','origem');
  end if;
  v_msg := nullif(p->>'messageId','');
  if v_msg is null or length(v_msg) > 128 then return jsonb_build_object('ignorado','sem id'); end if;
  if not coalesce((p->>'isGroup')::boolean, false) then return jsonb_build_object('ignorado','somente grupo'); end if;

  v_chat := p->>'phone';
  select unidade_id into v_un from fin.grupos_whatsapp where chat_id = v_chat and ativo;
  if v_un is null then return jsonb_build_object('ignorado','grupo nao autorizado'); end if;

  v_tel := regexp_replace(coalesce(p->>'participantPhone',''), '\D', '', 'g');
  select id into v_pr from core.principais
   where tipo = 'usuario' and ativo and telefone = any(fin.tel_variantes(v_tel)) limit 1;
  if v_pr is null then return jsonb_build_object('ignorado','remetente nao cadastrado'); end if;
  -- regra do Diego: o que é enviado num grupo só pode ser registrado na unidade daquele grupo
  if not exists (select 1 from core.principal_papeis pp where pp.principal_id = v_pr
                  and pp.papel_id in ('admin','diretoria','financeiro','gerente')
                  and (pp.unidade_id is null or pp.unidade_id = v_un)
                  and (pp.valido_ate is null or pp.valido_ate > now())) then
    return jsonb_build_object('ignorado','sem permissao na unidade');
  end if;

  if p->'image'->>'imageUrl' is not null then
    v_tipo := 'imagem'; v_url := p->'image'->>'imageUrl'; v_mime := p->'image'->>'mimeType'; v_texto := p->'image'->>'caption';
  elsif p->'document'->>'documentUrl' is not null then
    v_tipo := 'documento'; v_url := p->'document'->>'documentUrl'; v_mime := p->'document'->>'mimeType';
    v_texto := p->'document'->>'caption'; v_nome := coalesce(p->'document'->>'fileName', p->'document'->>'title');
  elsif p->'audio'->>'audioUrl' is not null then
    v_tipo := 'audio'; v_url := p->'audio'->>'audioUrl'; v_mime := p->'audio'->>'mimeType';
  elsif p->'text'->>'message' is not null then
    v_tipo := 'texto'; v_texto := p->'text'->>'message';
  else
    v_tipo := 'outro';
  end if;

  insert into fin.whatsapp_mensagens (provider_message_id, chat_id, unidade_id, principal_id, tipo, texto, media_url, media_mime,
    media_nome, payload, status, motivo)
  values (v_msg, v_chat, v_un, v_pr, v_tipo, left(v_texto, 4000), left(v_url, 2000), left(v_mime, 100), left(v_nome, 255), p,
    case when v_tipo in ('imagem','documento') then 'recebida' else 'fora_de_escopo' end,
    case when v_tipo in ('imagem','documento') then null else 'texto/áudio seguem com o Finance AI nesta fase' end)
  on conflict (provider, provider_message_id) do nothing
  returning id into v_id;
  if v_id is null then return jsonb_build_object('ok', true, 'duplicado', true); end if;
  if v_tipo not in ('imagem','documento') then return jsonb_build_object('ok', true, 'fora_de_escopo', v_tipo); end if;

  v_tar := core.criar_tarefa(v_pr, 'financeiro', 'whatsapp_comprovante', 'fin.lancamento', 'registrar_comprovante', v_un,
    jsonb_build_object('mensagem_id', v_id), 'whatsapp:zapi:' || v_msg);
  select status into v_status from core.tarefas where id = v_tar;
  update fin.whatsapp_mensagens set tarefa_id = v_tar, status = 'tarefa' where id = v_id;
  return jsonb_build_object('ok', true, 'mensagem', v_id, 'tarefa', v_tar, 'tarefa_status', v_status);
end $$;

-- contexto que o worker precisa (só leitura)
create or replace function fin.contexto_tarefa_whatsapp(p_tarefa uuid) returns jsonb
language sql stable security definer set search_path = fin, core, pg_catalog as $$
  select jsonb_build_object(
    'tarefa', jsonb_build_object('id', t.id, 'status', t.status, 'executor', t.executor, 'unidade', t.unidade_id),
    'mensagem', jsonb_build_object('id', m.id, 'tipo', m.tipo, 'texto', m.texto, 'url', m.media_url, 'mime', m.media_mime,
                                   'nome', m.media_nome, 'recebido_em', m.recebido_em),
    'unidade', (select nome from core.unidades where id = t.unidade_id),
    'hoje', (now() at time zone 'America/Sao_Paulo')::date,
    'config', jsonb_build_object('modelo', core.cfg('fin.whatsapp.modelo','claude-sonnet-5-5'),
                                 'max_midia_mb', core.cfg('fin.whatsapp.max_midia_mb','16'),
                                 'midia_hosts', core.cfg('fin.whatsapp.midia_hosts',''),
                                 'responder', core.cfg('fin.whatsapp.responder','false')))
  from core.tarefas t join fin.whatsapp_mensagens m on m.id = (t.payload->>'mensagem_id')::uuid
  where t.id = p_tarefa;
$$;

-- categoria sugerida pelas regras do Diego (por CPF/CNPJ ou nome do favorecido)
create or replace function fin.categoria_por_regra(p_doc text, p_nome text, p_sentido text, p_data date) returns text
language sql stable security definer set search_path = fin, pg_catalog as $$
  select categoria_id from fin.regras_classificacao r
   where r.status = 'ativa' and r.natureza in ('receita','despesa') and r.sentido = p_sentido
     and ((p_doc is not null and length(p_doc) >= 8 and p_doc like '%' || r.padrao || '%' and r.padrao ~ '^[0-9]{8,14}$')
          or (p_nome is not null and r.padrao !~ '^[0-9]+$' and length(r.padrao) >= 4 and p_nome ilike '%' || r.padrao || '%'))
     and (r.ultimos_dias_uteis is null or fin.no_fim_do_mes(p_data, r.ultimos_dias_uteis))
   order by r.prioridade, r.id limit 1
$$;

-- encerra a tarefa sem registro (arquivo inválido, não financeiro, host não permitido...)
create or replace function fin.encerrar_sem_registro(p_tarefa uuid, p_executor text, p_motivo text) returns text
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare r text;
begin
  update fin.whatsapp_mensagens set status = 'sem_registro', motivo = left(p_motivo, 500) where tarefa_id = p_tarefa;
  r := core.registrar_execucao(p_tarefa, p_executor, 'sucesso', null, jsonb_build_object('sem_registro', left(p_motivo, 500)));
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- Aplica a extração da IA com regras determinísticas. A IA só descreve o documento;
-- quem decide o que vira lançamento é esta função. Unidade = a do grupo, sempre.
-- p_doc:      {sha256, storage_path, mime, tamanho}
-- p_extracao: {tipo_documento, itens:[{valor, data, vencimento?, favorecido, favorecido_doc, id_transacao,
--               descricao, confianca:{valor,data}}], texto_usuario:{valor, data, descricao}}
-- ---------------------------------------------------------------------------
create or replace function fin.aplicar_extracao(p_tarefa uuid, p_executor text, p_doc jsonb, p_extracao jsonb) returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare t record; m record; v_doc uuid; v_tipo text; it jsonb; v_val numeric; v_data date; v_venc date; v_l uuid;
  v_lancs uuid[] := '{}'; v_prev uuid[] := '{}'; v_pend int := 0; v_min numeric; v_docnum text; v_cat text;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_res jsonb; v_tu jsonb;
begin
  select * into t from core.tarefas where id = p_tarefa for update;
  if t.status <> 'executando' or t.executor is distinct from p_executor then
    raise exception 'tarefa não está em execução por este executor (status=%)', t.status;
  end if;
  select * into m from fin.whatsapp_mensagens where id = (t.payload->>'mensagem_id')::uuid;
  v_tipo := p_extracao->>'tipo_documento';
  if v_tipo not in ('comprovante_pagamento','documento_fiscal','boleto','outro') then
    raise exception 'tipo_documento inválido: %', v_tipo;
  end if;
  if (p_doc->>'sha256') !~ '^[0-9a-f]{64}$' or coalesce(p_doc->>'storage_path','') = '' then
    raise exception 'documento sem hash/caminho válido';
  end if;
  if jsonb_typeof(coalesce(p_extracao->'itens','[]')) <> 'array' or jsonb_array_length(coalesce(p_extracao->'itens','[]')) > 200 then
    raise exception 'itens inválidos';
  end if;
  v_min := core.cfg('fin.whatsapp.confianca_minima','0.8')::numeric;
  v_tu := coalesce(p_extracao->'texto_usuario', '{}'::jsonb);

  -- mesmo arquivo já recebido nesta unidade: não lança de novo
  select id into v_doc from fin.documentos where sha256 = p_doc->>'sha256' and unidade_id = t.unidade_id;
  if v_doc is not null then
    update fin.whatsapp_mensagens set status = 'sem_registro', motivo = 'arquivo idêntico já recebido' where id = m.id;
    return jsonb_build_object('arquivo_ja_recebido', v_doc, 'lancamentos', '[]'::jsonb);
  end if;

  insert into fin.documentos (tipo, sha256, storage_path, mime, origem, unidade_id, enviado_por, extraido, confianca, status,
    mensagem_id, tarefa_id)
  values (case v_tipo when 'outro' then 'outro' else v_tipo end, p_doc->>'sha256', p_doc->>'storage_path', p_doc->>'mime',
    'whatsapp', t.unidade_id, m.principal_id, p_extracao,
    (select jsonb_agg(i->'confianca') from jsonb_array_elements(coalesce(p_extracao->'itens','[]')) i),
    case v_tipo when 'outro' then 'rejeitado' when 'documento_fiscal' then 'revisao' else 'extraido' end, m.id, p_tarefa)
  returning id into v_doc;

  if v_tipo in ('comprovante_pagamento','boleto') then
    for it in select * from jsonb_array_elements(coalesce(p_extracao->'itens','[]')) loop
      begin
        v_val := round((it->>'valor')::numeric, 2);
        v_data := (it->>'data')::date;
        v_venc := nullif(it->>'vencimento','')::date;
      exception when others then
        raise exception 'item com valor/data ilegível: %', left(it::text, 200);
      end;
      if v_val is null or v_val <= 0 or v_val > 10000000 then raise exception 'valor fora do intervalo: %', v_val; end if;
      if v_tipo = 'comprovante_pagamento' and (v_data is null or v_data > v_hoje + 1 or v_data < v_hoje - 400) then
        raise exception 'data do pagamento fora do intervalo: %', v_data;
      end if;
      v_docnum := fin.so_digitos(it->>'favorecido_doc');
      if v_docnum is not null and length(v_docnum) not in (11, 14) then v_docnum := null; end if;
      v_cat := fin.categoria_por_regra(v_docnum, it->>'favorecido', 'debito', coalesce(v_data, v_venc));

      if v_tipo = 'comprovante_pagamento' then
        v_l := fin.registrar_lancamento('despesa','saida', v_val, t.unidade_id, v_data, 'agente_financeiro', 'whatsapp', null,
          v_cat, left(it->>'favorecido', 200), v_docnum, left(coalesce(it->>'descricao', v_tu->>'descricao'), 300), v_data,
          'pendente', left(nullif(it->>'id_transacao',''), 100), v_doc);
        v_lancs := v_lancs || v_l;
      else
        -- boleto ainda não pago = conta a pagar (previsto); vira realizado só pelo extrato
        if v_venc is null and v_data is null then raise exception 'boleto sem vencimento'; end if;
        v_l := fin.registrar_lancamento('despesa','saida', v_val, t.unidade_id, coalesce(v_venc, v_data), 'agente_financeiro',
          'whatsapp', null, v_cat, left(it->>'favorecido', 200), v_docnum, left(coalesce(it->>'descricao', 'Boleto'), 300),
          coalesce(v_venc, v_data), 'previsto', left(nullif(it->>'id_transacao',''), 100), v_doc);
        v_prev := v_prev || v_l;
      end if;
      -- leitura duvidosa → revisão humana (o lançamento existe, mas não é tratado como certo)
      if coalesce((it->'confianca'->>'valor')::numeric, 0) < v_min or coalesce((it->'confianca'->>'data')::numeric, 0) < v_min then
        perform fin.abrir_pendencia('revisao_extracao', t.unidade_id, null, v_l,
          jsonb_build_object('confianca', it->'confianca', 'documento', v_doc));
        v_pend := v_pend + 1;
      end if;
      if v_cat is null then
        perform fin.abrir_pendencia('sem_classificacao', t.unidade_id, null, v_l, jsonb_build_object('favorecido', left(it->>'favorecido',200)), false);
      end if;
    end loop;
    -- o que o usuário escreveu diverge do documento? as duas versões ficam; a pessoa decide
    if jsonb_array_length(coalesce(p_extracao->'itens','[]')) = 1 and nullif(v_tu->>'valor','') is not null
       and round((v_tu->>'valor')::numeric, 2) <> v_val then
      perform fin.abrir_pendencia('divergencia', t.unidade_id, null, v_l,
        jsonb_build_object('valor_documento', v_val, 'valor_informado', round((v_tu->>'valor')::numeric, 2), 'prova', 'texto_usuario'));
      v_pend := v_pend + 1;
    end if;
  end if;

  update fin.whatsapp_mensagens set status = case when v_tipo = 'outro' then 'sem_registro' else 'registrada' end,
    motivo = case v_tipo when 'outro' then 'não é documento financeiro' when 'documento_fiscal' then 'documento fiscal não é saída de caixa: só arquivado' end
   where id = m.id;
  v_res := jsonb_build_object('documento', v_doc, 'tipo', v_tipo, 'lancamentos', to_jsonb(v_lancs), 'previstos', to_jsonb(v_prev),
                              'pendencias', v_pend);
  return v_res;
end $$;

-- execução + resultado na MESMA transação: ou os dois acontecem, ou nenhum
create or replace function fin.concluir_extracao(p_tarefa uuid, p_executor text, p_doc jsonb, p_extracao jsonb) returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare v jsonb;
begin
  v := fin.aplicar_extracao(p_tarefa, p_executor, p_doc, p_extracao);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', p_doc->>'sha256', v);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Validador independente: não usa o resumo do worker. Relê o documento guardado e os lançamentos
-- ligados a ele e confere as regras. Executor ≠ validador (o core recusa o mesmo nome).
-- ---------------------------------------------------------------------------
create or replace function fin.validar_registro_whatsapp(p_tarefa uuid, p_validador text) returns text
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare t record; d record; v_erros text[] := '{}'; v_itens int; v_lancs int; it jsonb; v_ok int;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  select * into d from fin.documentos where tarefa_id = p_tarefa;

  if t.resultado ? 'sem_registro' or t.resultado ? 'arquivo_ja_recebido' then
    if exists (select 1 from fin.lancamento_documentos ld join fin.documentos dd on dd.id = ld.documento_id where dd.tarefa_id = p_tarefa) then
      v_erros := v_erros || 'tarefa sem registro, mas há lançamento ligado';
    end if;
  else
    if d is null then v_erros := v_erros || 'documento da tarefa não encontrado'; end if;
    if d.sha256 !~ '^[0-9a-f]{64}$' or coalesce(d.storage_path,'') = '' then v_erros := v_erros || 'documento sem hash/caminho'; end if;
    if d.unidade_id is distinct from t.unidade_id then v_erros := v_erros || 'documento fora da unidade do grupo'; end if;
    select count(*) into v_lancs from fin.lancamento_documentos ld join fin.lancamentos l on l.id = ld.lancamento_id
     where ld.documento_id = d.id;
    v_itens := jsonb_array_length(coalesce(d.extraido->'itens','[]'));
    if d.tipo in ('documento_fiscal','outro') and v_lancs > 0 then
      v_erros := v_erros || 'documento fiscal/outro não pode gerar lançamento';
    end if;
    if d.tipo in ('comprovante_pagamento','boleto') then
      if v_lancs <> v_itens then v_erros := v_erros || format('itens (%s) ≠ lançamentos (%s)', v_itens, v_lancs); end if;
      for it in select * from jsonb_array_elements(coalesce(d.extraido->'itens','[]')) loop
        select count(*) into v_ok from fin.lancamento_documentos ld join fin.lancamentos l on l.id = ld.lancamento_id
         where ld.documento_id = d.id and l.valor = round((it->>'valor')::numeric, 2)
           and l.unidade_id = t.unidade_id and l.sentido = 'saida' and l.origem = 'whatsapp'
           and l.status in (case d.tipo when 'boleto' then 'previsto' else 'pendente' end, 'conciliado', 'contestado')
           and (d.tipo = 'boleto' or l.data_competencia = (it->>'data')::date);
        if v_ok = 0 then v_erros := v_erros || format('item %s sem lançamento correspondente', it->>'valor'); end if;
      end loop;
      if exists (select 1 from fin.lancamento_documentos ld join fin.lancamentos l on l.id = ld.lancamento_id
                  where ld.documento_id = d.id and l.status in ('confirmado')) then
        v_erros := v_erros || 'comprovante não pode nascer confirmado (só o extrato confirma)';
      end if;
    end if;
  end if;

  if array_length(v_erros, 1) is null then
    return core.registrar_validacao(p_tarefa, p_validador, true, null, jsonb_build_object('documento', d.id));
  end if;
  return core.registrar_validacao(p_tarefa, p_validador, false, array_to_string(v_erros, '; '),
    jsonb_build_object('documento', d.id, 'erros', to_jsonb(v_erros)));
end $$;

-- ---------------------------------------------------------------------------
-- Endurecimento (mesmo padrão)
-- ---------------------------------------------------------------------------
alter table fin.grupos_whatsapp enable row level security;   alter table fin.grupos_whatsapp force row level security;
alter table fin.whatsapp_mensagens enable row level security; alter table fin.whatsapp_mensagens force row level security;
revoke all on fin.grupos_whatsapp, fin.whatsapp_mensagens from public;
do $$ declare f text; begin
  foreach f in array array['fin.tel_variantes(text)','fin.receber_whatsapp(jsonb)','fin.contexto_tarefa_whatsapp(uuid)',
    'fin.categoria_por_regra(text,text,text,date)','fin.encerrar_sem_registro(uuid,text,text)',
    'fin.aplicar_extracao(uuid,text,jsonb,jsonb)','fin.concluir_extracao(uuid,text,jsonb,jsonb)',
    'fin.validar_registro_whatsapp(uuid,text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon, authenticated', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('grant execute on function %s to service_role', f); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on fin.grupos_whatsapp, fin.whatsapp_mensagens from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select on fin.grupos_whatsapp, fin.whatsapp_mensagens to service_role';
  end if;
end $$;

-- bucket privado para os comprovantes (só no Supabase; o banco de testes local não tem storage)
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('fin-documentos', 'fin-documentos', false, 16777216,
            array['image/jpeg','image/png','image/webp','application/pdf'])
    on conflict (id) do nothing;
  end if;
end $$;

insert into core.integracoes (id, nome, status, observacoes) values
  ('zapi_fin_novo','Z-API → canal WhatsApp do agente financeiro (novo)','nao_verificada','Instalado desligado; sem webhook apontado')
on conflict (id) do nothing;
