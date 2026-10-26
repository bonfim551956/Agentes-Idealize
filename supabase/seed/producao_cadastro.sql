-- =============================================================================
-- Cadastro de produção — Grupo Idealize (sem dados pessoais; aplicar só no projeto de produção)
-- Fonte: cadastro informado pelo Diego (empresas/CNPJ, lojas) e plano de contas aprovado.
-- Regras com nomes/CPF de pessoas ficam fora do Git (dados_privados/), por LGPD.
-- Idempotente: pode ser reaplicado.
-- =============================================================================

insert into core.unidades (id, nome) values
  ('sao_vicente','São Vicente'), ('campinas','Campinas'), ('sorocaba','Sorocaba'),
  ('piracicaba','Piracicaba'), ('administrativo','Administrativo / Grupo')
on conflict (id) do nothing;

insert into fin.empresas (id, razao_social, cnpj) values
  ('idealize_litoral','Idealize Comércio Óptico do Litoral Ltda','58849594000190'),
  ('rf_silva','RF Silva Ótica ME','43331384000138'),
  ('rm_comercio','RM Comércio Ótico Ltda','51885847000131'),
  ('idealize_piracicaba','Óticas Idealize Piracicaba Ltda','66317708000189')
on conflict (id) do nothing;

insert into fin.unidade_empresa (unidade_id, empresa_id) values
  ('sao_vicente','idealize_litoral'), ('campinas','rf_silva'),
  ('sorocaba','rm_comercio'), ('piracicaba','idealize_piracicaba')
on conflict (unidade_id) do nothing;

-- Sicredi coop 0727 — 100% da loja de São Vicente (só os dígitos finais ficam registrados)
insert into fin.contas (id, apelido, tipo, unidade_id, empresa_id, instituicao, final_numero) values
  ('sicredi_sv','Sicredi São Vicente','corrente','sao_vicente','idealize_litoral','Sicredi (748)','9921')
on conflict (id) do nothing;

