// Supabase falso para testes de navegador: Auth (senha + TOTP) e as RPCs painel_*. Dados 100% sintéticos.
import type { Page, Route } from "@playwright/test";

export const BASE = "https://mock.supabase.test";
const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
export const jwt = (aal: "aal1" | "aal2") =>
  `${b64({ alg: "HS256", typ: "JWT" })}.${b64({
    sub: "00000000-0000-0000-0000-0000000000d1", role: "authenticated", aal, exp: Math.floor(Date.now() / 1000) + 3600,
    amr: aal === "aal2" ? [{ method: "password", timestamp: 1 }, { method: "totp", timestamp: 2 }] : [{ method: "password", timestamp: 1 }],
    email: "diego@teste.local", session_id: "s1",
  })}.assinatura`;

const fator = { id: "f1", factor_type: "totp", status: "verified", friendly_name: "Painel Idealize", created_at: "2026-10-01T00:00:00Z", updated_at: "2026-10-01T00:00:00Z" };
export const usuario = (comFator = true) => ({
  id: "00000000-0000-0000-0000-0000000000d1", aud: "authenticated", role: "authenticated", email: "diego@teste.local",
  app_metadata: {}, user_metadata: {}, created_at: "2026-10-01T00:00:00Z", factors: comFator ? [fator] : [],
});
const sessao = (aal: "aal1" | "aal2", comFator = true) => ({
  access_token: jwt(aal), token_type: "bearer", expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600,
  refresh_token: "r1", user: usuario(comFator),
});

const agora = Date.now();
const ha = (min: number) => new Date(agora - min * 60_000).toISOString();
export const HASH = "7c1e9a0b42d3f5e6a7b8c9d0e1f20314253647586970a1b2c3d4e5f607182930";

export const EU_ADMIN = {
  nome: "Diego Teste", aal2: true,
  papeis: [{ papel: "admin", unidade: null }, { papel: "diretoria", unidade: null }],
  unidades: [{ id: "campinas", nome: "Campinas" }, { id: "piracicaba", nome: "Piracicaba" }, { id: "sao_vicente", nome: "São Vicente" }, { id: "sorocaba", nome: "Sorocaba" }],
  pode: { consultar: true, consultar_global: true, auditoria: true, administrar: true, pausar_plataforma: true,
    tratar_incidente: true, reconciliar: true, cancelar_tarefa: true, tratar_pendencia: true },
};
export const EU_GERENTE = {
  ...EU_ADMIN, nome: "Gerente Teste", papeis: [{ papel: "gerente", unidade: "sorocaba" }], unidades: [{ id: "sorocaba", nome: "Sorocaba" }],
  pode: { consultar: true, consultar_global: false, auditoria: false, administrar: false, pausar_plataforma: false,
    tratar_incidente: false, reconciliar: false, cancelar_tarefa: false, tratar_pendencia: false },
};

const tarefa = (id: string, status: string, extra: Record<string, unknown> = {}) => ({
  id, agente_id: "financeiro", tipo: "whatsapp_comprovante", recurso: "fin.lancamento", operacao: "registrar_comprovante",
  unidade_id: "sao_vicente", valor: 350, status, prioridade: 5, risco: "baixo", categoria: "automatica", tentativas: 1,
  prazo: null, atrasada: false, motivo: null, criado_em: ha(90), atualizado_em: ha(30), ...extra,
});

