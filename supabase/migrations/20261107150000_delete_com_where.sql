-- =============================================================================
-- Idealize AI — "DELETE requires a WHERE clause"  · Migração 20261107150000
-- Achado do Diego (07/11, Enviar arquivos → "Conferi, pode lançar" no arquivo de vendas): pelo painel, o Supabase usa a
-- proteção pg_safeupdate, que recusa DELETE sem WHERE. As funções que recalculam do zero (cx/cob/atr.recalcular,
-- aplicar_lote do RH, Cobranças e Atribuição) faziam "delete from tabela;". Pelo agendador funcionava (outra conexão),
-- pelo painel não. Agora todas usam "delete from tabela where true" (mesmo efeito, aceito pela proteção).
-- A troca é feita no texto atual de cada função, sem mudar mais nada.
-- =============================================================================
do $$ declare r record; v text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('cx', 'cob', 'atr', 'rh', 'multi', 'aud', 'public') and p.prokind = 'f'
              and pg_get_functiondef(p.oid) ~* 'delete\s+from\s+[a-z_][a-z0-9_.]*\s*;' loop
    v := regexp_replace(pg_get_functiondef(r.oid), '(delete\s+from\s+[a-z_][a-z0-9_.]*)\s*;', '\1 where true;', 'gi');
    execute v;
  end loop;
end $$;
