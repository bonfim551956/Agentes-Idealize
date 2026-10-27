import { supabase } from "./supabase";
import { traduzir } from "./erros";

export async function rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw traduzir(error);
  return data as T;
}

// ---- tipos das respostas (espelham as funções public.painel_*) ----
export type Eu = {
  nome: string; aal2: boolean;
  papeis: { papel: string; unidade: string | null }[];
  unidades: { id: string; nome: string }[];
  pode: Record<"consultar" | "consultar_global" | "auditoria" | "administrar" | "pausar_plataforma" |
    "tratar_incidente" | "reconciliar" | "cancelar_tarefa" | "tratar_pendencia", boolean>;
};

export type Resumo = {
  plataforma_pausada: boolean;
  agentes: Record<string, number>;
  tarefas: Record<string, number>;
  tarefas_24h: number; atrasadas: number; aprovacoes_pendentes: number;
  incidentes: Record<string, number>; falhas_recorrentes: number;
  pendencias_fin: { abertas: number; materiais: number };
  custo_mes: { confirmado: number; estimado: number } | null;
  integracoes: Record<string, number>;
  canal_whatsapp: { ativo: boolean; responder: boolean };
  auditoria: { integra: boolean; em: string } | null;
  gerado_em: string;
};

export type Agente = {
  id: string; nome: string; departamento: string; status: string; versao: string; descricao: string | null;
  limite_custo_mensal: number | null; ultima_atividade: string | null;
  tarefas: Record<"concluidas" | "em_andamento" | "aguardando_aprovacao" | "bloqueadas" | "incertas" | "falhas" | "atrasadas", number>;
  periodo_dias: number; execucoes: number; tempo_medio_s: number | null; taxa_sucesso: number | null; erros: number;
  taxa_retrabalho: number | null; aprovacoes_solicitadas: number;
  custo_mes: { confirmado: number; estimado: number } | null; tokens_mes: { entrada: number; saida: number } | null;
  incidentes_abertos: number; economia_estimada: null; economia_confirmada: null; disponibilidade: null;
};

export type TarefaResumo = {
  id: string; agente_id: string; tipo: string; recurso: string; operacao: string; unidade_id: string | null;
  valor: number | null; status: string; prioridade: number; risco: string; categoria: string; tentativas: number;
  prazo: string | null; atrasada: boolean; motivo: string | null; criado_em: string; atualizado_em: string;
};

export type TarefaDetalhe = {
  tarefa: TarefaResumo & {
    correlacao_id: string; max_tentativas: number; proximo_em: string; executor: string | null;
    payload: unknown; resultado: unknown; hash_operacao: string; solicitante: string | null;
  };
  politica: { id: number; versao: number; risco: string; categoria: string; aprovadores_minimos: number;
    papel_aprovador: string | null; limite_valor: number | null } | null;
  execucoes: { tentativa: number; executor: string; status: string; inicio_em: string; fim_em: string | null;
    efeito_externo_id: string | null; erro: string | null; evidencia: unknown }[];
  validacoes: { validador: string; resultado: string; motivo: string | null; evidencia: unknown; em: string }[];
  aprovacoes: { aprovador: string; decisao: string; canal: string; comentario: string | null; em: string; expira_em: string; vale: boolean }[];
  dependencias: { id: string; status: string }[];
  incidentes: { id: number; titulo: string; severidade: string; status: string; ocorrencias: number }[];
  historico: { id: number; em: string; acao: string; ator: string | null; antes: unknown; depois: unknown; motivo: string | null }[];
  pode: { aprovar: boolean; reconciliar: boolean; cancelar: boolean };
};

export type Aprovacao = {
  id: string; agente_id: string; tipo: string; recurso: string; operacao: string; unidade_id: string | null;
  valor: number | null; risco: string; prioridade: number; motivo: string | null; payload: unknown;
  hash_operacao: string; criado_em: string; solicitante: string | null; papel_aprovador: string | null;
  aprovadores_minimos: number | null; aprovacoes_validas: number; pode_aprovar: boolean;
};

