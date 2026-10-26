-- Etapas do kanban confirmadas pelo Diego em 26/10/2026; "Aguardando lentes" passa a ser parado após 4 dias.
-- A coluna 8 (2 cartões) continua sem nome e segue gerando alerta "Coluna do kanban sem nome".
update lab.etapas set confirmada = true where col between 0 and 7;
update lab.etapas set parado_dias = 4 where col = 1;