export const RPC: Record<string, unknown> = {
  painel_eu: EU_ADMIN,
  painel_resumo: {
    plataforma_pausada: false, agentes: { pausado: 1 }, tarefas: { concluida: 41, aguardando_aprovacao: 1, incerta: 1 },
    tarefas_24h: 6, atrasadas: 0, aprovacoes_pendentes: 1, incidentes: { alta: 1, baixa: 1 }, falhas_recorrentes: 0,
    pendencias_fin: { abertas: 3, materiais: 2 }, custo_mes: { confirmado: 0, estimado: 1.84 },
    integracoes: { ok: 2, nao_verificada: 8 }, canal_whatsapp: { ativo: false, responder: false }, auditoria: { integra: true, em: ha(120) }, gerado_em: ha(0),
  },
  painel_agentes: [{
    id: "financeiro", nome: "Agente Financeiro", departamento: "financeiro", status: "pausado", versao: "0.4.0",
    descricao: "Comprovantes, extratos, conciliação, fluxo de caixa e preparação do fechamento. Não movimenta dinheiro.",
    limite_custo_mensal: 50, ultima_atividade: ha(30),
    tarefas: { concluidas: 41, em_andamento: 0, aguardando_aprovacao: 1, bloqueadas: 0, incertas: 1, falhas: 0, atrasadas: 0 },
    periodo_dias: 30, execucoes: 44, tempo_medio_s: 8.4, taxa_sucesso: 0.9545, erros: 2, taxa_retrabalho: 0.0455, aprovacoes_solicitadas: 1,
    custo_mes: { confirmado: 0, estimado: 1.84 }, tokens_mes: { entrada: 182000, saida: 9100 }, incidentes_abertos: 1,
    economia_estimada: null, economia_confirmada: null, disponibilidade: null,
  }],
  painel_aprovacoes: [{
    id: "00000000-0000-0000-0000-00000000aa01", agente_id: "financeiro", tipo: "ajuste", recurso: "fin.lancamento", operacao: "registrar_ajuste",
    unidade_id: "sao_vicente", valor: 4165.55, risco: "alto", prioridade: 3, motivo: "Fatura do cartão sem compras lançadas",
    payload: { conta: "cartao_sicredi_sv", competencia: "2026-10-01", descricao: "Pagamento de fatura de cartão" },
    hash_operacao: HASH, criado_em: ha(45), solicitante: "Agente Financeiro", papel_aprovador: "diretoria",
    aprovadores_minimos: 1, aprovacoes_validas: 0, pode_aprovar: true,
  }],
  painel_tarefas: [
    tarefa("00000000-0000-0000-0000-00000000aa01", "aguardando_aprovacao", { valor: 4165.55, operacao: "registrar_ajuste", categoria: "aprovacao", risco: "alto" }),
    tarefa("00000000-0000-0000-0000-00000000aa02", "incerta", { motivo: "execução interrompida: verificar se o efeito externo ocorreu" }),
    tarefa("00000000-0000-0000-0000-00000000aa03", "concluida"),
  ],
  painel_tarefa: {
    tarefa: { ...tarefa("00000000-0000-0000-0000-00000000aa02", "incerta", { motivo: "execução interrompida: verificar se o efeito externo ocorreu" }),
      correlacao_id: "c1", max_tentativas: 3, proximo_em: ha(20), executor: "fin-worker",
      payload: { mensagem: "******0001", favorecido: "LAB TESTE", valor: 350 }, resultado: null, hash_operacao: HASH, solicitante: "Rafael" },
    politica: { id: 12, versao: 1, risco: "baixo", categoria: "automatica", aprovadores_minimos: 1, papel_aprovador: null, limite_valor: null },
    execucoes: [{ tentativa: 1, executor: "fin-worker", status: "lease_expirado", inicio_em: ha(25), fim_em: ha(22), efeito_externo_id: null, erro: null, evidencia: null }],
    validacoes: [], aprovacoes: [], dependencias: [],
    incidentes: [{ id: 7, titulo: "Tarefa em estado incerto", severidade: "alta", status: "aberto", ocorrencias: 1 }],
    historico: [
      { id: 101, em: ha(90), acao: "tarefa_criada", ator: "Rafael", antes: null, depois: { status: "pronta" }, motivo: null },
      { id: 102, em: ha(25), acao: "tarefa_status", ator: "fin-worker", antes: { status: "pronta" }, depois: { status: "executando" }, motivo: null },
      { id: 103, em: ha(22), acao: "tarefa_status", ator: null, antes: { status: "executando" }, depois: { status: "incerta" }, motivo: "execução interrompida" },
    ],
    pode: { aprovar: false, reconciliar: true, cancelar: false },
  },
  painel_incidentes: [
    { id: 7, chave: "incerta:aa02", severidade: "alta", status: "aberto", titulo: "Tarefa em estado incerto", agente_id: "financeiro", integracao_id: null,
      tarefa_id: "00000000-0000-0000-0000-00000000aa02", unidade_id: "sao_vicente", ocorrencias: 1, escalonado: false,
      primeira_em: ha(22), ultima_em: ha(22), resolvido_em: null, detalhes: null, pode_tratar: true },
    { id: 8, chave: "custo:financeiro", severidade: "baixa", status: "aberto", titulo: "Consumo do agente em 80% do limite mensal", agente_id: "financeiro",
      integracao_id: null, tarefa_id: null, unidade_id: null, ocorrencias: 3, escalonado: false, primeira_em: ha(3000), ultima_em: ha(60), resolvido_em: null, detalhes: null, pode_tratar: true },
  ],
  painel_pendencias: [
    { id: 31, tipo: "fatura_divergente", unidade_id: "sao_vicente", material: true, referencia: "fatura-out", detalhe: { total_fatura: 4165.55, compras_lancadas: 0 },
      criado_em: ha(600), lancamento: { numero: 188, valor: 4165.55, natureza: "pagamento_fatura", sentido: "saida", categoria_id: null, data_competencia: "2026-10-23", descricao: "Boleto Sicredi" },
      movimento: null, pode_tratar: true, pode_aceitar: true },
    { id: 32, tipo: "sem_classificacao", unidade_id: "sao_vicente", material: true, referencia: "", detalhe: null, criado_em: ha(1200), lancamento: null,
      movimento: { data: "2026-10-20", valor: 19.2, sentido: "debito", conta_id: "sicredi_sv", descricao: "PIX ENVIADO DGFIN ******8909" }, pode_tratar: true, pode_aceitar: true },
    { id: 33, tipo: "divergencia", unidade_id: "campinas", material: false, referencia: "", detalhe: { diferenca: 0.02 }, criado_em: ha(2000), lancamento: null, movimento: null, pode_tratar: true, pode_aceitar: true },
  ],
  painel_financeiro: {
    competencia: "2026-10-01",
    unidades: [
      { id: "campinas", nome: "Campinas", receitas: 0, despesas: 0, resultado: 0, caixa_entradas: 0, caixa_saidas: 0, pendencias_abertas: 1, pendencias_materiais: 0, fechamento: null },
      { id: "sao_vicente", nome: "São Vicente", receitas: 100295.77, despesas: 118669.87, resultado: -18374.1, caixa_entradas: 96120.1, caixa_saidas: 118659.75,
        pendencias_abertas: 2, pendencias_materiais: 2,
        fechamento: { id: "fe1", status: "validado", versao: 1, pendencias_materiais: 0, pacote_hash: HASH, preparado_por: "agente_financeiro", validado_por: "validador_sql", decidido_em: null, criado_em: ha(100) } },
    ],
    consolidado: { receitas: 100295.77, despesas: 118669.87, caixa_entradas: 96120.1, caixa_saidas: 118659.75 },
  },
  painel_dre: [
    { natureza: "receita", grupo: "Receita de vendas", categoria_id: "vendas_cartao", categoria: "Vendas no cartão", valor: 71230.4, tem_rateio: false },
    { natureza: "receita", grupo: "Receita de vendas", categoria_id: "vendas_pix", categoria: "Vendas no PIX", valor: 29065.37, tem_rateio: false },
    { natureza: "despesa", grupo: "Pessoal", categoria_id: "folha", categoria: "Folha", valor: 38200, tem_rateio: false },
    { natureza: "despesa", grupo: "Custo do produto", categoria_id: "laboratorio", categoria: "Laboratório", valor: 21480.5, tem_rateio: false },
  ],
  painel_custos: {
    inicio: "2026-10-01", fim: "2026-10-26", total: { confirmado: 0, estimado: 1.84, registros: 44 },
    por: { agente: [{ chave: "financeiro", confirmado: 0, estimado: 1.84, tokens_entrada: 182000, tokens_saida: 9100, registros: 44 }],
      modelo: [{ chave: "claude-sonnet-5-5", confirmado: 0, estimado: 1.84, tokens_entrada: 182000, tokens_saida: 9100, registros: 44 }] },
    limites: [{ agente_id: "financeiro", nome: "Agente Financeiro", limite: 50, consumo_mes: 1.84, percentual: 3.7 }],
  },
  painel_auditoria: [
    { id: 903, em: ha(5), acao: "aprovacao_aprovar", entidade: "tarefa", entidade_id: "00000000-0000-0000-0000-00000000aa09", ator: "Diego Teste",
      antes: null, depois: { canal: "painel" }, motivo: "ok", hash: "1f2e3d4c5b6a7980" },
    { id: 902, em: ha(60), acao: "pendencia_resolvida", entidade: "fin.pendencia", entidade_id: "29", ator: "Rafael",
      antes: { status: "aberta" }, depois: { status: "resolvida" }, motivo: "classificado como laboratório", hash: "0a1b2c3d4e5f6071" },
  ],
  painel_auditoria_verificar: { integra: true, primeiro_adulterado: null, eventos: 1288, verificado_em: ha(0) },
  painel_operacao: {
    integracoes: [
      { id: "zapi", nome: "Z-API (WhatsApp)", status: "ok", escrita_habilitada: false, ultimo_ok_em: null, observacoes: "Em uso pelo Finance AI atual" },
      { id: "kommo", nome: "Kommo CRM", status: "nao_verificada", escrita_habilitada: false, ultimo_ok_em: null, observacoes: "Credencial não verificada" },
    ],
    chaves: { plataforma_pausada: false, fin_whatsapp_ativo: false, fin_whatsapp_responder: false },
    versoes: { componentes: { versao_fundacao: "0.1.0", versao_painel: "0.5.0" }, agentes: { financeiro: "0.4.0" },
      migracoes: [{ versao: "20261026170000", nome: "painel_acesso" }, { versao: "20261026160000", nome: "fin_whatsapp" }] },
    agendamentos: { cron: null, tarefas_futuras: 0, proxima_tarefa_em: null },
  },
  painel_usuarios: {
    principais: [
      { id: "p1", tipo: "usuario", nome: "Diego Teste", ativo: true, vinculado: true, eu: true, agente_id: null, telefone: "••••7862", papeis: [{ papel: "admin", unidade: null, valido_ate: null }, { papel: "diretoria", unidade: null, valido_ate: null }] },
      { id: "p2", tipo: "usuario", nome: "Rafael", ativo: true, vinculado: false, eu: false, agente_id: null, telefone: "••••5114", papeis: [{ papel: "financeiro", unidade: "sao_vicente", valido_ate: null }, { papel: "financeiro", unidade: "campinas", valido_ate: null }] },
      { id: "p3", tipo: "agente", nome: "Agente Financeiro", ativo: true, vinculado: false, eu: false, agente_id: "financeiro", telefone: null, papeis: [{ papel: "agente_financeiro", unidade: null, valido_ate: null }] },
    ],
    papeis: [{ id: "admin", nome: "Administrador" }, { id: "agente_financeiro", nome: "Agente" }, { id: "consulta", nome: "Consulta" }, { id: "diretoria", nome: "Diretoria" }, { id: "financeiro", nome: "Financeiro" }, { id: "gerente", nome: "Gerente" }],
    unidades: [{ id: "campinas", nome: "Campinas", ativo: true }, { id: "sao_vicente", nome: "São Vicente", ativo: true }],
    politicas: [
      { id: 12, versao: 1, papel: "agente_financeiro", recurso: "fin.lancamento", operacao: "registrar_comprovante", unidade: null, risco: "baixo", categoria: "automatica", limite_valor: null, aprovadores_minimos: 1, papel_aprovador: null, valido_de: "2026-10-26T12:00:00Z" },
      { id: 20, versao: 1, papel: "financeiro", recurso: "painel", operacao: "tratar_pendencia", unidade: null, risco: "medio", categoria: "automatica", limite_valor: null, aprovadores_minimos: 1, papel_aprovador: null, valido_de: "2026-10-26T12:00:00Z" },
    ],
  },
  painel_lab: {
    sincronizacao: { ativa: false, agente: "pausado", ultima: { em: ha(300), recebidas: 412, aplicadas: 410, ignoradas: 2 } },
    etapas: [
      { col: 0, nome: "Pedido", situacao: "andamento", parado_dias: 2, confirmada: false },
      { col: 1, nome: "Aguardando lentes", situacao: "andamento", parado_dias: 7, confirmada: false },
      { col: 2, nome: "Aguardando montagem", situacao: "andamento", parado_dias: 3, confirmada: false },
      { col: 3, nome: "Em montagem", situacao: "andamento", parado_dias: 3, confirmada: false },
      { col: 4, nome: "Avisado", situacao: "aguardando_cliente", parado_dias: 15, confirmada: false },
      { col: 5, nome: "Entregue", situacao: "encerrada", parado_dias: null, confirmada: false },
    ],
    unidades: [
      { id: "campinas", nome: "Campinas", por_etapa: { "0": 19, "1": 22, "3": 10, "4": 16 }, alertas: { prazo_vencido: 6, sem_pedido_lab: 2 } },
      { id: "sao_vicente", nome: "São Vicente", por_etapa: { "0": 8, "1": 8, "4": 12 }, alertas: { aguardando_retirada: 3 } },
    ],
    alertas: [
      { id: 1, tipo: "prazo_vencido", unidade_id: "campinas", aberto_em: ha(200), detalhe: { prazo: "2026-10-22", dias: 4, etapa: "Aguardando lentes" },
        os: "1001", pedido: "BR-55821", tipo_os: "venda", laboratorio: "LAB PRÓPRIO", etapa: "Aguardando lentes", prazo: "2026-10-22", urgente: true, entrou_etapa_em: ha(9000) },
      { id: 2, tipo: "aguardando_retirada", unidade_id: "sao_vicente", aberto_em: ha(400), detalhe: { dias: 21, limite_dias: 15, saldo_aberto: true },
        os: "2002", pedido: "BR-55102", tipo_os: "venda", laboratorio: "LAB PRÓPRIO", etapa: "Avisado", prazo: "2026-10-01", urgente: false, entrou_etapa_em: ha(30000) },
    ],
  },
  painel_comercial: {
    periodo_dias: 7, limite_resposta_min: 30,
    sincronizacao: { ativa: false, agente: "pausado", ultima: null },
    lojas: [
      { id: "campinas", nome: "Campinas", leads_novos: 84, ganhos: 21, perdidos: 9, valor_ganho: 18450.9, em_aberto: 40 },
      { id: "_sem_loja", nome: "Funis sem loja definida", leads_novos: 12, ganhos: 2, perdidos: 1, valor_ganho: 1200, em_aberto: 7 },
    ],
    atendentes: [
      { id: 7, nome: "Atendente Ana", respondidas: 120, mediana_min: 12.5, no_limite_pct: 81.2, ganhos: 11 },
      { id: 8, nome: "Atendente Bia", respondidas: 64, mediana_min: 47, no_limite_pct: 40, ganhos: 4 },
    ],
    resposta_geral: { respondidas: 184, mediana_min: 18, no_limite_pct: 67.4 },
    alertas: [
      { id: 1, tipo: "cliente_sem_resposta", referencia: "lead:100", unidade_id: "campinas", responsavel: "Atendente Bia", aberto_em: ha(1),
        detalhe: { desde: new Date(Date.now() - 50 * 60000).toISOString(), minutos: 50, limite_min: 30 } },
      { id: 2, tipo: "lead_parado", referencia: "lead:104", unidade_id: "campinas", responsavel: "Atendente Ana", aberto_em: ha(30),
        detalhe: { etapa: "Em contato", dias: 5, limite_dias: 3 } },
      { id: 3, tipo: "funil_sem_loja", referencia: "funil:20", unidade_id: null, responsavel: null, aberto_em: ha(30), detalhe: { funil: "Funil Sorocaba" } },
    ],
    funis: [{ id: 10, nome: "Funil Campinas", unidade_id: "campinas" }, { id: 20, nome: "Funil Sorocaba", unidade_id: null }],
  },
  painel_comercial_funil_loja: null,
  painel_marketing: {
    periodo_dias: 7, desde: "2026-10-20", ate: "2026-10-26",
    sincronizacao: { ativa: false, agente: "pausado", ultima: null },
    lojas: [
      { id: "campinas", nome: "Campinas", gasto: 5370.9, conversas: 368, leads: 4, impressoes: 410000, gasto_recrutamento: 134.6 },
      { id: "_sem_loja", nome: "Contas sem loja definida", gasto: 3881.2, conversas: 221, leads: 0, impressoes: 290000, gasto_recrutamento: 46 },
    ],
    marcas: [{ marca: "idealize", gasto: 5370.9, conversas: 368, leads: 4 }, { marca: "sem_marca", gasto: 3881.2, conversas: 221, leads: 0 }],
    campanhas: [
      { id: "52568233317239", nome: "[ENGAJAMENTO] [MENSAGEM] CAMPINAS", conta: "CA Campinas Idealize", unidade_id: "campinas", status: "ACTIVE",
        objetivo: "OUTCOME_ENGAGEMENT", recrutamento: false, orcamento_diario: 760, gasto: 5370.9, conversas: 368, leads: 4, cliques: 9100, impressoes: 410000, visitas: 0 },
      { id: "52629493165439", nome: "Tráfego [vagas]", conta: "CA Campinas Idealize", unidade_id: "campinas", status: "ACTIVE",
        objetivo: "OUTCOME_TRAFFIC", recrutamento: true, orcamento_diario: 20, gasto: 134.6, conversas: 0, leads: 0, cliques: 400, impressoes: 30000, visitas: 273 },
    ],
    por_dia: [0, 1, 2, 3, 4, 5, 6].map((n) => ({ dia: `2026-10-${20 + n}`, gasto: 1200 + n * 20, resultados: 80 + n })),
    alertas: [
      { id: 1, tipo: "gasto_sem_resultado", referencia: "campanha:1", unidade_id: "campinas", aberto_em: ha(30),
        detalhe: { campanha: "[MENSAGEM] Teste", conta: "CA Campinas Idealize", gasto: 70 } },
      { id: 2, tipo: "conta_com_problema", referencia: "conta:1441410073197795", unidade_id: null, aberto_em: ha(60),
        detalhe: { conta: "CA IDEALIZE SOROCABA", status_meta: 3 } },
    ],
    contas: [
      { id: "961713916565369", nome: "CA Campinas Idealize", unidade_id: "campinas", marca: "idealize", status_meta: 1,
        sugestao: { unidade_id: "campinas", marca: "idealize" }, gasto_30d: 23582.18 },
      { id: "1441410073197795", nome: "CA IDEALIZE SOROCABA", unidade_id: null, marca: null, status_meta: 3,
        sugestao: { unidade_id: "sorocaba", marca: "idealize" }, gasto_30d: 16834.56 },
    ],
  },
  painel_marketing_conta_loja: null,
  painel_rh: {
    hoje: "2026-10-26", mes: "2026-10-01",
    sincronizacao: { ativa: false, agente: "pausado", ultima: null },
    quadro: [{ unidade_id: "sao_vicente", ativos: 9, em_experiencia: 3, em_ferias: 1, afastados: 0, em_admissao: 1, admitidos_mes: 2, desligados_mes: 0 }],
    alertas: [
      { id: 1, tipo: "ferias_vencidas", referencia: "vinculo:a:2023-11-01:fora", unidade_id: "sao_vicente", prazo: "2025-10-31", aberto_em: ha(60),
        detalhe: { nome: "COLABORADORA TESTE", aquisitivo_inicio: "2023-11-01", aquisitivo_fim: "2024-10-31", limite: "2025-10-31", dias_fora_do_prazo: 30 } },
      { id: 2, tipo: "fim_experiencia", referencia: "vinculo:b:45", unidade_id: "sao_vicente", prazo: "2026-10-31", aberto_em: ha(60),
        detalhe: { nome: "CONSULTOR NOVO", marco_dias: 45, termina: "2026-10-31" } },
      { id: 3, tipo: "uniforme_baixo", referencia: "uniforme:u", unidade_id: null, prazo: null, aberto_em: ha(60),
        detalhe: { peca: "POLO FEMININO", tamanho: "M", saldo: 3, minimo: 12 } },
    ],
    contabilidade: {
      admissoes: [{ nome: "CONSULTOR NOVO", unidade_id: "sao_vicente", cargo: "CONSULTOR DE VENDAS", data: "2026-10-01" }],
      desligamentos: [], ferias: [{ nome: "COLABORADORA TESTE", unidade_id: "sao_vicente", inicio: "2026-10-13", fim: "2026-11-01", programada: false }],
      mudancas: [{ nome: "COLABORADORA TESTE", unidade_id: "sao_vicente", tipo: "salario", data: "2026-10-01" }],
    },
  },
  painel_cobrancas: {
    hoje: "2026-10-26",
    sincronizacao: { ativa: false, agente: "pausado", ultima: null, asaas_lojas: [] },
    carteira: [
      { unidade_id: "sao_vicente", financeira: "asaas", a_vencer_30: 2100, a_vencer_total: 10341.63, vencido_1_30: 900, vencido_31_60: 868.33,
        vencido_61_90: 0, vencido_90_mais: 0, parcelas_vencidas: 14, clientes_em_atraso: 9 },
      { unidade_id: "sao_vicente", financeira: "multicredito", a_vencer_30: 5200, a_vencer_total: 41116.48, vencido_1_30: 1725.31, vencido_31_60: 0,
        vencido_61_90: 0, vencido_90_mais: 0, parcelas_vencidas: 10, clientes_em_atraso: 7 },
    ],
    recebido_30d: [{ unidade_id: "sao_vicente", financeira: "asaas", valor: 1820, parcelas: 12 }],
    alertas: [
      { id: 1, tipo: "cobranca_sem_parcela", referencia: "asaas:pay_z", unidade_id: "sao_vicente", aberto_em: ha(60),
        detalhe: { valor: 120, vencimento: "2026-11-05", status_asaas: "PENDING" } },
      { id: 2, tipo: "parcela_vencida", referencia: "carne:A", unidade_id: "sao_vicente", aberto_em: ha(600),
        detalhe: { os: "1234", financeira: "asaas", parcelas: 2, valor: 300, dias: 41 } },
    ],
  },
  painel_caixa: {
    periodo_dias: 7, desde: "2026-10-20", ate: "2026-10-26",
    sincronizacao: { ativa: false, agente: "pausado", ultima: null },
    fontes: [{ forma: "pix", fonte: "banco", rotulo: "Pix" }, { forma: "asaas", fonte: "asaas", rotulo: "Asaas" },
      { forma: "credito", fonte: "stone", rotulo: "Crédito" }, { forma: "dinheiro", fonte: "deposito", rotulo: "Dinheiro" },
      { forma: "crediario", fonte: "nenhuma", rotulo: "Multicrediário" }],
    cobertura: [{ unidade_id: "sao_vicente", fonte: "banco", ate: "2026-10-26" }, { unidade_id: "sao_vicente", fonte: "asaas", ate: "2026-10-26" }],
    conferencia: [
      { unidade_id: "sao_vicente", dia: "2026-10-23", forma: "pix", sistema: 706, quantidade: 5, achado: 506, faltando: 200 },
      { unidade_id: "sao_vicente", dia: "2026-10-23", forma: "asaas", sistema: 600, quantidade: 1, achado: 600, faltando: 0 },
      { unidade_id: "sao_vicente", dia: "2026-10-23", forma: "credito", sistema: 800, quantidade: 2, achado: 0, faltando: 800 },
      { unidade_id: "sao_vicente", dia: "2026-10-23", forma: "crediario", sistema: 900, quantidade: 1, achado: 0, faltando: 900 },
    ],
    dias: [{ unidade_id: "sao_vicente", dia: "2026-10-23", status_adm: "aberto", caixa: 3100, soma_formas: 3006, deposito_valor: null }],
    alertas: [
      { id: 1, tipo: "nao_encontrado", referencia: "sao_vicente:2026-10-23:pix", unidade_id: "sao_vicente", dia: "2026-10-23", aberto_em: ha(60),
        detalhe: { forma: "pix", rotulo: "Pix", fonte: "banco", quantidade: 2, valor: 200, valores: [100, 100] } },
      { id: 2, tipo: "caixa_nao_fechado", referencia: "sao_vicente:2026-10-22", unidade_id: "sao_vicente", dia: "2026-10-22", aberto_em: ha(600), detalhe: {} },
    ],
  },
  painel_aprovar: "pronta", painel_plataforma_pausar: null, painel_reconciliar: "validando", painel_pendencia_tratar: null,
  painel_incidente_tratar: null, painel_fechamento_decidir: "aprovado", painel_agente_status: null, painel_papel_conceder: null,
};