export type Incidente = {
  id: number; chave: string; severidade: string; status: string; titulo: string; agente_id: string | null;
  integracao_id: string | null; tarefa_id: string | null; unidade_id: string | null; ocorrencias: number;
  escalonado: boolean; primeira_em: string; ultima_em: string; resolvido_em: string | null; detalhes: unknown; pode_tratar: boolean;
};

export type Pendencia = {
  id: number; tipo: string; unidade_id: string | null; material: boolean; referencia: string; detalhe: unknown; criado_em: string;
  lancamento: { numero: number; valor: number; natureza: string; sentido: string; categoria_id: string | null;
    data_competencia: string; descricao: string | null } | null;
  movimento: { data: string; valor: number; sentido: string; conta_id: string; descricao: string } | null;
  pode_tratar: boolean; pode_aceitar: boolean;
};

export type Financeiro = {
  competencia: string;
  unidades: { id: string; nome: string; receitas: number; despesas: number; resultado: number;
    caixa_entradas: number; caixa_saidas: number; pendencias_abertas: number; pendencias_materiais: number;
    fechamento: { id: string; status: string; versao: number; pendencias_materiais: number; pacote_hash: string;
      preparado_por: string; validado_por: string | null; decidido_em: string | null; criado_em: string } | null }[];
  consolidado: { receitas: number; despesas: number; caixa_entradas: number; caixa_saidas: number } | null;
};

export type LinhaDre = { natureza: string; grupo: string; categoria_id: string | null; categoria: string; valor: number; tem_rateio: boolean };

export type Custos = {
  inicio: string; fim: string;
  total: { confirmado: number; estimado: number; registros: number };
  por: Record<string, { chave: string; confirmado: number; estimado: number; tokens_entrada: number; tokens_saida: number; registros: number }[]>;
  limites: { agente_id: string; nome: string; limite: number | null; consumo_mes: number; percentual: number | null }[] | null;
};

export type EventoAuditoria = { id: number; em: string; acao: string; entidade: string; entidade_id: string | null;
  ator: string | null; antes: unknown; depois: unknown; motivo: string | null; hash: string };

export type Operacao = {
  integracoes: { id: string; nome: string; status: string; escrita_habilitada: boolean; ultimo_ok_em: string | null; observacoes: string | null }[];
  chaves: { plataforma_pausada: boolean; fin_whatsapp_ativo: boolean; fin_whatsapp_responder: boolean };
  versoes: { componentes: Record<string, string>; agentes: Record<string, string>; migracoes: { versao: string; nome: string | null }[] | null };
  agendamentos: { cron: { nome: string; agenda: string; ativo: boolean }[] | null; tarefas_futuras: number; proxima_tarefa_em: string | null };
};

export type Usuarios = {
  principais: { id: string; tipo: string; nome: string; ativo: boolean; vinculado: boolean; eu: boolean; agente_id: string | null;
    telefone: string | null; papeis: { papel: string; unidade: string | null; valido_ate: string | null }[] }[];
  papeis: { id: string; nome: string }[];
  unidades: { id: string; nome: string; ativo: boolean }[];
  politicas: { id: number; versao: number; papel: string; recurso: string; operacao: string; unidade: string | null; risco: string;
    categoria: string; limite_valor: number | null; aprovadores_minimos: number; papel_aprovador: string | null; valido_de: string }[];
};

export type LabPainel = {
  sincronizacao: { ativa: boolean; agente: string; ultima: { em: string; recebidas: number; aplicadas: number; ignoradas: number } | null };
  etapas: { col: number; nome: string; situacao: string; parado_dias: number | null; confirmada: boolean }[];
  unidades: { id: string; nome: string; por_etapa: Record<string, number>; alertas: Record<string, number> }[];
  alertas: { id: number; tipo: string; unidade_id: string; aberto_em: string; detalhe: Record<string, unknown> | null; os: string | null;
    pedido: string | null; tipo_os: string | null; laboratorio: string | null; etapa: string; prazo: string | null; urgente: boolean;
    entrou_etapa_em: string | null }[];
};

