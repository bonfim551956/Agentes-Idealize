-- =============================================================================
-- Idealize AI — Auditoria do atendimento (conversas da Kommo)  · Migração 20261107140000
-- Pedido do Diego (07/11, PODE FAZER): auditar as conversas das operadoras para saber quem segue o padrão e o quanto
-- o padrão funciona. Três peças:
--   1. O robô (repositório robos-idealize, GitHub Actions) entra na Kommo com o usuário próprio, abre o card de cada
--      lead da fila (public.aud_fila) e copia o TEXTO da conversa para aud.conversas (public.aud_receber). Só leitura.
--   2. O agente Auditor de Atendimento (tarefa agendada) lê as conversas sem nota, aplica o checklist (aud.criterios,
--      editável na tela) e grava a nota de cada critério com o trecho que prova (aud.concluir_avaliacao).
--   3. A tela mostra por operadora: nota média, % de cada critério e o resultado (agendou / comprou no ADM),
--      para ver se quem segue o padrão vende mais.
-- Telefones e números longos são tirados do texto antes de gravar. Leitura só para quem consulta a rede inteira.
-- =============================================================================
create schema if not exists aud;
revoke all on schema aud from public;

create table aud.criterios (
  id        text primary key check (id ~ '^[a-z0-9_]{2,40}$'),
  titulo    text not null,
  descricao text not null,               -- o que o agente procura na conversa
  peso      int not null default 1 check (peso between 1 and 5),
  ordem     int not null default 0,
  ativo     boolean not null default true,
  atualizado_em timestamptz not null default now()
);
-- checklist inicial (provisório até o script oficial; editável na tela)
insert into aud.criterios (id, titulo, descricao, peso, ordem) values
  ('saudacao', 'Saudação e apresentação', 'Cumprimenta, diz o próprio nome e chama o cliente pelo nome.', 1, 1),
  ('tempo', 'Resposta rápida', 'Responde a primeira mensagem do cliente em até 5 minutos (horário comercial).', 2, 2),
  ('necessidade', 'Entende a necessidade', 'Pergunta o que o cliente precisa (exame, óculos, lente, grau, última consulta) antes de oferecer.', 2, 3),
  ('oferta', 'Explica a oferta', 'Explica a oferta ou o exame com clareza (o que é, condições, onde fica a loja).', 2, 4),
  ('agendamento', 'Propõe agendamento', 'Oferece data e horário concretos para o cliente ir à loja ou ao exame.', 3, 5),
  ('objecao', 'Contorna objeção', 'Quando o cliente hesita (preço, horário, distância), responde e tenta manter o agendamento.', 2, 6),
  ('confirmacao', 'Confirma o agendamento', 'Confirma dia, hora e endereço e pede confirmação do cliente.', 2, 7),
  ('followup', 'Faz follow-up', 'Quando o cliente para de responder, volta a chamar (não abandona a conversa).', 2, 8);

create table aud.conversas (
  lead_id        bigint primary key,
  responsavel_id bigint,
  funil_id       bigint,
  dia            date not null,              -- dia da atividade que colocou o lead na fila
  mensagens      jsonb not null default '[]',-- [{em, de: 'cliente'|'atendente'|'bot', autor, texto}]
  primeira_cliente text,                     -- 1ª mensagem do cliente (mostra de qual anúncio veio)
  capturado_em   timestamptz not null default now(),
  erro           text
);
create index aud_conversas_dia on aud.conversas (dia desc);
create index aud_conversas_resp on aud.conversas (responsavel_id, dia);

create table aud.avaliacoes (
  lead_id      bigint primary key references aud.conversas(lead_id) on delete cascade,
  nota         int not null check (nota between 0 and 100),
  itens        jsonb not null,               -- {criterio: {ok: true|false|null, trecho}}
  resumo       text not null,
  capturado_em timestamptz not null,         -- versão da conversa avaliada
  agente       text not null default 'auditor-atendimento v1',
  avaliado_em  timestamptz not null default now()
);

alter table aud.criterios enable row level security; alter table aud.criterios force row level security;
alter table aud.conversas enable row level security; alter table aud.conversas force row level security;
alter table aud.avaliacoes enable row level security; alter table aud.avaliacoes force row level security;
do $$ begin
  revoke all on all tables in schema aud from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on all tables in schema aud from anon, authenticated'; end if;
end $$;

insert into core.config (chave, valor) values
  ('aud.por_operadora_dia', '8'),   -- quantas conversas de cada operadora o robô lê por dia
  ('aud.ativo', 'true')
on conflict (chave) do nothing;

insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('auditor_atendimento', 'Auditor de Atendimento', 'comercial', 'ativo', '0.1.0',
   'Lê as conversas das operadoras na Kommo (amostra diária por operadora), dá nota pelo checklist do padrão de atendimento e cruza com agendamento e venda no ADM. Só leitura: nunca envia mensagem nem altera lead.')
on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', 'Auditor de Atendimento', 'auditor_atendimento' where not exists (select 1 from core.principais where agente_id = 'auditor_atendimento');

-- tira telefone, CPF e números longos do texto
create or replace function aud._limpo(t text) returns text language sql immutable set search_path = pg_catalog as $$
  select left(regexp_replace(regexp_replace(coalesce(t, ''), '\+?\d[\d\s().-]{8,}\d', '[número]', 'g'), '\S+@\S+\.\S+', '[e-mail]', 'g'), 2000)
$$;

-- fila do robô: leads com mensagem de atendente ontem, até N por operadora (os mais movimentados primeiro)
create or replace function public.aud_fila(p_dia date default null) returns table (lead_id bigint, responsavel_id bigint, dia date)
language sql stable security definer set search_path = aud, com, core, pg_catalog as $$
  with d as (select coalesce(p_dia, (now() at time zone 'America/Sao_Paulo')::date - 1) dia),
  ativos as (
    select m.entidade_id lead_id, l.responsavel_id, count(*) n
      from com.mensagens m join com.leads l on l.id = m.entidade_id, d
     where m.entidade_tipo = 'lead' and m.sentido = 'atendente' and (m.em at time zone 'America/Sao_Paulo')::date = d.dia
       and l.responsavel_id is not null and core.cfg('aud.ativo', 'true') = 'true'
     group by 1, 2),
  r as (select a.*, row_number() over (partition by a.responsavel_id order by a.n desc, a.lead_id) k from ativos a)
  select r.lead_id, r.responsavel_id, d.dia from r, d
   where r.k <= greatest(1, least(coalesce(nullif(core.cfg('aud.por_operadora_dia', '8'), '')::int, 8), 40))
     and not exists (select 1 from aud.conversas c where c.lead_id = r.lead_id and c.dia = d.dia and c.erro is null)
   order by r.responsavel_id, r.k
$$;

-- o robô grava a conversa lida (substitui a anterior do mesmo lead; a nota antiga sai)
create or replace function public.aud_receber(p_lead bigint, p_dia date, p_mensagens jsonb, p_erro text default null) returns int
language plpgsql security definer set search_path = aud, com, pg_catalog as $$
declare v jsonb; n int;
begin
  if jsonb_typeof(coalesce(p_mensagens, '[]')) <> 'array' or jsonb_array_length(coalesce(p_mensagens, '[]')) > 2000 then raise exception 'mensagens inválidas'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('em', left(x->>'em', 20), 'de', case when x->>'de' in ('cliente','atendente','bot') then x->>'de' else 'atendente' end,
           'autor', left(aud._limpo(x->>'autor'), 60), 'texto', aud._limpo(x->>'texto'))), '[]'::jsonb)
    into v from jsonb_array_elements(coalesce(p_mensagens, '[]')) x where btrim(coalesce(x->>'texto', '')) <> '';
  insert into aud.conversas (lead_id, responsavel_id, funil_id, dia, mensagens, primeira_cliente, capturado_em, erro)
  select p_lead, l.responsavel_id, l.funil_id, p_dia, v,
         (select e->>'texto' from jsonb_array_elements(v) e where e->>'de' = 'cliente' limit 1), now(), left(p_erro, 300)
    from (select 1) z left join com.leads l on l.id = p_lead
  on conflict (lead_id) do update set responsavel_id = excluded.responsavel_id, funil_id = excluded.funil_id, dia = excluded.dia,
    mensagens = excluded.mensagens, primeira_cliente = excluded.primeira_cliente, capturado_em = now(), erro = excluded.erro;
  delete from aud.avaliacoes a where a.lead_id = p_lead;
  get diagnostics n = row_count;
  return jsonb_array_length(v);
end $$;

