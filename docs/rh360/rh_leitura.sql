-- =============================================================================
-- Idealize RH 360 — visões de LEITURA para o agente de RH da Idealize AI.
-- Só aplicar com "PODE FAZER" do Diego. Não altera nenhuma tabela existente.
-- Entregam nome, loja, cargo, datas e situação. NUNCA: CPF, nascimento, endereço, telefone, e-mail, contato de
-- emergência, salário, conteúdo de documento (inclusive de saúde) ou motivo de desligamento/advertência.
-- Usuário próprio, só leitura, sem senha até o Diego definir (segredo RH_LEITURA_DB_URL no projeto Idealize).
-- =============================================================================
create schema if not exists idealize_ai;
revoke all on schema idealize_ai from public;

-- Vínculo atual de cada pessoa: loja (lotação aberta), cargo, tipo de contrato, situação, jornada e escala
create or replace view idealize_ai.rh_vinculos with (security_barrier = true) as
select v.id as vinculo_id, c.nome_completo as nome, l.codigo as loja, cg.nome as cargo, v.tipo::text as tipo, v.status::text as status,
       v.data_admissao, v.data_desligamento, v.jornada_semanal_horas, v.escala
from public.vinculos v
join public.colaboradores c on c.id = v.colaborador_id
left join lateral (select lo.loja_id from public.lotacoes lo where lo.vinculo_id = v.id and lo.fim is null order by lo.inicio desc limit 1) la on true
left join public.lojas l on l.id = coalesce(la.loja_id, c.loja_atual_id)
left join public.cargos cg on cg.id = v.cargo_id;

-- Férias registradas na linha do tempo ("FÉRIAS [PROGRAMADAS] DE dd/mm/aaaa A dd/mm/aaaa" / "PERÍODO AQUISITIVO ...")
create or replace view idealize_ai.rh_ferias with (security_barrier = true) as
select e.id, e.vinculo_id,
       to_date(substring(e.titulo from 'DE ([0-9]{2}/[0-9]{2}/[0-9]{4}) A'), 'DD/MM/YYYY') as inicio,
       to_date(substring(e.titulo from ' A ([0-9]{2}/[0-9]{2}/[0-9]{4})'), 'DD/MM/YYYY') as fim,
       to_date(substring(e.descricao from 'AQUISITIVO ([0-9]{2}/[0-9]{2}/[0-9]{4})'), 'DD/MM/YYYY') as aquisitivo_inicio,
       to_date(substring(e.descricao from 'AQUISITIVO [0-9]{2}/[0-9]{2}/[0-9]{4} A ([0-9]{2}/[0-9]{2}/[0-9]{4})'), 'DD/MM/YYYY') as aquisitivo_fim,
       e.titulo ilike '%PROGRAMADA%' as programada
from public.eventos_timeline e
where e.tipo::text = 'ferias' and e.vinculo_id is not null
  and e.titulo ~ 'DE [0-9]{2}/[0-9]{2}/[0-9]{4} A [0-9]{2}/[0-9]{2}/[0-9]{4}';

create or replace view idealize_ai.rh_desligamentos with (security_barrier = true) as
select d.id, d.vinculo_id, d.modalidade::text as modalidade, d.data_comunicacao, d.data_desligamento, d.status::text as status, d.concluido_em
from public.desligamentos d;

create or replace view idealize_ai.rh_tarefas with (security_barrier = true) as
select t.id, t.titulo, t.categoria::text as categoria, l.codigo as loja, t.prazo, t.prioridade::text as prioridade, t.status::text as status
from public.tarefas t left join public.lojas l on l.id = t.loja_id;

-- Só documentos que têm vencimento (ex.: exame ocupacional): categoria, vencimento e situação — sem conteúdo
create or replace view idealize_ai.rh_documentos_vencimento with (security_barrier = true) as
select d.id, v.id as vinculo_id, cat.codigo as categoria, d.vencimento, d.status::text as status
from public.documentos d
join public.doc_categorias cat on cat.id = d.categoria_id and cat.exige_vencimento
left join lateral (select vv.id from public.vinculos vv where vv.colaborador_id = d.colaborador_id order by vv.data_admissao desc limit 1) v on true
where d.vencimento is not null;

-- Mudanças de cargo e de salário (só a DATA e o tipo; nunca o valor) para a lista do mês da contabilidade
create or replace view idealize_ai.rh_mudancas with (security_barrier = true) as
select 'cargo:' || h.id as id, h.vinculo_id, 'cargo'::text as tipo, h.inicio as data from public.historico_cargos h
union all
select 'salario:' || r.id, r.vinculo_id, 'salario', r.vigencia_inicio from public.remuneracoes r;

create or replace view idealize_ai.rh_uniformes with (security_barrier = true) as
select i.id, i.peca, i.tamanho, i.estoque_minimo, coalesce((select sum(m.delta) from public.uniforme_movimentos m where m.item_id = i.id), 0) as saldo
from public.uniforme_itens i where i.ativo;

create role idealize_ai_leitor_rh login connection limit 3;   -- sem senha até o Diego definir
alter role idealize_ai_leitor_rh set default_transaction_read_only = on;
alter role idealize_ai_leitor_rh set statement_timeout = '15s';
grant usage on schema idealize_ai to idealize_ai_leitor_rh;
grant select on idealize_ai.rh_vinculos, idealize_ai.rh_ferias, idealize_ai.rh_desligamentos, idealize_ai.rh_tarefas,
  idealize_ai.rh_documentos_vencimento, idealize_ai.rh_mudancas, idealize_ai.rh_uniformes to idealize_ai_leitor_rh;
revoke all on idealize_ai.rh_vinculos, idealize_ai.rh_ferias, idealize_ai.rh_desligamentos, idealize_ai.rh_tarefas,
  idealize_ai.rh_documentos_vencimento, idealize_ai.rh_mudancas, idealize_ai.rh_uniformes from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on idealize_ai.rh_vinculos, idealize_ai.rh_ferias, idealize_ai.rh_desligamentos, idealize_ai.rh_tarefas,
      idealize_ai.rh_documentos_vencimento, idealize_ai.rh_mudancas, idealize_ai.rh_uniformes from anon, authenticated';
  end if;
end $$;
