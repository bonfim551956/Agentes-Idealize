-- =============================================================================
-- Idealize RH 360 — acrescenta o ANIVERSÁRIO (só dia e mês, "MM-DD") à visão de leitura dos vínculos.
-- Só aplicar com "PODE FAZER" do Diego. Não altera nenhuma tabela; o ano de nascimento continua fora.
-- Recriar a visão mantém os acessos já dados ao idealize_ai_leitor_rh.
-- =============================================================================
create or replace view idealize_ai.rh_vinculos with (security_barrier = true) as
select v.id as vinculo_id, c.nome_completo as nome, l.codigo as loja, cg.nome as cargo, v.tipo::text as tipo, v.status::text as status,
       v.data_admissao, v.data_desligamento, v.jornada_semanal_horas, v.escala,
       to_char(c.data_nascimento, 'MM-DD') as aniversario   -- só dia e mês, para o aviso de aniversário; o ano não sai
from public.vinculos v
join public.colaboradores c on c.id = v.colaborador_id
left join lateral (select lo.loja_id from public.lotacoes lo where lo.vinculo_id = v.id and lo.fim is null order by lo.inicio desc limit 1) la on true
left join public.lojas l on l.id = coalesce(la.loja_id, c.loja_atual_id)
left join public.cargos cg on cg.id = v.cargo_id;