export type Opcoes = {
  logado?: "aal1" | "aal2" | false;
  comFator?: boolean;
  rpc?: Record<string, unknown | ((corpo: Record<string, unknown>) => { status: number; body: unknown })>;
};

export async function instalar(page: Page, o: Opcoes = {}) {
  const chamadas: { fn: string; corpo: Record<string, unknown> }[] = [];
  const comFator = o.comFator ?? true;
  let nivel: "aal1" | "aal2" = o.logado === "aal1" ? "aal1" : "aal2";
  if (o.logado) {
    await page.addInitScript(([s]) => { window.sessionStorage.setItem("idealize-painel", s); }, [JSON.stringify(sessao(nivel, comFator))]);
  }
  const json = (r: Route, body: unknown, status = 200) => r.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });

  await page.route(`${BASE}/**`, async (r) => {
    const url = new URL(r.request().url());
    const p = url.pathname;
    if (r.request().method() === "OPTIONS") return r.fulfill({ status: 204, headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "*", "access-control-allow-methods": "*" } });
    if (p === "/auth/v1/token" && url.searchParams.get("grant_type") === "password") {
      const corpo = r.request().postDataJSON();
      if (corpo.password !== "senha-certa") return json(r, { error: "invalid_grant", error_description: "Invalid login credentials", msg: "Invalid login credentials", code: "invalid_credentials" }, 400);
      nivel = "aal1";
      return json(r, sessao("aal1", comFator));
    }
    if (p === "/auth/v1/token") return json(r, sessao(nivel, comFator));
    if (p === "/auth/v1/recover") { chamadas.push({ fn: "auth_recover", corpo: r.request().postDataJSON() }); return json(r, {}); }
    if (p === "/auth/v1/user" && r.request().method() === "PUT") {
      chamadas.push({ fn: "auth_user_put", corpo: r.request().postDataJSON() });
      return json(r, usuario(comFator));
    }
    if (p === "/auth/v1/user") return json(r, usuario(comFator));
    if (p === "/auth/v1/logout") return r.fulfill({ status: 204 });
    if (p === "/auth/v1/factors" && r.request().method() === "POST")
      return json(r, { id: "f-novo", type: "totp", friendly_name: "Painel Idealize",
        totp: { qr_code: "data:image/svg+xml;utf-8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'><rect width='10' height='10' fill='%23ccc'/></svg>", secret: "JBSWY3DPEHPK3PXP", uri: "otpauth://totp/x" } });
    if (/\/auth\/v1\/factors\/[^/]+\/challenge$/.test(p)) return json(r, { id: "c1", type: "totp", expires_at: Math.floor(Date.now() / 1000) + 300 });
    if (/\/auth\/v1\/factors\/[^/]+\/verify$/.test(p)) {
      const corpo = r.request().postDataJSON();
      if (corpo.code !== "123456") return json(r, { code: "mfa_verification_failed", msg: "Invalid TOTP code entered", error_code: "mfa_verification_failed" }, 422);
      nivel = "aal2";
      return json(r, sessao("aal2", true));
    }
    const m = p.match(/^\/rest\/v1\/rpc\/(painel_[a-z_]+)$/);
    if (m) {
      const corpo = (r.request().postDataJSON() ?? {}) as Record<string, unknown>;
      chamadas.push({ fn: m[1], corpo });
      const sob = o.rpc?.[m[1]];
      if (typeof sob === "function") { const x = (sob as (c: Record<string, unknown>) => { status: number; body: unknown })(corpo); return json(r, x.body, x.status); }
      if (sob !== undefined) return json(r, sob);
      if (m[1] in RPC) return json(r, RPC[m[1]]);
    }
    return json(r, { message: `mock sem rota: ${p}` }, 404);
  });
  return chamadas;
}