-- Regras de classificação do extrato — pessoas jurídicas e lançamentos do banco.
-- prioridade menor vence. padrao é trecho da descrição do banco (ILIKE).
insert into fin.regras_classificacao (padrao, sentido, natureza, categoria_id, unidade_destino, prioridade, origem, responsavel) values
  -- banco
  ('COB IOF', 'debito', 'despesa', 'juros_iof', null, 5, 'manual', 'Diego (plano de contas)'),
  ('IOF ', 'debito', 'despesa', 'juros_iof', null, 10, 'manual', 'Diego (plano de contas)'),
  ('JUROS UTILIZ', 'debito', 'despesa', 'juros_iof', null, 10, 'manual', 'Diego (plano de contas)'),
  ('SICREDI GRANDES LAGOS', 'debito', 'despesa', 'tarifas', null, 10, 'manual', 'Diego: boleto Sicredi/cesta = tarifa'),
  ('SAQUE DIN', 'debito', 'despesa', 'premios', null, 10, 'manual', 'Diego: saque em dinheiro = prêmio de colaboradores'),
  -- recebimentos
  ('STONE', 'credito', 'receita', 'vendas_cartao', null, 20, 'manual', 'Diego: Stone = vendas no cartão'),
  ('58849594000190', 'credito', 'receita', 'vendas_crediario', null, 20, 'manual', 'Diego: Idealize Comércio recebido = Asaas/Multicrédito'),
  ('66317708000189', 'credito', 'transferencia_unidades', null, 'piracicaba', 20, 'manual', 'Diego: Piracicaba recebido = repasse intercompany'),
  ('TOPOVIA', 'credito', 'receita', 'vendas_pix', null, 20, 'manual', 'Diego: Topovia = venda'),
  ('RECEBIMENTO PIX', 'credito', 'receita', 'vendas_pix', null, 900, 'manual', 'Diego: PIX recebidos = vendas'),
  -- intercompany
  ('51885847000131', 'debito', 'transferencia_unidades', null, 'sorocaba', 20, 'manual', 'Diego: R M Comércio = repasse de custos compartilhados'),
  ('43331384000138', 'debito', 'despesa', 'trafego_pago', null, 20, 'manual', 'Diego: R F E Silva = tráfego pago, mesmo em valores altos'),
  -- custo do produto
  ('19300038000108', 'debito', 'despesa', 'laboratorio', null, 30, 'manual', 'Diego: HTK = laboratório'),
  ('11511163000155', 'debito', 'despesa', 'laboratorio', null, 30, 'manual', 'Diego: Braslab = laboratório'),
  ('28826394000150', 'debito', 'despesa', 'laboratorio', null, 30, 'manual', 'Diego: Carl Zeiss = laboratório'),
  ('22485231000175', 'debito', 'despesa', 'suprimentos', null, 30, 'manual', 'Diego: ECL Estojos = suprimentos'),
  ('20524136000108', 'debito', 'despesa', 'lentes_contato', null, 30, 'manual', 'Diego: Irawo = lentes de contato'),
  ('61505310000152', 'debito', 'despesa', 'armacoes', null, 30, 'manual', 'Diego: Bity = armações'),
  ('66214493000170', 'debito', 'despesa', 'armacoes', null, 30, 'manual', 'Diego: MDT = armações'),
  -- pessoal / benefícios / impostos
  ('02535864', 'debito', 'despesa', 'beneficios', null, 30, 'manual', 'Diego: VR = benefício'),
  ('02661037000196', 'debito', 'despesa', 'exames', null, 30, 'manual', 'Diego: Clínica Boa Vista = exame'),
  ('00394460005887', 'debito', 'despesa', 'impostos', null, 30, 'manual', 'Diego: Receita Federal = impostos'),
  ('00360305000104', 'debito', 'despesa', 'fgts', null, 30, 'manual', 'Diego: CEF Matriz = FGTS'),
  -- marketing
  ('06990590000123', 'debito', 'despesa', 'google_ads', null, 30, 'manual', 'Diego: Google = Google Ads'),
  ('68886125000102', 'debito', 'despesa', 'trafego_pago', null, 30, 'manual', 'Diego: M S Santos = gestora de tráfego'),
  ('21902826000116', 'debito', 'despesa', 'grafica', null, 30, 'manual', 'Diego: 360 Imprimir = gráfica'),
  -- ocupação
  ('X114', 'debito', 'despesa', 'iptu', null, 30, 'manual', 'Diego: X114 = IPTU'),
  ('SABESP', 'debito', 'despesa', 'agua_luz_telefone', null, 30, 'manual', 'Diego: Sabesp = conta da loja'),
  ('02558157000162', 'debito', 'despesa', 'agua_luz_telefone', null, 30, 'manual', 'Diego: Vivo = conta da loja'),
  ('40432544000147', 'debito', 'despesa', 'agua_luz_telefone', null, 30, 'manual', 'Claro = telefone (a confirmar)'),
  ('09614276000134', 'debito', 'despesa', 'agua_luz_telefone', null, 30, 'manual', 'Diego: M4 = recarga de celular'),
  ('clubdaagua', 'debito', 'despesa', 'agua_luz_telefone', null, 30, 'manual', 'Diego: clubdaagua = empresa de água'),
  ('10382371000139', 'debito', 'despesa', 'aluguel', null, 30, 'manual', 'Diego: Venturine = aluguel'),
  ('12326372000191', 'debito', 'despesa', 'limpeza', null, 30, 'manual', 'Diego: Eco Soluções = produtos de limpeza'),
  -- sistemas / administrativo
  ('11867482000106', 'debito', 'despesa', 'sistemas', null, 30, 'manual', 'Diego: Atual Original = Acert'),
  ('63629889000190', 'debito', 'despesa', 'sistemas', null, 30, 'manual', 'Diego: Optovision = sistema de receitas'),
  ('61942370000132', 'debito', 'despesa', 'seguranca', null, 30, 'manual', 'Diego: Zaga = segurança'),
  ('08776918000139', 'debito', 'despesa', 'sistemas', null, 30, 'manual', 'Diego: Credtech = Multicrédito (categoria a confirmar)'),
  ('ANTHROPIC', 'debito', 'despesa', 'ia', null, 30, 'manual', 'Diego: Anthropic = ferramentas de IA'),
  ('09664937000136', 'debito', 'despesa', 'contabilidade', null, 30, 'manual', 'Diego: Organização Contábil = contabilidade'),
  ('DLKNET', 'debito', 'despesa', 'correios', null, 30, 'manual', 'Diego: DLKNET = Correios'),
  ('CasaLuanda', 'debito', 'despesa', 'reunioes', null, 30, 'manual', 'Diego: CasaLuanda = café para reunião');
