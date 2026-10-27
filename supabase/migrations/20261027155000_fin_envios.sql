-- =============================================================================
-- Idealize AI — Central de envio de arquivos (v0.1.0)  · Migração 20261027155000
--
-- O financeiro (ou o Diego) envia pelo painel: extrato do banco (OFX ou PDF), fatura do cartão (PDF/CSV),
-- relatório da Stone (CSV/planilha/PDF), comprovante, boleto ou nota (PDF/imagem).
-- Regras à prova de erro:
--   • arquivo idêntico (mesmo hash) na mesma loja não entra duas vezes;
--   • só OFX de extrato com a conta reconhecida é lançado sozinho (formato do banco, sem interpretação);
--   • tudo que a IA leu (PDF, imagem, planilha) fica "para conferir": o sistema mostra as linhas e as contas de
--     fechamento (saldo inicial + movimentos = saldo final; soma das compras = total da fatura) e só lança
--     quando uma PESSOA confirma; não fechou, avisa;
--   • o validador independente refaz as contas e confere que nada foi lançado sem a regra acima.
-- A leitura nasce DESLIGADA (fin.envios.ativo = false): o arquivo é guardado e fica "na fila" até o "PODE LIGAR".
-- Arquivos esperados (extrato diário, Stone semanal, fatura mensal): o Supervisor cobra o que não chegou.
-- =============================================================================

create table fin.envios (
  id             uuid primary key default gen_random_uuid(),
  unidade_id     text not null references core.unidades(id),
  conta_id       text references fin.contas(id),
  tipo_declarado text not null check (tipo_declarado in ('auto','extrato','fatura','stone','comprovante','boleto','nota')),
  tipo           text check (tipo in ('extrato','fatura','stone','comprovante','boleto','nota','outro')),
  nome_arquivo   text not null check (length(nome_arquivo) between 1 and 200),
  mime           text not null,
  tamanho        int not null check (tamanho between 1 and 20971520),
  sha256         text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  caminho        text not null,
  enviado_por    uuid not null references core.principais(id),
  status         text not null default 'aguardando_arquivo'
                 check (status in ('aguardando_arquivo','recebido','lendo','conferir','lancado','descartado','erro')),
  formato        text check (formato in ('ofx','ia')),
  leitura        jsonb,
  checagens      jsonb,
  resultado      jsonb,
  tarefa_id      uuid references core.tarefas(id),
  decidido_por   uuid references core.principais(id),
  decidido_em    timestamptz,
  motivo         text,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
-- o mesmo arquivo não entra duas vezes na mesma loja (reenviar só depois de descartado ou com erro)
create unique index fin_envios_unico on fin.envios (unidade_id, sha256) where status not in ('descartado','erro');
create index fin_envios_status on fin.envios (status, criado_em);
create index fin_envios_unidade on fin.envios (unidade_id, criado_em desc);
create index fin_envios_tarefa on fin.envios (tarefa_id);
create index fin_envios_conta on fin.envios (conta_id);
create index fin_envios_enviado on fin.envios (enviado_por);
create index fin_envios_decidido on fin.envios (decidido_por);

-- O que precisa chegar e quando (o Supervisor cobra). Nasce sem nenhum: o Diego diz quais contas/lojas.
create table fin.arquivos_esperados (
  id          bigint generated always as identity primary key,
  unidade_id  text not null references core.unidades(id),
  tipo        text not null check (tipo in ('extrato','fatura','stone')),
  conta_id    text references fin.contas(id),
  frequencia  text not null check (frequencia in ('diaria','semanal','mensal')),
  dia_limite  int,          -- semanal: dia da semana (1 = segunda); mensal: dia do mês
  hora_limite int not null default 10 check (hora_limite between 0 and 23),
  dias        text not null default '1,2,3,4,5',   -- diária: dias da semana em que o extrato do dia anterior é esperado
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now(),
  check (frequencia = 'diaria' or dia_limite is not null),
  check (frequencia <> 'semanal' or dia_limite between 1 and 7),
  check (frequencia <> 'mensal' or dia_limite between 1 and 28)
);
create index fin_arquivos_esperados_unidade on fin.arquivos_esperados (unidade_id);
create index fin_arquivos_esperados_conta on fin.arquivos_esperados (conta_id);

-- extrato lido pela IA (PDF/imagem) e confirmado por pessoa entra como importação de formato 'ia'
alter table fin.importacoes drop constraint if exists importacoes_formato_check;
alter table fin.importacoes add constraint importacoes_formato_check check (formato in ('ofx','csv','json','manual','ia'));

insert into core.config (chave, valor) values
  ('fin.envios.ativo', 'false'),
  ('fin.envios.max_mb', '20'),
  ('fin.envios.tolerancia', '0.05'),
  ('versao_envios', '0.1.0')
on conflict (chave) do nothing;

-- quem pode enviar e confirmar pelo painel
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select v.papel, 'painel', v.op, v.risco, 'automatica'
from (values ('admin','enviar_documento','medio'), ('diretoria','enviar_documento','medio'), ('financeiro','enviar_documento','medio'),
             ('admin','confirmar_documento','alto'), ('diretoria','confirmar_documento','alto'), ('financeiro','confirmar_documento','alto')) v(papel, op, risco)
where exists (select 1 from core.papeis where id = v.papel)
  and not exists (select 1 from core.politicas p where p.papel_id = v.papel and p.recurso = 'painel' and p.operacao = v.op and p.ativo);
-- o agente lê; lançar o que a IA leu sem pessoa confirmar é proibido
insert into core.politicas (papel_id, recurso, operacao, risco, categoria)
select 'agente_financeiro', 'fin.envio', v.op, v.risco, v.cat
from (values ('ler','baixo','automatica'), ('lancar_sem_confirmacao','alto','proibida'), ('excluir_arquivo','alto','proibida')) v(op, risco, cat)
where exists (select 1 from core.papeis where id = 'agente_financeiro')
  and not exists (select 1 from core.politicas p where p.papel_id = 'agente_financeiro' and p.recurso = 'fin.envio' and p.operacao = v.op and p.ativo);

-- bucket privado dos arquivos enviados (só no Supabase; o banco de testes local não tem storage)
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit)
    values ('fin-envios', 'fin-envios', false, 20971520) on conflict (id) do nothing;
  end if;
