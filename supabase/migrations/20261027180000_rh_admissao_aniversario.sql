-- =============================================================================
-- Idealize AI — RH: avisos de NOVA ADMISSÃO e ANIVERSÁRIO  · Migração 20261027180000
-- Nova admissão: pré-admissão ou admissão até 7 dias antes/depois de hoje (documentos, exame admissional, contabilidade).
-- Aniversário: avisa 7 dias antes. Do nascimento só entra DIA e MÊS ("MM-DD"); o ano nunca é lido do RH 360.
-- Experiência (decisão do Diego, 27/10): 15 + 15 dias para todos os cargos; CONSULTOR(A) ÓPTICO: 15 + 30.
-- Marcos = fim do 1º período e fim da prorrogação (dias corridos desde a admissão); aviso 5 dias antes.
-- =============================================================================
alter table rh.vinculos add column if not exists aniversario text
  check (aniversario is null or aniversario ~ '^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$');

-- com períodos de 15 dias, avisar 10 dias antes seria cedo demais: passa para 5 (se ainda estiver no padrão antigo)
update core.config set valor = '5', atualizado_em = now() where chave = 'rh.experiencia_aviso_dias' and valor = '10';

-- marcos da experiência por cargo: {fim do 1º período, fim da prorrogação}, em dias corridos desde a admissão
create or replace function rh._marcos_experiencia(p_cargo text) returns int[]
language plpgsql stable security definer set search_path = core, pg_catalog as $$
declare k text := regexp_replace(regexp_replace(translate(upper(coalesce(p_cargo, '')), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'AAAAAEEEEIIIIOOOOOUUUUC'),
    '\([^)]*\)', '', 'g'), '[^A-Z]', '', 'g');   -- "CONSULTOR(A) ÓPTICO" → CONSULTOROPTICO
  r text; p text := core.cfg('rh.experiencia_periodos', '15,15'); a int; b int;
begin
  foreach r in array string_to_array(core.cfg('rh.experiencia_periodos_cargo', ''), ';') loop
    if k <> '' and split_part(r, '=', 1) <> '' and k = regexp_replace(upper(split_part(r, '=', 1)), '[^A-Z]', '', 'g') then
      p := split_part(r, '=', 2); exit;
    end if;
  end loop;
  begin
    a := split_part(p, ',', 1)::int; b := split_part(p, ',', 2)::int;
  exception when others then a := 15; b := 15;
  end;
  if a is null or a < 1 or a > 90 then a := 15; end if;
  if b is null or b < 0 or a + b > 90 then b := 15; end if;   -- CLT: no máximo 90 dias no total
  return array[a, a + b];
end $$;
revoke all on function rh._marcos_experiencia(text) from public;

alter table rh.alertas drop constraint if exists alertas_tipo_check;
alter table rh.alertas add constraint alertas_tipo_check check (tipo in ('fim_experiencia','experiencia_vencida','ferias_limite',
  'ferias_vencidas','exame_vencendo','desligamento_prazo','tarefa_atrasada','jornada_irregular','uniforme_baixo','nova_admissao','aniversario'));

insert into core.config (chave, valor) values
  ('rh.experiencia_periodos', '15,15'),                          -- 1º período, prorrogação (dias)
  ('rh.experiencia_periodos_cargo', 'CONSULTOROPTICO=15,30'),    -- cargo (só letras, sem acento) = períodos; vários com ";"
  ('rh.admissao_aviso_dias', '7'),
  ('rh.aniversario_aviso_dias', '7')
on conflict (chave) do nothing;

create or replace function rh.recalcular() returns jsonb
language plpgsql security definer set search_path = rh, core, pg_catalog as $$
declare d date := rh._hoje(); v_exp int := rh._cfg_int('rh.experiencia_aviso_dias', 10);
  v_fer int := rh._cfg_int('rh.ferias_aviso_dias', 90); v_exa int := rh._cfg_int('rh.exame_aviso_dias', 30);
  v_ace int := rh._cfg_int('rh.acerto_prazo_dias', 10); v_jor int := rh._cfg_int('rh.jornada_max_semanal', 44);
  v_adm int := rh._cfg_int('rh.admissao_aviso_dias', 7); v_ani int := rh._cfg_int('rh.aniversario_aviso_dias', 7);
  n_ab int; n_res int;