export type ComercialPainel = {
  periodo_dias: number; limite_resposta_min: number;
  sincronizacao: { ativa: boolean; agente: string; ultima: { em: string; ate: string; leads: number; mensagens_novas: number } | null };
  lojas: { id: string; nome: string; leads_novos: number; ganhos: number; perdidos: number; valor_ganho: number; em_aberto: number }[];
  atendentes: { id: number; nome: string; respondidas: number; mediana_min: number | null; media_min: number | null; no_limite_pct: number | null; ganhos: number }[];
  resposta_geral: { respondidas: number; mediana_min: number | null; media_min: number | null; no_limite_pct: number | null };
  horario_atendimento: string; dias_atendimento: string;
  alertas: { id: number; tipo: string; referencia: string; unidade_id: string | null; responsavel: string | null; aberto_em: string;
    detalhe: Record<string, unknown> | null }[];
  funis: { id: number; nome: string; unidade_id: string | null }[] | null;
};

export type MarketingPainel = {
  periodo_dias: number; desde: string; ate: string;
  sincronizacao: { ativa: boolean; agente: string; ultima: { em: string; desde: string; ate: string; contas: number; linhas: number } | null };
  lojas: { id: string; nome: string; gasto: number; conversas: number; leads: number; impressoes: number; gasto_recrutamento: number }[];
  marcas: { marca: string; gasto: number; conversas: number; leads: number }[];
  campanhas: { id: string; nome: string; conta: string; unidade_id: string | null; status: string | null; objetivo: string | null;
    recrutamento: boolean; orcamento_diario: number | null; gasto: number; conversas: number; leads: number; cliques: number;
    impressoes: number; visitas: number }[];
  por_dia: { dia: string; gasto: number; resultados: number }[];
  alertas: { id: number; tipo: string; referencia: string; unidade_id: string | null; aberto_em: string; detalhe: Record<string, unknown> | null }[];
  contas: { id: string; nome: string; unidade_id: string | null; marca: string | null; status_meta: number;
    sugestao: { unidade_id: string | null; marca: string | null }; gasto_30d: number }[] | null;
};

export type CaixaPainel = {
  periodo_dias: number; desde: string; ate: string;
  sincronizacao: { ativa: boolean; agente: string; ultima: { em: string; desde: string; ate: string; dias: number; casados: number } | null };
  fontes: { forma: string; fonte: "banco" | "asaas" | "stone" | "deposito" | "nenhuma"; rotulo: string }[];
  cobertura: { unidade_id: string; fonte: string; ate: string | null }[];
  conferencia: { unidade_id: string; dia: string; forma: string; sistema: number; quantidade: number; achado: number; faltando: number }[];
  dias: { unidade_id: string; dia: string; status_adm: string | null; caixa: number | null; soma_formas: number; deposito_valor: number | null }[];
  alertas: { id: number; tipo: string; referencia: string; unidade_id: string | null; dia: string | null; aberto_em: string; detalhe: Record<string, unknown> | null }[];
};

export type CobrancasPainel = {
  hoje: string;
  sincronizacao: { ativa: boolean; agente: string; ultima: { em: string; parcelas: number; cobrancas_asaas: number; vinculos: number } | null; asaas_lojas: string[] };
  carteira: { unidade_id: string; financeira: string; a_vencer_30: number; a_vencer_total: number; vencido_1_30: number; vencido_31_60: number;
    vencido_61_90: number; vencido_90_mais: number; parcelas_vencidas: number; clientes_em_atraso: number }[];
  recebido_30d: { unidade_id: string; financeira: string; valor: number; parcelas: number }[];
  alertas: { id: number; tipo: string; referencia: string; unidade_id: string | null; aberto_em: string; detalhe: Record<string, unknown> | null }[];
};