end $$;

create or replace function fin._envio_ext(p_nome text) returns text
language sql immutable set search_path = pg_catalog as $$
  select lower(substring(p_nome from '\.([A-Za-z0-9]{2,5})$'))
$$;

-- ---------------------------------------------------------------------------
-- 1. Painel: pedir o envio (a função de recebimento chama como o próprio usuário, com o login e o 2FA dele)
-- ---------------------------------------------------------------------------
create or replace function public.painel_envio_iniciar(p_unidade text, p_tipo text, p_conta text, p_nome text, p_mime text,
  p_tamanho int, p_sha256 text) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; v_id uuid := gen_random_uuid(); v_ext text := fin._envio_ext(p_nome); e record;
  v_max int := coalesce(nullif(core.cfg('fin.envios.max_mb', '20'), '')::int, 20);
begin
  v_eu := painel._entrar('envio_iniciar', p_unidade);
  perform painel._exigir(v_eu, 'enviar_documento', p_unidade);
  if p_tipo not in ('auto','extrato','fatura','stone','comprovante','boleto','nota') then raise exception 'tipo de arquivo inválido' using errcode = '22023'; end if;
  if coalesce(v_ext, '') not in ('pdf','jpg','jpeg','png','webp','csv','txt','xls','xlsx','ofx') then
    raise exception 'formato não aceito: envie PDF, foto (JPG/PNG), planilha (CSV/XLS/XLSX) ou OFX' using errcode = '22023';
  end if;
  if p_tamanho is null or p_tamanho < 1 or p_tamanho > v_max * 1048576 then
    raise exception 'arquivo acima de % MB', v_max using errcode = '22023';
  end if;
  if coalesce(p_sha256, '') !~ '^[0-9a-f]{64}$' then raise exception 'hash inválido' using errcode = '22023'; end if;
  if p_conta is not null and not exists (select 1 from fin.contas where id = p_conta and unidade_id = p_unidade and ativo) then
    raise exception 'conta não é desta loja' using errcode = '22023';
  end if;
  select * into e from fin.envios where unidade_id = p_unidade and sha256 = p_sha256 and status not in ('descartado','erro');
  if e.id is not null then
    return jsonb_build_object('duplicado', true, 'id', e.id, 'status', e.status, 'enviado_em', e.criado_em);
  end if;
  insert into fin.envios (id, unidade_id, conta_id, tipo_declarado, nome_arquivo, mime, tamanho, sha256, caminho, enviado_por)
  values (v_id, p_unidade, p_conta, p_tipo, left(regexp_replace(p_nome, '[/\\]', '_', 'g'), 200), left(coalesce(p_mime, 'application/octet-stream'), 100),
    p_tamanho, p_sha256, p_unidade || '/' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM') || '/' || v_id || '.' || v_ext, v_eu);
  perform core.auditar(v_eu, null, 'envio_iniciado', 'fin.envio', v_id::text, null,
    jsonb_build_object('unidade', p_unidade, 'tipo', p_tipo, 'nome', left(p_nome, 200), 'tamanho', p_tamanho, 'sha256', p_sha256));
  return jsonb_build_object('duplicado', false, 'id', v_id,
    'caminho', (select caminho from fin.envios where id = v_id));
end $$;

-- a função de recebimento confere o arquivo gravado (tamanho e hash refeitos sobre os bytes)
create or replace function fin.envio_arquivo_recebido(p_id uuid, p_tamanho int, p_sha256 text) returns text
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare e record;
begin
  select * into e from fin.envios where id = p_id for update;
  if e.id is null or e.status <> 'aguardando_arquivo' then raise exception 'envio % não está aguardando arquivo', p_id; end if;
  if p_sha256 is distinct from e.sha256 or p_tamanho is distinct from e.tamanho then
    update fin.envios set status = 'erro', motivo = 'arquivo recebido difere do anunciado (hash/tamanho)', atualizado_em = now() where id = p_id;
    return 'erro';
  end if;
  update fin.envios set status = 'recebido', atualizado_em = now() where id = p_id;
  return 'recebido';
end $$;

-- ---------------------------------------------------------------------------
-- 2. Leitura (agente financeiro): fila, registro da leitura e conferência das contas de fechamento
-- ---------------------------------------------------------------------------
create or replace function fin.agendar_envios() returns int
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare e record; n int := 0; v_p uuid; v_t uuid;
begin
  if core.cfg('fin.envios.ativo', 'false') <> 'true' or not exists (select 1 from core.agentes where id = 'financeiro' and status = 'ativo') then
    return 0;
  end if;
  select id into v_p from core.principais where agente_id = 'financeiro';
  for e in select * from fin.envios where status = 'recebido' and tarefa_id is null order by criado_em limit 50 for update skip locked loop
    v_t := core.criar_tarefa(v_p, 'financeiro', 'fin_envio', 'fin.envio', 'ler', e.unidade_id, jsonb_build_object('envio', e.id),
      'fin:envio:' || e.id, null, 4);
    update fin.envios set tarefa_id = v_t, status = 'lendo', atualizado_em = now() where id = e.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- contas de fechamento de uma leitura (o mesmo cálculo é refeito pelo validador)
-- extrato: {saldo_inicial?, saldo_final?, linhas:[{data, valor(±), descricao, documento?}]}
-- fatura:  {total, vencimento?, final_cartao?, compras:[{data, descricao, valor(±), parcela?, categoria?}]}
-- stone:   {total_bruto?, total_liquido?, transacoes:[{id?, data, forma(credito|debito|pix), valor, liquido?}]}
-- comprovante|boleto|nota: {itens:[{valor, data?, vencimento?, favorecido?, favorecido_doc?, id_transacao?, descricao?}]}
create or replace function fin._checar_leitura(p_tipo text, l jsonb) returns jsonb
language plpgsql immutable set search_path = pg_catalog as $$
declare n int; s numeric; ruins int; tol numeric := 0.05; esp numeric; ok boolean; av text[] := '{}';
begin
  if p_tipo = 'extrato' then
    select count(*), coalesce(sum((x->>'valor')::numeric), 0),
           count(*) filter (where x->>'data' !~ '^\d{4}-\d{2}-\d{2}$' or coalesce((x->>'valor')::numeric, 0) = 0)
      into n, s, ruins from jsonb_array_elements(coalesce(l->'linhas', '[]')) x;
    if (l->>'saldo_inicial') is not null and (l->>'saldo_final') is not null then
      esp := (l->>'saldo_final')::numeric - (l->>'saldo_inicial')::numeric;
      ok := abs(s - esp) <= 0.01;
      if not ok then av := av || ('saldo inicial + movimentos não fecha com o saldo final (diferença de ' || round(s - esp, 2) || ')'); end if;
    else ok := null; av := av || 'extrato sem saldo inicial e final: não dá para conferir o fechamento'::text; end if;
  elsif p_tipo = 'fatura' then
    select count(*), coalesce(sum((x->>'valor')::numeric), 0),
           count(*) filter (where x->>'data' !~ '^\d{4}-\d{2}-\d{2}$' or (x->>'valor') is null)
      into n, s, ruins from jsonb_array_elements(coalesce(l->'compras', '[]')) x;
    esp := (l->>'total')::numeric;
    if esp is null then ok := null; av := av || 'fatura sem total: não dá para conferir'::text;
    else ok := abs(s - esp) <= tol;
      if not ok then av := av || ('soma das compras (' || round(s, 2) || ') não bate com o total da fatura (' || esp || ')'); end if;
    end if;
  elsif p_tipo = 'stone' then
    select count(*), coalesce(sum((x->>'valor')::numeric), 0),
           count(*) filter (where x->>'data' !~ '^\d{4}-\d{2}-\d{2}$' or coalesce((x->>'valor')::numeric, 0) <= 0
                              or coalesce(x->>'forma', '') not in ('credito','debito','pix'))
      into n, s, ruins from jsonb_array_elements(coalesce(l->'transacoes', '[]')) x;
    esp := (l->>'total_bruto')::numeric;
    if esp is null then ok := null; av := av || 'relatório sem total bruto: não dá para conferir'::text;
    else ok := abs(s - esp) <= tol;
      if not ok then av := av || ('soma das vendas (' || round(s, 2) || ') não bate com o total do relatório (' || esp || ')'); end if;
    end if;
  elsif p_tipo in ('comprovante','boleto','nota') then
    select count(*), coalesce(sum((x->>'valor')::numeric), 0), count(*) filter (where coalesce((x->>'valor')::numeric, 0) <= 0)
      into n, s, ruins from jsonb_array_elements(coalesce(l->'itens', '[]')) x;
    ok := n > 0 and ruins = 0;
  else
    return jsonb_build_object('ok', false, 'itens', 0, 'avisos', jsonb_build_array('não reconheci como documento financeiro'));
  end if;
  if ruins > 0 then ok := false; av := av || (ruins || ' linha(s) sem data ou valor legível'); end if;
  if n = 0 then ok := false; av := av || 'nenhuma linha lida'::text; end if;
  return jsonb_build_object('ok', ok, 'itens', n, 'soma', round(s, 2), 'esperado', esp, 'avisos', to_jsonb(av));
end $$;

-- conta da loja pelo número da conta do OFX (final do número), quando o envio não disse qual
create or replace function fin._conta_por_numero(p_unidade text, p_numero text) returns text
language sql stable security definer set search_path = fin, pg_catalog as $$
  select (array_agg(id))[1] from fin.contas
  where unidade_id = p_unidade and ativo and tipo <> 'cartao_credito' and coalesce(final_numero, '') <> ''
    and regexp_replace(coalesce(p_numero, ''), '\D', '', 'g') like '%' || regexp_replace(final_numero, '\D', '', 'g') || '%'   -- número pode vir com dígito
  having count(*) = 1
$$;

-- p_leitura: {tipo, formato: 'ofx'|'ia', conta_numero?, ...campos do tipo}
create or replace function fin.envio_registrar_leitura(p_tarefa uuid, p_executor text, p_leitura jsonb) returns jsonb
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare t record; e record; v_tipo text; v_fmt text; c jsonb; v_conta text; v_imp jsonb; v_status text; v jsonb;
begin
  select * into t from core.tarefas where id = p_tarefa for update;
  if t.status <> 'executando' or t.executor is distinct from p_executor or t.tipo <> 'fin_envio' then
    raise exception 'tarefa não está em execução por este executor (status=%)', t.status;
  end if;
  select * into e from fin.envios where id = (t.payload->>'envio')::uuid for update;
  if e.id is null or e.status <> 'lendo' then raise exception 'envio não está em leitura'; end if;
  if jsonb_typeof(p_leitura) is distinct from 'object' then raise exception 'leitura inválida'; end if;
  v_tipo := p_leitura->>'tipo'; v_fmt := p_leitura->>'formato';
  if v_tipo not in ('extrato','fatura','stone','comprovante','boleto','nota','outro') or v_fmt not in ('ofx','ia') then
    raise exception 'leitura sem tipo/formato válido';
  end if;
  if v_fmt = 'ofx' and v_tipo <> 'extrato' then raise exception 'OFX só pode ser extrato'; end if;
  if length(p_leitura::text) > 2000000 then raise exception 'leitura grande demais'; end if;
  c := fin._checar_leitura(v_tipo, p_leitura);
  v_conta := coalesce(e.conta_id, case when v_tipo = 'extrato' then fin._conta_por_numero(e.unidade_id, p_leitura->>'conta_numero') end);

  -- só OFX de extrato, com conta conhecida e fechamento conferido (ou sem saldo para conferir), é lançado sem pessoa
  if v_fmt = 'ofx' and v_tipo = 'extrato' and v_conta is not null and c->>'ok' is distinct from 'false' then
    v_imp := fin.importar_extrato(v_conta, e.sha256, 'ofx', p_leitura->'linhas', 'agente_financeiro',
      (p_leitura->>'saldo_inicial')::numeric, (p_leitura->>'saldo_final')::numeric);
    v_status := 'lancado';
  else
    v_status := 'conferir';
  end if;
  update fin.envios set tipo = v_tipo, formato = v_fmt, conta_id = v_conta, leitura = p_leitura, checagens = c,
    resultado = v_imp, status = v_status, atualizado_em = now(),
    decidido_em = case when v_status = 'lancado' then now() end,
    motivo = case when v_status = 'conferir' and v_fmt = 'ofx' and v_conta is null then 'não reconheci a conta do extrato: escolha a conta'
                  when v_status = 'conferir' and v_fmt = 'ofx' then 'saldo do extrato não fecha'
                  when v_tipo = 'outro' then 'não reconheci como documento financeiro' end
   where id = e.id;
  v := jsonb_build_object('envio', e.id, 'tipo', v_tipo, 'status', v_status, 'checagens', c, 'importacao', v_imp);
  perform core.registrar_execucao(p_tarefa, p_executor, 'sucesso', e.id::text, v);
  return v;
end $$;

create or replace function fin.envio_erro_leitura(p_tarefa uuid, p_executor text, p_erro text) returns text
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare t record; v text;
begin
  select * into t from core.tarefas where id = p_tarefa;
  v := core.registrar_execucao(p_tarefa, p_executor, 'erro', null, null, left(p_erro, 300));
  if v = 'falhou' then
    update fin.envios set status = 'erro', motivo = 'não consegui ler o arquivo: ' || left(p_erro, 200), atualizado_em = now()
     where id = (t.payload->>'envio')::uuid;
  end if;
  return v;
end $$;

-- Validador independente: refaz as contas e confere que nada foi lançado fora da regra
create or replace function fin.validar_envio(p_tarefa uuid, p_validador text) returns text
language plpgsql security definer set search_path = fin, core, pg_catalog as $$
declare t record; e record; err text[] := '{}'; c jsonb; i record;
begin
  select * into t from core.tarefas where id = p_tarefa;
  if t.status <> 'validando' then raise exception 'tarefa não está em validação (status=%)', t.status; end if;
  select * into e from fin.envios where id = (t.payload->>'envio')::uuid;
  if e.id is null then err := array_append(err, 'envio inexistente');
  else
    c := fin._checar_leitura(e.tipo, e.leitura);
    if c is distinct from e.checagens then err := array_append(err, 'contas de fechamento refeitas não conferem'); end if;
    if e.status = 'lancado' and e.formato <> 'ofx' then err := array_append(err, 'documento lido pela IA lançado sem confirmação de pessoa'); end if;
    if e.status = 'lancado' then
      select * into i from fin.importacoes where conta_id = e.conta_id and arquivo_sha256 = e.sha256;
      if i.id is null then err := array_append(err, 'extrato marcado como lançado sem importação');
      elsif i.linhas <> jsonb_array_length(e.leitura->'linhas') then err := array_append(err, 'importação com número de linhas diferente da leitura');
      end if;
      if e.checagens->>'ok' = 'false' then err := array_append(err, 'extrato lançado com fechamento que não bate'); end if;
    end if;
    if e.leitura::text ~ '[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}' and e.tipo in ('extrato','fatura','stone') then
      err := array_append(err, 'leitura com CPF formatado onde não deveria haver');
    end if;
  end if;
  if array_length(err, 1) is null then
    return core.registrar_validacao(p_tarefa, p_validador, true, null, jsonb_build_object('envio', e.id));
  end if;
  if e.status = 'conferir' then update fin.envios set motivo = 'conferência automática reprovou: ' || array_to_string(err, '; ') where id = e.id; end if;
  return core.registrar_validacao(p_tarefa, p_validador, false, array_to_string(err, '; '), jsonb_build_object('envio', e.id, 'erros', to_jsonb(err)));
end $$;

-- ---------------------------------------------------------------------------
-- 3. Stone no caixa (a conferência valor a valor do agente de Caixa)
-- ---------------------------------------------------------------------------
create or replace function cx.registrar_stone(p_unidade text, p_transacoes jsonb, p_sha256 text) returns jsonb
language plpgsql security definer set search_path = cx, core, pg_catalog as $$
declare v_ini date; v_fim date; n int; v_al jsonb;
begin
  if not exists (select 1 from core.unidades where id = p_unidade) then raise exception 'loja inexistente'; end if;
  select min((x->>'data')::date), max((x->>'data')::date) into v_ini, v_fim from jsonb_array_elements(p_transacoes) x;
  if v_ini is null then raise exception 'relatório sem vendas'; end if;
  delete from cx.recebimentos where fonte = 'stone' and unidade_id = p_unidade and dia between v_ini and v_fim;
  insert into cx.recebimentos (id, fonte, unidade_id, dia, forma, valor, parcela_crediario)
  select 'stone:' || coalesce(nullif(regexp_replace(x->>'id', '[^A-Za-z0-9_-]', '', 'g'), ''), left(p_sha256, 16) || '-' || o),
         'stone', p_unidade, (x->>'data')::date, x->>'forma', round((x->>'valor')::numeric, 2), false
  from jsonb_array_elements(p_transacoes) with ordinality t(x, o)
  where x->>'forma' in ('credito','debito','pix') and (x->>'valor')::numeric > 0
  on conflict (id) do update set dia = excluded.dia, forma = excluded.forma, valor = excluded.valor, unidade_id = excluded.unidade_id;
  get diagnostics n = row_count;
  insert into cx.cobertura (fonte, unidade_id, ate) values ('stone', p_unidade, v_fim)
  on conflict (fonte, unidade_id) do update set ate = greatest(cx.cobertura.ate, excluded.ate), em = now();
  v_al := cx.recalcular();
  return jsonb_build_object('vendas', n, 'de', v_ini, 'ate', v_fim, 'alertas', v_al);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Painel: lista, confirmação (pessoa) e descarte
-- ---------------------------------------------------------------------------
create or replace function public.painel_envios(p_unidade text default null) returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; un text[];
begin
  v_eu := painel._entrar('envios', p_unidade);
  un := painel._unidades(v_eu, 'enviar_documento');
  if p_unidade is not null then perform painel._exigir(v_eu, 'enviar_documento', p_unidade); un := array[p_unidade]; end if;
  if cardinality(un) = 0 then raise exception 'sem permissão para enviar arquivos' using errcode = '42501'; end if;
  return jsonb_build_object(
    'leitura_ligada', core.cfg('fin.envios.ativo', 'false') = 'true' and exists (select 1 from core.agentes where id = 'financeiro' and status = 'ativo'),
    'max_mb', coalesce(nullif(core.cfg('fin.envios.max_mb', '20'), '')::int, 20),
    'contas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'apelido', apelido, 'tipo', tipo, 'unidade_id', unidade_id,
                 'instituicao', instituicao, 'final', final_numero) order by unidade_id, apelido), '[]')
               from fin.contas where ativo and unidade_id = any(un)),
    'envios', (select coalesce(jsonb_agg(x order by x->>'criado_em' desc), '[]') from (
      select jsonb_build_object('id', e.id, 'unidade_id', e.unidade_id, 'conta_id', e.conta_id, 'tipo_declarado', e.tipo_declarado, 'tipo', e.tipo,
        'nome_arquivo', e.nome_arquivo, 'tamanho', e.tamanho, 'status', e.status, 'formato', e.formato, 'checagens', e.checagens,
        'leitura', case when e.status = 'conferir' then painel._mascarar(e.leitura) end,
        'resultado', e.resultado, 'motivo', e.motivo, 'criado_em', e.criado_em, 'decidido_em', e.decidido_em,
        'enviado_por', (select nome from core.principais where id = e.enviado_por),
        'pode_confirmar', painel._pode(v_eu, 'confirmar_documento', e.unidade_id)) x
      from fin.envios e where e.unidade_id = any(un) order by e.criado_em desc limit 100) q),
    'faltando', (select coalesce(jsonb_agg(to_jsonb(f)), '[]') from fin.arquivos_faltando() f where f.unidade_id = any(un)),
    'categorias', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by grupo, nome), '[]')
                   from fin.categorias where ativo and natureza = 'despesa'));