-- o agente grava a avaliação de uma conversa (nota calculada aqui pelos pesos, não pelo agente)
create or replace function aud.concluir_avaliacao(p_lead bigint, p_itens jsonb, p_resumo text) returns int
language plpgsql security definer set search_path = aud, pg_catalog as $$
declare c record; v_nota int; v_itens jsonb := '{}';
begin
  select * into c from aud.conversas where lead_id = p_lead and erro is null;
  if c.lead_id is null then raise exception 'conversa inexistente'; end if;
  if length(btrim(coalesce(p_resumo, ''))) < 10 then raise exception 'resumo obrigatório'; end if;
  select coalesce(jsonb_object_agg(k.id, jsonb_build_object('ok', case when p_itens->k.id->>'ok' in ('true','false') then (p_itens->k.id->>'ok')::boolean end,
           'trecho', left(aud._limpo(p_itens->k.id->>'trecho'), 300))), '{}'::jsonb)
    into v_itens from aud.criterios k where k.ativo;
  -- critério "não se aplica" (ok = null) fica fora da conta
  select coalesce(round(100.0 * sum(k.peso) filter (where (v_itens->k.id->>'ok')::boolean) / nullif(sum(k.peso) filter (where v_itens->k.id->>'ok' is not null), 0)), 0)
    into v_nota from aud.criterios k where k.ativo;
  insert into aud.avaliacoes (lead_id, nota, itens, resumo, capturado_em) values (p_lead, v_nota, v_itens, left(btrim(p_resumo), 600), c.capturado_em)
  on conflict (lead_id) do update set nota = excluded.nota, itens = excluded.itens, resumo = excluded.resumo, capturado_em = excluded.capturado_em, avaliado_em = now();
  return v_nota;
end $$;

-- para o agente: conversas lidas e ainda sem nota, com o checklist
create or replace function aud.pendentes(p_limite int default 20) returns jsonb
language sql stable security definer set search_path = aud, com, pg_catalog as $$
  select jsonb_build_object(
    'criterios', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'titulo', titulo, 'descricao', descricao, 'peso', peso) order by ordem), '[]'::jsonb) from aud.criterios where ativo),
    'conversas', (select coalesce(jsonb_agg(jsonb_build_object('lead_id', c.lead_id, 'operadora', u.nome, 'funil', f.nome, 'dia', c.dia, 'mensagens', c.mensagens)), '[]'::jsonb)
                    from (select * from aud.conversas c where c.erro is null and jsonb_array_length(c.mensagens) > 0
                            and not exists (select 1 from aud.avaliacoes a where a.lead_id = c.lead_id)
                          order by c.dia desc, c.lead_id limit least(greatest(coalesce(p_limite, 20), 1), 50)) c
                    left join com.usuarios u on u.id = c.responsavel_id left join com.funis f on f.id = c.funil_id))
$$;

-- tela
create or replace function public.painel_auditoria_atendimento(p_dias int default 30, p_operadora bigint default null) returns jsonb
language plpgsql security definer set search_path = aud, com, atr, core, pg_catalog as $$
declare v_eu uuid; v_ini date := (now() at time zone 'America/Sao_Paulo')::date - least(greatest(coalesce(p_dias, 30), 1), 120);
begin
  v_eu := painel._entrar('auditoria_atendimento', coalesce(p_operadora::text, ''));
  if not painel._pode(v_eu, 'consultar') then raise exception 'sem permissão' using errcode = '42501'; end if;
  drop table if exists _av;
  create temp table _av on commit drop as
    select c.lead_id, c.responsavel_id, c.dia, c.primeira_cliente, a.nota, a.itens, a.resumo, a.avaliado_em, f.nome funil,
           exists (select 1 from com.leads l join com.etapas e on e.funil_id = l.funil_id and e.id = l.etapa_id
                    where l.id = c.lead_id and (e.tipo = 'ganha' or e.nome ~* '(agendad|compareceu)')) agendou,
           exists (select 1 from atr.v_origem_vendas o where o.lead_id = c.lead_id) comprou
      from aud.conversas c join aud.avaliacoes a on a.lead_id = c.lead_id left join com.funis f on f.id = c.funil_id
     where c.dia >= v_ini;
  return jsonb_build_object(
    'desde', v_ini, 'pode_editar', painel._pode(v_eu, 'administrar'),
    'ultima_leitura', (select max(capturado_em) from aud.conversas), 'ultima_avaliacao', (select max(avaliado_em) from aud.avaliacoes),
    'lidas', (select count(*) from aud.conversas where dia >= v_ini and erro is null), 'avaliadas', (select count(*) from _av),
    'criterios', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'titulo', titulo, 'descricao', descricao, 'peso', peso, 'ordem', ordem, 'ativo', ativo) order by ordem), '[]'::jsonb) from aud.criterios),
    'operadoras', (select coalesce(jsonb_agg(x order by x->>'nota_media' desc nulls last), '[]'::jsonb) from (
       select jsonb_build_object('id', v.responsavel_id, 'nome', coalesce(u.nome, 'sem nome'), 'conversas', count(*), 'nota_media', round(avg(v.nota)),
         'agendou', round(100.0 * count(*) filter (where v.agendou) / count(*)), 'comprou', round(100.0 * count(*) filter (where v.comprou) / count(*)),
         'criterios', (select jsonb_object_agg(k.id, (select round(100.0 * count(*) filter (where (w.itens->k.id->>'ok')::boolean) / nullif(count(*) filter (where w.itens->k.id->>'ok' is not null), 0))
                                                         from _av w where w.responsavel_id = v.responsavel_id)) from aud.criterios k where k.ativo)) x
         from _av v left join com.usuarios u on u.id = v.responsavel_id group by v.responsavel_id, u.nome) q),
    -- o padrão funciona? resultado por faixa de nota
    'faixas', (select coalesce(jsonb_agg(jsonb_build_object('faixa', faixa, 'conversas', n, 'agendou', ag, 'comprou', co) order by faixa), '[]'::jsonb) from (
       select case when nota >= 80 then '80 a 100' when nota >= 50 then '50 a 79' else '0 a 49' end faixa, count(*) n,
              round(100.0 * count(*) filter (where agendou) / count(*)) ag, round(100.0 * count(*) filter (where comprou) / count(*)) co
         from _av group by 1) f),
    'conversas', (select coalesce(jsonb_agg(jsonb_build_object('lead_id', v.lead_id, 'operadora', u.nome, 'dia', v.dia, 'funil', v.funil, 'nota', v.nota,
                    'resumo', v.resumo, 'itens', v.itens, 'agendou', v.agendou, 'comprou', v.comprou, 'primeira_cliente', left(v.primeira_cliente, 140)) order by v.dia desc, v.nota), '[]'::jsonb)
                  from (select * from _av where p_operadora is null or responsavel_id = p_operadora order by dia desc, nota limit 200) v
                  left join com.usuarios u on u.id = v.responsavel_id));