begin
  drop table if exists _devidos;
  create temp table _devidos (tipo text, referencia text, unidade_id text, prazo date, detalhe jsonb) on commit drop;

  -- contrato de experiência: fim do 1º período (45 dias) e do total (90 dias)
  insert into _devidos
  select 'fim_experiencia', 'vinculo:' || v.id || ':' || m.dias, v.unidade_id, (v.admissao + m.dias - 1),
         jsonb_build_object('nome', v.nome, 'cargo', v.cargo, 'marco_dias', m.dias, 'periodo', m.n, 'total_dias', p.mc[cardinality(p.mc)],
                            'admissao', v.admissao, 'termina', v.admissao + m.dias - 1)
  from rh.vinculos v
  cross join lateral (select rh._marcos_experiencia(v.cargo) mc) p
  cross join lateral unnest(p.mc) with ordinality m(dias, n)
  where v.tipo = 'clt_experiencia' and v.status in ('ativo','em_ferias','afastado','em_licenca') and v.admissao is not null
    and (v.admissao + m.dias - 1) between d and d + v_exp;
  insert into _devidos
  select 'experiencia_vencida', 'vinculo:' || v.id, v.unidade_id, (v.admissao + p.total - 1),
         jsonb_build_object('nome', v.nome, 'cargo', v.cargo, 'admissao', v.admissao, 'total_dias', p.total, 'terminou', v.admissao + p.total - 1)
  from rh.vinculos v
  cross join lateral (select (rh._marcos_experiencia(v.cargo))[2] total) p
  where v.tipo = 'clt_experiencia' and v.status in ('ativo','em_ferias','afastado','em_licenca') and v.admissao + p.total - 1 < d;

  -- férias: período aquisitivo completo com dias faltando e limite chegando (ou já passado)
  insert into _devidos
  select case when p.limite_concessao < d then 'ferias_vencidas' else 'ferias_limite' end,
         'vinculo:' || p.vinculo_id || ':' || p.aquisitivo_inicio, p.unidade_id, p.limite_concessao,
         jsonb_build_object('nome', p.nome, 'aquisitivo_inicio', p.aquisitivo_inicio, 'aquisitivo_fim', p.aquisitivo_fim,
                            'limite', p.limite_concessao, 'dias_registrados', p.dias_registrados, 'dias_faltando', 30 - p.dias_registrados)
  from rh.v_periodos_ferias p
  where p.aquisitivo_fim < d and p.dias_registrados < 30 and p.limite_concessao <= d + v_fer;
  -- férias registradas fora do prazo (já gozadas depois do limite): pagamento em dobro a conferir
  insert into _devidos
  select 'ferias_vencidas', 'vinculo:' || p.vinculo_id || ':' || p.aquisitivo_inicio || ':fora', p.unidade_id, p.limite_concessao,
         jsonb_build_object('nome', p.nome, 'aquisitivo_inicio', p.aquisitivo_inicio, 'aquisitivo_fim', p.aquisitivo_fim,
                            'limite', p.limite_concessao, 'dias_fora_do_prazo', p.dias_fora_do_prazo)
  from rh.v_periodos_ferias p where p.dias_fora_do_prazo > 0 and p.limite_concessao >= d - 365;

  -- exame ocupacional (e outros documentos com validade) vencendo ou vencido
  insert into _devidos
  select 'exame_vencendo', 'documento:' || dv.id, v.unidade_id, dv.vencimento,
         jsonb_build_object('nome', v.nome, 'categoria', dv.categoria, 'vencimento', dv.vencimento, 'vencido', dv.vencimento < d)
  from rh.documentos_vencimento dv join rh.vinculos v on v.id = dv.vinculo_id
  where v.status not in ('desligado','arquivado') and coalesce(dv.status, '') not in ('arquivado')
    and dv.vencimento <= d + v_exa
    and not exists (select 1 from rh.documentos_vencimento n where n.vinculo_id = dv.vinculo_id and n.categoria = dv.categoria and n.vencimento > dv.vencimento);

  -- desligamento sem acerto concluído perto do prazo legal
  insert into _devidos
  select 'desligamento_prazo', 'desligamento:' || dl.id, v.unidade_id, dl.desligamento + v_ace,
         jsonb_build_object('nome', v.nome, 'modalidade', dl.modalidade, 'desligamento', dl.desligamento, 'prazo_acerto', dl.desligamento + v_ace)
  from rh.desligamentos dl join rh.vinculos v on v.id = dl.vinculo_id
  where not dl.concluido and dl.desligamento is not null and dl.desligamento + v_ace <= d + 3;

  -- tarefa do RH 360 atrasada
  insert into _devidos
  select 'tarefa_atrasada', 'tarefa:' || t.id, t.unidade_id, t.prazo,
         jsonb_build_object('titulo', t.titulo, 'categoria', t.categoria, 'prazo', t.prazo, 'prioridade', t.prioridade)
  from rh.tarefas t
  where t.prazo < d and coalesce(lower(t.status), '') not in ('concluida','concluída','cancelada','feito','concluido');

  -- jornada acima do limite, sem jornada ou sem escala definida
  insert into _devidos
  select 'jornada_irregular', 'vinculo:' || v.id, v.unidade_id, null,
         jsonb_build_object('nome', v.nome, 'cargo', v.cargo, 'jornada', v.jornada_semanal, 'escala', v.escala,
                            'motivo', case when v.jornada_semanal > v_jor then 'acima' when v.jornada_semanal is null then 'sem_jornada' else 'sem_escala' end)
  from rh.vinculos v
  where v.status in ('ativo','em_ferias','afastado','em_licenca') and v.tipo like 'clt%'
    and (v.jornada_semanal > v_jor or v.jornada_semanal is null or coalesce(btrim(v.escala), '') in ('', 'DAS 00:00 AS 00:00'));

  -- nova admissão: quem está em pré-admissão ou começou/começa perto de hoje (documentos, exame admissional, contabilidade)
  insert into _devidos
  select 'nova_admissao', 'vinculo:' || v.id, v.unidade_id, v.admissao,
         jsonb_build_object('nome', v.nome, 'cargo', v.cargo, 'admissao', v.admissao, 'pre_admissao', v.status = 'pre_admissao')
  from rh.vinculos v
  where v.status = 'pre_admissao'
     or (v.status in ('ativo','em_ferias','afastado','em_licenca') and v.admissao between d - v_adm and d + v_adm);

  -- aniversário nos próximos dias (só dia e mês; o ano de nascimento não é lido)
  insert into _devidos
  select 'aniversario', 'vinculo:' || v.id || ':' || extract(year from x.dia), v.unidade_id, x.dia,
         jsonb_build_object('nome', v.nome, 'cargo', v.cargo, 'dia', to_char(x.dia, 'DD/MM'), 'hoje', x.dia = d)
  from rh.vinculos v
  cross join lateral (
    select min(c) dia from (
      select make_date(y, split_part(v.aniversario, '-', 1)::int,
               least(split_part(v.aniversario, '-', 2)::int,
                     extract(day from (make_date(y, split_part(v.aniversario, '-', 1)::int, 1) + interval '1 month - 1 day'))::int)) c
      from unnest(array[extract(year from d)::int, extract(year from d)::int + 1]) y) z
    where c >= d) x
  where v.aniversario is not null and v.status in ('ativo','em_ferias','afastado','em_licenca','pre_admissao')
    and x.dia <= d + v_ani;

  -- uniforme abaixo do estoque mínimo
  insert into _devidos
  select 'uniforme_baixo', 'uniforme:' || u.id, null, null,
         jsonb_build_object('peca', u.peca, 'tamanho', u.tamanho, 'saldo', u.saldo, 'minimo', u.minimo)
  from rh.uniformes u where u.saldo < u.minimo;

  insert into rh.alertas (tipo, referencia, unidade_id, prazo, detalhe)
  select tipo, referencia, unidade_id, prazo, detalhe from _devidos
  on conflict (tipo, referencia) where status = 'aberto'
  do update set detalhe = excluded.detalhe, unidade_id = excluded.unidade_id, prazo = excluded.prazo;
  get diagnostics n_ab = row_count;

  update rh.alertas a set status = 'resolvido', resolvido_em = now(), resolvido_por = 'agente_rh: situação deixou de existir'
   where a.status = 'aberto' and not exists (select 1 from _devidos x where x.tipo = a.tipo and x.referencia = a.referencia);
  get diagnostics n_res = row_count;
  return jsonb_build_object('ativos', n_ab, 'resolvidos', n_res);
