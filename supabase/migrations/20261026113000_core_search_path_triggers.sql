-- Fixa search_path das duas funções de trigger apontadas pelo advisor do Supabase (lint 0011).
alter function core._aud_imutavel() set search_path = core, pg_catalog;
alter function core._politica_sem_delete() set search_path = core, pg_catalog;
