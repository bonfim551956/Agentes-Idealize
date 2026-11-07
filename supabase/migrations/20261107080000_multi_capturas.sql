-- =============================================================================
-- Idealize AI — Multicrediário: capturas do robô de leitura  · Migração 20261107080000
-- Pedido do Diego (07/11, PODE FAZER). O robô (repositório robos-idealize, GitHub Actions) entra no Multicrediário com
-- o usuário do agente, lê os relatórios do dia (Operação e detalhes, Recebimentos e detalhes, Status Garantia) e grava
-- aqui as tabelas como vieram (cabeçalho + linhas). O cruzamento com o ADM e a tela de conferência vêm em seguida.
-- Começa só por São Vicente (loja do login atual). Só leitura no Multicrediário.
-- =============================================================================
create schema if not exists multi;
revoke all on schema multi from public;

create table multi.capturas (
  id           bigserial primary key,
  relatorio    text not null check (relatorio in ('operacao','operacao_detalhe','recebimentos','recebimentos_detalhe','garantia')),
  referencia   text not null,               -- o que identifica a tela (ex.: 'Tipo=1&Data=06/11/2026', 'G|01/10/2026-07/11/2026')
  dia          date,                        -- dia a que se refere (quando houver)
  loja         text not null default 'sao_vicente',
  cabecalho    jsonb not null default '[]',
  linhas       jsonb not null default '[]', -- [[célula, célula, ...], ...]
  capturado_em timestamptz not null default now(),
  unique (relatorio, referencia, loja)
);
create index multi_capturas_dia on multi.capturas (dia desc, relatorio);
alter table multi.capturas enable row level security; alter table multi.capturas force row level security;
do $$ begin
  revoke all on all tables in schema multi from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on all tables in schema multi from anon, authenticated'; end if;
end $$;

-- recebe uma tela lida pelo robô (substitui a leitura anterior da mesma tela)
create or replace function public.multi_receber(p_relatorio text, p_referencia text, p_dia date, p_cabecalho jsonb, p_linhas jsonb,
  p_loja text default 'sao_vicente') returns int
language plpgsql security definer set search_path = multi, pg_catalog as $$
begin
  if jsonb_typeof(coalesce(p_linhas, '[]')) <> 'array' or jsonb_array_length(coalesce(p_linhas, '[]')) > 5000 then raise exception 'linhas inválidas'; end if;
  insert into multi.capturas (relatorio, referencia, dia, loja, cabecalho, linhas)
  values (p_relatorio, left(p_referencia, 300), p_dia, coalesce(p_loja, 'sao_vicente'), coalesce(p_cabecalho, '[]'), coalesce(p_linhas, '[]'))
  on conflict (relatorio, referencia, loja) do update set dia = excluded.dia, cabecalho = excluded.cabecalho, linhas = excluded.linhas, capturado_em = now();
  return jsonb_array_length(coalesce(p_linhas, '[]'));
end $$;

-- registro da rodada (para o painel e o Supervisor)
create or replace function public.multi_rodada(p_resumo jsonb) returns void
language sql security definer set search_path = intel, pg_catalog as $$
  insert into intel.sincronizacoes (agente_id, resumo) values ('multicrediario', coalesce(p_resumo, '{}'::jsonb))
$$;

insert into core.agentes (id, nome, departamento_id, status, versao, descricao) values
  ('multicrediario', 'Conferência do Multicrediário', 'financeiro', 'ativo', '0.1.0',
   'Todo dia às 7h lê no Multicrediário (São Vicente) as vendas no crediário, os documentos de cada venda (garantia) e as parcelas recebidas, e confere com o ADM. Só leitura.')
on conflict (id) do nothing;
insert into core.principais (tipo, nome, agente_id)
select 'agente', 'Conferência do Multicrediário', 'multicrediario' where not exists (select 1 from core.principais where agente_id = 'multicrediario');

do $$ declare f text; begin
  foreach f in array array['public.multi_receber(text,text,date,jsonb,jsonb,text)', 'public.multi_rodada(jsonb)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon, authenticated', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('grant execute on function %s to service_role', f); end if;
  end loop;
end $$;