end $$;

create or replace function rh.aplicar_lote(p_tarefa uuid, p_lote jsonb) returns jsonb
language plpgsql security definer set search_path = rh, core, pg_catalog as $$
declare v_s uuid := gen_random_uuid(); n_v int; n_f int; n_o int := 0; n int; n_ign int; v_al jsonb;
begin
  if jsonb_typeof(p_lote) is distinct from 'object' or jsonb_typeof(p_lote->'vinculos') is distinct from 'array' then
    raise exception 'lote sem vínculos do RH 360';
  end if;
  if jsonb_array_length(p_lote->'vinculos') = 0 and exists (select 1 from rh.vinculos) then
    raise exception 'lote veio vazio e o espelho tem pessoas: leitura suspeita, nada foi apagado';
  end if;

  delete from rh.mudancas; delete from rh.documentos_vencimento; delete from rh.desligamentos; delete from rh.ferias;
  delete from rh.vinculos; delete from rh.tarefas; delete from rh.uniformes;

  insert into rh.vinculos (id, nome, unidade_id, cargo, tipo, status, admissao, desligamento, jornada_semanal, escala, aniversario, sincronizacao_id)
  select r.vinculo_id, left(btrim(r.nome), 120), o.unidade_id, left(r.cargo, 80), lower(r.tipo), lower(r.status), r.data_admissao,
         r.data_desligamento, r.jornada_semanal_horas, left(r.escala, 120),
         case when r.aniversario ~ '^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' then r.aniversario end, v_s
  from jsonb_to_recordset(p_lote->'vinculos') r(vinculo_id text, nome text, loja text, cargo text, tipo text, status text,
    data_admissao date, data_desligamento date, jornada_semanal_horas numeric, escala text, aniversario text)
  left join rh.lojas_origem o on o.origem = upper(r.loja)
  where coalesce(r.vinculo_id, '') ~ '^[A-Za-z0-9_-]{1,64}$' and coalesce(btrim(r.nome), '') <> '' and r.tipo is not null and r.status is not null
  on conflict (id) do nothing;
  get diagnostics n_v = row_count;
  n_ign := jsonb_array_length(p_lote->'vinculos') - n_v;

  insert into rh.ferias (id, vinculo_id, inicio, fim, aquisitivo_inicio, aquisitivo_fim, programada)
  select r.id, r.vinculo_id, r.inicio, r.fim, r.aquisitivo_inicio, r.aquisitivo_fim, coalesce(r.programada, false)
  from jsonb_to_recordset(coalesce(p_lote->'ferias', '[]')) r(id text, vinculo_id text, inicio date, fim date, aquisitivo_inicio date,
    aquisitivo_fim date, programada boolean)
  where exists (select 1 from rh.vinculos v where v.id = r.vinculo_id) and r.inicio is not null and r.fim >= r.inicio and r.fim - r.inicio < 60
  on conflict (id) do nothing;
  get diagnostics n_f = row_count;

  insert into rh.desligamentos (id, vinculo_id, modalidade, comunicacao, desligamento, status, concluido)
  select r.id, r.vinculo_id, left(r.modalidade, 40), r.data_comunicacao, r.data_desligamento, left(r.status, 30),
         r.concluido_em is not null or lower(coalesce(r.status, '')) in ('concluido','concluído','finalizado')
  from jsonb_to_recordset(coalesce(p_lote->'desligamentos', '[]')) r(id text, vinculo_id text, modalidade text, data_comunicacao date,
    data_desligamento date, status text, concluido_em timestamptz)
  where exists (select 1 from rh.vinculos v where v.id = r.vinculo_id) on conflict (id) do nothing;
  get diagnostics n = row_count; n_o := n_o + n;

  insert into rh.tarefas (id, titulo, categoria, unidade_id, prazo, prioridade, status)
  select r.id, left(btrim(r.titulo), 200), left(r.categoria, 40), o.unidade_id, r.prazo, left(r.prioridade, 20), left(r.status, 30)
  from jsonb_to_recordset(coalesce(p_lote->'tarefas', '[]')) r(id text, titulo text, categoria text, loja text, prazo date, prioridade text, status text)
  left join rh.lojas_origem o on o.origem = upper(r.loja)
  where coalesce(r.id, '') <> '' and coalesce(btrim(r.titulo), '') <> '' on conflict (id) do nothing;
  get diagnostics n = row_count; n_o := n_o + n;

  insert into rh.documentos_vencimento (id, vinculo_id, categoria, vencimento, status)
  select r.id, r.vinculo_id, left(r.categoria, 40), r.vencimento, left(r.status, 30)
  from jsonb_to_recordset(coalesce(p_lote->'documentos', '[]')) r(id text, vinculo_id text, categoria text, vencimento date, status text)
  where exists (select 1 from rh.vinculos v where v.id = r.vinculo_id) and r.vencimento is not null and r.categoria is not null
  on conflict (id) do nothing;
  get diagnostics n = row_count; n_o := n_o + n;

  insert into rh.mudancas (id, vinculo_id, tipo, data)
  select r.id, r.vinculo_id, r.tipo, r.data
  from jsonb_to_recordset(coalesce(p_lote->'mudancas', '[]')) r(id text, vinculo_id text, tipo text, data date)
  where exists (select 1 from rh.vinculos v where v.id = r.vinculo_id) and r.tipo in ('cargo','salario') and r.data is not null
  on conflict (id) do nothing;
  get diagnostics n = row_count; n_o := n_o + n;

  insert into rh.uniformes (id, peca, tamanho, minimo, saldo)
  select r.id, left(r.peca, 80), left(r.tamanho, 20), coalesce(r.estoque_minimo, 0), coalesce(r.saldo, 0)
  from jsonb_to_recordset(coalesce(p_lote->'uniformes', '[]')) r(id text, peca text, tamanho text, estoque_minimo int, saldo int)
  where coalesce(r.id, '') <> '' and coalesce(r.peca, '') <> '' on conflict (id) do nothing;
  get diagnostics n = row_count; n_o := n_o + n;

  v_al := rh.recalcular();
  insert into rh.sincronizacoes (id, tarefa_id, vinculos, ativos, ferias, outros, ignoradas, alertas_abertos, alertas_resolvidos, hash_lote)
  values (v_s, p_tarefa, n_v, (select count(*) from rh.vinculos where status in ('ativo','em_ferias','afastado','em_licenca')), n_f, n_o, n_ign,
    (v_al->>'ativos')::int, (v_al->>'resolvidos')::int, md5(p_lote::text));
  return jsonb_build_object('sincronizacao', v_s, 'vinculos', n_v, 'ferias', n_f, 'outros', n_o, 'ignoradas', n_ign,
    'alertas', v_al, 'hash_lote', md5(p_lote::text));
end $$;