export type RhPainel = {
  hoje: string; mes: string;
  sincronizacao: { ativa: boolean; agente: string; ultima: { em: string; vinculos: number; ativos: number } | null };
  quadro: { unidade_id: string; ativos: number; em_experiencia: number; em_ferias: number; afastados: number; em_admissao: number;
    admitidos_mes: number; desligados_mes: number }[];
  alertas: { id: number; tipo: string; referencia: string; unidade_id: string | null; prazo: string | null; aberto_em: string; detalhe: Record<string, unknown> | null }[];
  contabilidade: {
    admissoes: { nome: string; unidade_id: string; cargo: string | null; data: string }[];
    desligamentos: { nome: string; unidade_id: string; data: string; modalidade: string | null }[];
    ferias: { nome: string; unidade_id: string; inicio: string; fim: string; programada: boolean }[];
    mudancas: { nome: string; unidade_id: string; tipo: "cargo" | "salario"; data: string }[];
  };
};

export type AtribuicaoPainel = {
  desde: string; ate: string; janela_conversao_dias: number; janela_aberta_desde: string;
  sincronizacao: { ativa: boolean; agente: string; ultima: { em: string; leads: number; leads_com_telefone: number; vendas: number; conversoes: number } | null };
  lojas: { unidade_id: string; investido: number; resultados_meta: number; leads: number; leads_com_telefone: number; compraram: number;
    compraram_novos: number; faturamento: number; faturamento_novos: number }[];
  campanhas: { campanha_id: string; nome: string | null; unidade_id: string; investido: number; leads: number; compraram: number;
    faturamento: number; faturamento_novos: number; exatos: number }[];
  atendentes: { responsavel_id: number | null; nome: string | null; unidades: string[] | null; leads: number; compraram: number;
    compraram_novos: number; faturamento: number; faturamento_novos: number }[];
};

export type SupervisorPainel = {
  config: { ativo: boolean; agente: string; enviar: boolean; destinos: number; horarios: string; modo_seguro: boolean; auto_modo_seguro: boolean };
  ultima: { em: string; abertos: number; novos: number; resolvidos: number; auditoria_ok: boolean } | null;
  agentes: { agente_id: string; nome: string; status: string; leitura_ligada: boolean; ultima_leitura: string | null; minutos_desde: number | null;
    limite_min: number | null; alertas_abertos: number; problemas_24h: number; atrasado: boolean;
    amostra: { em: string; conferidos: number; iguais: number; mudaram_depois: number; divergentes: number; nao_encontrados: number } | null }[];
  achados: { id: number; tipo: string; agente_id: string | null; severidade: string; titulo: string; aberto_em: string; notificado_em: string | null }[];
  resolvidos: { id: number; tipo: string; severidade: string; titulo: string; aberto_em: string; resolvido_em: string }[];
  mensagens: { id: number; tipo: "urgente" | "resumo"; status: string; texto: string; criada_em: string; enviada_em: string | null; erro: string | null }[];
  previa: string;
};

export type EnvioLeitura = {
  tipo: string; formato: "ofx" | "ia"; saldo_inicial?: number | null; saldo_final?: number | null; total?: number | null; total_bruto?: number | null;
  linhas?: { data: string | null; valor: number | null; descricao: string }[];
  compras?: { data: string | null; descricao: string; valor: number | null; parcela?: string | null; categoria?: string | null }[];
  transacoes?: { data: string | null; forma: string | null; valor: number | null }[];
  itens?: { valor: number | null; data?: string | null; vencimento?: string | null; favorecido?: string | null }[];
};
export type EnviosPainel = {
  leitura_ligada: boolean; max_mb: number;
  contas: { id: string; apelido: string; tipo: string; unidade_id: string; instituicao: string | null; final: string | null }[];
  envios: { id: string; unidade_id: string; conta_id: string | null; tipo_declarado: string; tipo: string | null; nome_arquivo: string; tamanho: number;
    status: string; formato: string | null; checagens: { ok: boolean | null; itens: number; soma: number; esperado: number | null; avisos: string[] } | null;
    leitura: EnvioLeitura | null; resultado: Record<string, unknown> | null; motivo: string | null; criado_em: string; decidido_em: string | null;
    enviado_por: string | null; pode_confirmar: boolean }[];
  faltando: { esperado_id: number; unidade_id: string; tipo: string; conta_id: string | null; descricao: string; prazo: string }[];
  categorias: { id: string; nome: string }[];
};