end $$;

-- diretoria ajusta o checklist pela tela
create or replace function public.painel_aud_criterio_salvar(p_id text, p_titulo text, p_descricao text, p_peso int, p_ordem int, p_ativo boolean) returns void
language plpgsql security definer set search_path = aud, core, pg_catalog as $$
declare v_eu uuid; v_antes jsonb;
begin
  v_eu := painel._entrar('aud_criterio_salvar', p_id);
  perform painel._exigir(v_eu, 'administrar');
  if coalesce(p_id, '') !~ '^[a-z0-9_]{2,40}$' then raise exception 'código do critério: letras minúsculas, números e _' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_titulo, ''))) < 3 or length(btrim(coalesce(p_descricao, ''))) < 10 then raise exception 'escreva o título e o que o agente deve procurar' using errcode = '22023'; end if;
  if p_peso not between 1 and 5 then raise exception 'peso de 1 a 5' using errcode = '22023'; end if;
  select to_jsonb(c) into v_antes from aud.criterios c where id = p_id;
  insert into aud.criterios (id, titulo, descricao, peso, ordem, ativo, atualizado_em)
  values (p_id, btrim(p_titulo), btrim(p_descricao), p_peso, coalesce(p_ordem, 99), coalesce(p_ativo, true), now())
  on conflict (id) do update set titulo = excluded.titulo, descricao = excluded.descricao, peso = excluded.peso, ordem = excluded.ordem,
    ativo = excluded.ativo, atualizado_em = now();
  perform core.auditar(v_eu, null, 'aud_criterio_salvo', 'aud.criterios', p_id, v_antes,
    jsonb_build_object('titulo', p_titulo, 'peso', p_peso, 'ativo', p_ativo), null);
end $$;

do $$ declare f text; begin
  foreach f in array array['aud._limpo(text)', 'public.aud_fila(date)', 'public.aud_receber(bigint,date,jsonb,text)', 'aud.concluir_avaliacao(bigint,jsonb,text)',
    'aud.pendentes(int)', 'public.painel_auditoria_atendimento(int,bigint)', 'public.painel_aud_criterio_salvar(text,text,text,int,int,boolean)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', f); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.aud_fila(date), public.aud_receber(bigint,date,jsonb,text) from authenticated';
    execute 'grant execute on function public.painel_auditoria_atendimento(int,bigint) to authenticated';
    execute 'grant execute on function public.painel_aud_criterio_salvar(text,text,text,int,int,boolean) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.aud_fila(date), public.aud_receber(bigint,date,jsonb,text) to service_role';
  end if;
end $$;
