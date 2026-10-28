-- =============================================================================
-- Idealize AI — conserto em fin.arquivos_faltando()  · Migração 20261028030000
-- Achado na instalação (28/10): ao conferir as importações da conta do extrato, "conta_id" era ambíguo (coluna da
-- tabela × campo de saída da função) e a consulta falhava — derrubando a tela de envio e a verificação do Supervisor.
-- Única mudança: a coluna passa a ser qualificada (i.conta_id).
-- =============================================================================
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
      select max(i.periodo_fim) into v_cob from fin.importacoes i where i.conta_id = a.conta_id;
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
