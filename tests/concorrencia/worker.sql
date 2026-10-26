-- worker: reivindica até esvaziar; cada tarefa registra sucesso
do $$ declare x core.tarefas; n int := 0; begin
  loop
    select * into x from core.reivindicar('teste', 'WID', 60);
    exit when x.id is null;
    perform core.registrar_execucao(x.id, 'WID', 'sucesso');
    n := n + 1;
    commit;  -- cada tarefa em sua própria transação: força intercalação real entre workers
  end loop;
  raise notice 'worker % processou %', 'WID', n;
end $$;
