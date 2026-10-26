-- Índices para as chaves estrangeiras usadas na conciliação, nas pendências e no fechamento
-- (advisor de desempenho do Supabase, lint 0001). As demais FKs são de cadastro, de baixo volume.
create index if not exists conciliacoes_movimento on fin.conciliacoes (movimento_id);
create index if not exists pendencias_movimento on fin.pendencias (movimento_id) where movimento_id is not null;
create index if not exists pendencias_lancamento on fin.pendencias (lancamento_id) where lancamento_id is not null;
create index if not exists pendencias_unidade_aberta on fin.pendencias (unidade_id) where status = 'aberta';
create index if not exists lancamentos_original on fin.lancamentos (original_id) where original_id is not null;
create index if not exists lancamentos_par on fin.lancamentos (par_id) where par_id is not null;
create index if not exists lancamentos_fatura on fin.lancamentos (fatura_id) where fatura_id is not null;
create index if not exists lancamentos_documento_banco on fin.lancamentos (documento_banco) where documento_banco is not null;
create index if not exists movimentos_importacao on fin.movimentos (importacao_id);
create index if not exists movimentos_documento_banco on fin.movimentos (documento_banco) where documento_banco is not null;
create index if not exists validacoes_tarefa on core.validacoes (tarefa_id);
create index if not exists tarefa_dependencias_depende on core.tarefa_dependencias (depende_de);