end $$;

-- p_conta: conta do extrato ou do cartão (quando a leitura não definiu); p_categorias: {"<índice da compra>": "<categoria>"}
create or replace function public.painel_envio_confirmar(p_id uuid, p_conta text default null, p_categorias jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; e record; v_nome text; v_conta text; r jsonb; x jsonb; i int; v_l uuid; v_lancs uuid[] := '{}'; v_cat text;
  v_doc uuid; v_tipo_doc text; n_pend int := 0; v_ct record;
begin
  select * into e from fin.envios where id = p_id for update;
  if e.id is null then raise exception 'envio inexistente' using errcode = '22023'; end if;
  v_eu := painel._entrar('envio_confirmar', e.unidade_id);
  perform painel._exigir(v_eu, 'confirmar_documento', e.unidade_id);
  if e.status <> 'conferir' then raise exception 'envio não está para conferir (status=%)', e.status using errcode = '22023'; end if;
  if e.tipo = 'outro' then raise exception 'não é documento financeiro: descarte o envio' using errcode = '22023'; end if;
  if e.checagens->>'ok' = 'false' then
    raise exception 'as contas não fecham (%): corrija o arquivo e envie de novo, ou descarte', e.checagens->'avisos' using errcode = '22023';
  end if;
  select nome into v_nome from core.principais where id = v_eu;
  v_conta := coalesce(p_conta, e.conta_id);
  select * into v_ct from fin.contas where false;   -- deixa o registro definido (vazio) quando não há conta
  if v_conta is not null then
    select * into v_ct from fin.contas where id = v_conta and unidade_id = e.unidade_id and ativo;
    if v_ct.id is null then raise exception 'conta não é desta loja' using errcode = '22023'; end if;
  end if;

  if e.tipo = 'extrato' then
    if v_conta is null or v_ct.tipo = 'cartao_credito' then raise exception 'escolha a conta bancária do extrato' using errcode = '22023'; end if;
    r := fin.importar_extrato(v_conta, e.sha256, case when e.formato = 'ofx' then 'ofx' else 'ia' end, e.leitura->'linhas', 'pessoa:' || v_nome,
      (e.leitura->>'saldo_inicial')::numeric, (e.leitura->>'saldo_final')::numeric);

  elsif e.tipo = 'fatura' then
    if v_conta is null or v_ct.tipo <> 'cartao_credito' then raise exception 'escolha o cartão desta fatura' using errcode = '22023'; end if;
    i := 0;
    for x in select * from jsonb_array_elements(e.leitura->'compras') loop
      i := i + 1;
      if (x->>'valor')::numeric <= 0 then continue; end if;   -- pagamento/estorno da fatura: não é compra
      v_cat := coalesce(nullif(p_categorias->>(i::text), ''),
                        case when exists (select 1 from fin.categorias where id = x->>'categoria' and ativo) then x->>'categoria' end,
                        fin.categoria_por_regra(null, x->>'descricao', 'debito', (x->>'data')::date));
      if v_cat is not null and not exists (select 1 from fin.categorias where id = v_cat and ativo) then
        raise exception 'categoria % inexistente', v_cat using errcode = '22023';
      end if;
      v_l := fin.registrar_lancamento('despesa', 'saida', round((x->>'valor')::numeric, 2), e.unidade_id, (x->>'data')::date,
        'pessoa:' || v_nome, 'painel', v_conta, v_cat, left(x->>'descricao', 200), null,
        left(concat_ws(' ', x->>'descricao', nullif(x->>'parcela', '')), 300), null, 'pendente', null, null);
      v_lancs := v_lancs || v_l;
      if v_cat is null then
        perform fin.abrir_pendencia('sem_classificacao', e.unidade_id, null, v_l, jsonb_build_object('envio', e.id, 'descricao', left(x->>'descricao', 200)), false);
        n_pend := n_pend + 1;
      end if;
    end loop;
    r := jsonb_build_object('compras', cardinality(v_lancs), 'sem_categoria', n_pend);

  elsif e.tipo = 'stone' then
    r := cx.registrar_stone(e.unidade_id, e.leitura->'transacoes', e.sha256);

  else  -- comprovante / boleto / nota
    v_tipo_doc := case e.tipo when 'comprovante' then 'comprovante_pagamento' when 'boleto' then 'boleto' else 'documento_fiscal' end;
    insert into fin.documentos (tipo, sha256, storage_path, mime, origem, unidade_id, enviado_por, extraido, status)
    values (v_tipo_doc, e.sha256, 'fin-envios/' || e.caminho, e.mime, 'painel', e.unidade_id, e.enviado_por, e.leitura,
      case when e.tipo = 'nota' then 'revisao' else 'extraido' end)
    returning id into v_doc;
    if e.tipo in ('comprovante','boleto') then
      for x in select * from jsonb_array_elements(e.leitura->'itens') loop
        v_cat := fin.categoria_por_regra(fin.so_digitos(x->>'favorecido_doc'), x->>'favorecido', 'debito',
                   coalesce(nullif(x->>'data', '')::date, nullif(x->>'vencimento', '')::date));
        v_l := fin.registrar_lancamento('despesa', 'saida', round((x->>'valor')::numeric, 2), e.unidade_id,
          coalesce(nullif(x->>'data', '')::date, nullif(x->>'vencimento', '')::date), 'pessoa:' || v_nome, 'painel', null, v_cat,
          left(x->>'favorecido', 200), case when length(fin.so_digitos(x->>'favorecido_doc')) in (11, 14) then fin.so_digitos(x->>'favorecido_doc') end,
          left(coalesce(x->>'descricao', case when e.tipo = 'boleto' then 'Boleto' end), 300),
          coalesce(nullif(x->>'data', '')::date, nullif(x->>'vencimento', '')::date),
          case when e.tipo = 'boleto' then 'previsto' else 'pendente' end, left(nullif(x->>'id_transacao', ''), 100), v_doc);
        v_lancs := v_lancs || v_l;
        if v_cat is null then
          perform fin.abrir_pendencia('sem_classificacao', e.unidade_id, null, v_l, jsonb_build_object('envio', e.id, 'favorecido', left(x->>'favorecido', 200)), false);
          n_pend := n_pend + 1;
        end if;
      end loop;
    end if;
    r := jsonb_build_object('documento', v_doc, 'lancamentos', cardinality(v_lancs), 'sem_categoria', n_pend);
  end if;

  update fin.envios set status = 'lancado', conta_id = coalesce(v_conta, conta_id), resultado = r, decidido_por = v_eu, decidido_em = now(),
    motivo = null, atualizado_em = now() where id = e.id;
  perform core.auditar(v_eu, null, 'envio_confirmado', 'fin.envio', e.id::text, jsonb_build_object('status', 'conferir'),
    jsonb_build_object('status', 'lancado', 'tipo', e.tipo, 'resultado', r));
  return jsonb_build_object('status', 'lancado', 'resultado', r);
end $$;

create or replace function public.painel_envio_descartar(p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = core, pg_catalog as $$
declare v_eu uuid; e record;
begin
  select * into e from fin.envios where id = p_id for update;
  if e.id is null then raise exception 'envio inexistente' using errcode = '22023'; end if;
  v_eu := painel._entrar('envio_descartar', e.unidade_id);
  perform painel._exigir(v_eu, 'enviar_documento', e.unidade_id);
  if e.status in ('lancado','descartado') then raise exception 'envio já %', e.status using errcode = '22023'; end if;
  if coalesce(length(btrim(p_motivo)), 0) < 3 then raise exception 'diga o motivo' using errcode = '22023'; end if;
  update fin.envios set status = 'descartado', motivo = left(p_motivo, 300), decidido_por = v_eu, decidido_em = now(), atualizado_em = now()
   where id = p_id;
  perform core.auditar(v_eu, null, 'envio_descartado', 'fin.envio', p_id::text, jsonb_build_object('status', e.status),
    jsonb_build_object('status', 'descartado'), left(p_motivo, 300));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Arquivos que deviam ter chegado (lido pelo Supervisor e pela tela de envio)
-- ---------------------------------------------------------------------------
create or replace function fin.arquivos_faltando() returns table (esperado_id bigint, unidade_id text, tipo text, conta_id text,
  descricao text, prazo timestamptz)
language plpgsql stable security definer set search_path = fin, core, pg_catalog as $$
declare a record; agora timestamp := now() at time zone 'America/Sao_Paulo'; hoje date := agora::date;
  v_prazo timestamp; v_janela timestamp; v_cob date; v_rotulo text; v_ok boolean;
begin
  for a in select x.*, c.apelido from fin.arquivos_esperados x left join fin.contas c on c.id = x.conta_id where x.ativo loop
    -- prazo = último horário-limite que já passou; janela = desde quando um envio conta para esse prazo
    if a.frequencia = 'diaria' then
      continue when not (extract(isodow from hoje)::int = any(string_to_array(replace(a.dias, ' ', ''), ',')::int[]))
                or extract(hour from agora) < a.hora_limite;
      v_prazo := hoje + make_time(a.hora_limite, 0, 0); v_janela := hoje::timestamp;            -- o de ontem chega hoje
    elsif a.frequencia = 'semanal' then
      v_prazo := date_trunc('week', agora) + make_interval(days => a.dia_limite - 1, hours => a.hora_limite);
      if v_prazo > agora then v_prazo := v_prazo - interval '7 days'; end if;
      v_janela := v_prazo - interval '7 days';                                                  -- um por semana
    else
      v_prazo := date_trunc('month', agora) + make_interval(days => a.dia_limite - 1, hours => a.hora_limite);
      if v_prazo > agora then v_prazo := v_prazo - interval '1 month'; end if;
      v_janela := v_prazo - interval '1 month';                                                 -- um por mês
    end if;

    v_ok := exists (select 1 from fin.envios e
      where e.unidade_id = a.unidade_id and coalesce(e.tipo, e.tipo_declarado) in (a.tipo, 'auto')
        and (a.conta_id is null or e.conta_id is null or e.conta_id = a.conta_id) and e.status not in ('descartado','erro')
        and e.criado_em >= v_janela at time zone 'America/Sao_Paulo');
    if not v_ok and a.tipo = 'extrato' and a.conta_id is not null then
      select max(periodo_fim) into v_cob from fin.importacoes where conta_id = a.conta_id;
      v_ok := v_cob >= (case when a.frequencia = 'diaria' then hoje - 1 else (v_prazo::date - 1) end);
    end if;
    if not v_ok and a.tipo = 'stone' then
      select ate into v_cob from cx.cobertura where fonte = 'stone' and cx.cobertura.unidade_id = a.unidade_id;
      v_ok := v_cob >= v_prazo::date - 1;
    end if;
    continue when v_ok;
    v_rotulo := case a.tipo when 'extrato' then 'Extrato' when 'fatura' then 'Fatura do cartão' else 'Relatório da Stone' end
      || coalesce(' ' || a.apelido, '') || ' (' || coalesce((select nome from core.unidades u where u.id = a.unidade_id), a.unidade_id) || ')'
      || case a.frequencia when 'diaria' then ': falta o de ' || to_char(hoje - 1, 'DD/MM')
                           when 'semanal' then ': falta o da semana (prazo ' || to_char(v_prazo, 'DD/MM HH24"h"') || ')'
                           else ': falta a do mês (prazo ' || to_char(v_prazo, 'DD/MM') || ')' end;
    esperado_id := a.id; unidade_id := a.unidade_id; tipo := a.tipo; conta_id := a.conta_id; descricao := v_rotulo;
    prazo := v_prazo at time zone 'America/Sao_Paulo';
    return next;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Endurecimento
-- ---------------------------------------------------------------------------
alter table fin.envios enable row level security;
alter table fin.envios force row level security;
alter table fin.arquivos_esperados enable row level security;
alter table fin.arquivos_esperados force row level security;
revoke all on fin.envios, fin.arquivos_esperados from public;
do $$
declare f text;
begin
  foreach f in array array['fin._envio_ext(text)', 'fin.envio_arquivo_recebido(uuid, int, text)', 'fin.agendar_envios()',
    'fin._checar_leitura(text, jsonb)', 'fin._conta_por_numero(text, text)', 'fin.envio_registrar_leitura(uuid, text, jsonb)',
    'fin.envio_erro_leitura(uuid, text, text)', 'fin.validar_envio(uuid, text)', 'cx.registrar_stone(text, jsonb, text)',
    'fin.arquivos_faltando()'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon, authenticated', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('grant execute on function %s to service_role', f); end if;
  end loop;
  foreach f in array array['public.painel_envio_iniciar(text, text, text, text, text, int, text)', 'public.painel_envios(text)',
    'public.painel_envio_confirmar(uuid, text, jsonb)', 'public.painel_envio_descartar(uuid, text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon', f);
      execute format('grant execute on function %s to authenticated', f);
    end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('grant execute on function %s to service_role', f); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on fin.envios, fin.arquivos_esperados from anon, authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select on fin.envios, fin.arquivos_esperados to service_role';
  end if;
end $$;
