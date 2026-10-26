// Formatação e vocabulário: nomes que a pessoa entende, não os nomes internos do sistema.
const brl = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });
const usd = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "USD", maximumFractionDigits: 4 });
const num = new Intl.NumberFormat("pt-BR");
const pct = new Intl.NumberFormat("pt-BR", { style: "percent", maximumFractionDigits: 1 });

export const dinheiro = (v: number | null | undefined) => (v == null ? "—" : brl.format(Number(v)));
export const dolar = (v: number | null | undefined) => (v == null ? "—" : usd.format(Number(v)));
export const numero = (v: number | null | undefined) => (v == null ? "—" : num.format(Number(v)));
export const percentual = (v: number | null | undefined) => (v == null ? "sem dados" : pct.format(Number(v)));

export function dataHora(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("pt-BR", { day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" });
}
export function data(iso: string | null | undefined): string {
  if (!iso) return "—";
  const [a, m, d] = iso.slice(0, 10).split("-");
  return `${d}/${m}/${a}`;
}
export function relativo(iso: string | null | undefined, agora = Date.now()): string {
  if (!iso) return "nunca";
  const s = Math.round((agora - new Date(iso).getTime()) / 1000);
  if (s < 0) { const f = -s; return f < 3600 ? `em ${Math.ceil(f / 60)} min` : f < 86400 ? `em ${Math.round(f / 3600)} h` : `em ${Math.round(f / 86400)} dias`; }
  if (s < 60) return "agora";
  if (s < 3600) return `há ${Math.floor(s / 60)} min`;
  if (s < 86400) return `há ${Math.floor(s / 3600)} h`;
  return `há ${Math.floor(s / 86400)} ${Math.floor(s / 86400) === 1 ? "dia" : "dias"}`;
}
export function duracao(seg: number | null | undefined): string {
  if (seg == null) return "sem dados";
  if (seg < 60) return `${num.format(Math.round(seg * 10) / 10)} s`;
  return `${Math.floor(seg / 60)} min ${Math.round(seg % 60)} s`;
}
export function competenciaRotulo(iso: string): string {
  const d = new Date(iso.slice(0, 10) + "T12:00:00");
  const s = d.toLocaleDateString("pt-BR", { month: "long", year: "numeric" });
  return s[0].toUpperCase() + s.slice(1);
}

export type Tom = "neutro" | "lente" | "ok" | "atencao" | "critico";

export const STATUS_TAREFA: Record<string, { rotulo: string; tom: Tom }> = {
  pendente: { rotulo: "Na fila", tom: "neutro" },
  pronta: { rotulo: "Pronta para executar", tom: "lente" },
  aguardando_aprovacao: { rotulo: "Aguardando aprovação", tom: "atencao" },
  executando: { rotulo: "Executando", tom: "lente" },
  validando: { rotulo: "Em validação", tom: "lente" },
  concluida: { rotulo: "Concluída", tom: "ok" },
  falhou: { rotulo: "Falhou", tom: "critico" },
  bloqueada: { rotulo: "Bloqueada", tom: "atencao" },
  incerta: { rotulo: "Incerta, conferir", tom: "critico" },
  cancelada: { rotulo: "Cancelada", tom: "neutro" },
  rejeitada: { rotulo: "Rejeitada", tom: "neutro" },
};

export const STATUS_AGENTE: Record<string, { rotulo: string; tom: Tom }> = {
  ativo: { rotulo: "Ativo", tom: "ok" },
  pausado: { rotulo: "Pausado", tom: "atencao" },
  indisponivel: { rotulo: "Indisponível", tom: "critico" },
  desativado: { rotulo: "Desativado", tom: "neutro" },
};

export const SEVERIDADE: Record<string, { rotulo: string; tom: Tom; ordem: number }> = {
  critica: { rotulo: "Crítica", tom: "critico", ordem: 0 },
  alta: { rotulo: "Alta", tom: "critico", ordem: 1 },
  media: { rotulo: "Média", tom: "atencao", ordem: 2 },
  baixa: { rotulo: "Baixa", tom: "neutro", ordem: 3 },
  info: { rotulo: "Informativa", tom: "neutro", ordem: 4 },
};

export const STATUS_INTEGRACAO: Record<string, { rotulo: string; tom: Tom }> = {
  ok: { rotulo: "Funcionando", tom: "ok" },
  degradada: { rotulo: "Instável", tom: "atencao" },
  indisponivel: { rotulo: "Fora do ar", tom: "critico" },
  isolada: { rotulo: "Isolada", tom: "atencao" },
  nao_verificada: { rotulo: "Não verificada", tom: "neutro" },
};

export const TIPO_PENDENCIA: Record<string, string> = {
  divergencia: "Valores não batem",
  ambiguidade: "Mais de um lançamento possível",
  sem_classificacao: "Sem categoria",
  sem_comprovante: "Pagamento sem comprovante",
  duplicidade_suspeita: "Possível duplicidade",
  rateio_desbalanceado: "Rateio não fecha",
  transferencia_sem_par: "Transferência sem a outra ponta",
  fatura_divergente: "Fatura do cartão não bate",
  saldo_divergente: "Saldo do extrato não bate",
  comprovante_sem_pagamento: "Comprovante sem pagamento no extrato",
  revisao_extracao: "Leitura do comprovante a revisar",
};

export const STATUS_FECHAMENTO: Record<string, { rotulo: string; tom: Tom }> = {
  preparado: { rotulo: "Preparado", tom: "lente" },
  bloqueado: { rotulo: "Bloqueado por pendências", tom: "atencao" },
  validado: { rotulo: "Validado, falta a diretoria", tom: "atencao" },
  aprovado: { rotulo: "Aprovado", tom: "ok" },
  rejeitado: { rotulo: "Rejeitado", tom: "critico" },
  reaberto: { rotulo: "Reaberto", tom: "neutro" },
};

export const PAPEL: Record<string, string> = {
  admin: "Administrador", diretoria: "Diretoria", gerente: "Gerente", financeiro: "Financeiro",
  consulta: "Somente consulta", agente_financeiro: "Agente financeiro",
};

export const DEPARTAMENTO: Record<string, string> = {
  financeiro: "Financeiro", rh: "RH / DP", operacoes: "Operações e laboratório", comercial: "Comercial e marketing",
  tecnologia: "Tecnologia", administracao: "Administração",
};

// Nome das operações em linguagem de quem usa; o nome técnico aparece pequeno, para conferência
const OPERACAO: Record<string, string> = {
  "fin.lancamento.registrar_comprovante": "Registrar comprovante recebido",
  "fin.lancamento.registrar_ajuste": "Lançar ajuste financeiro",
  "fin.lancamento.registrar": "Registrar lançamento",
  "fin.lancamento.reclassificar": "Reclassificar lançamento",
  "fin.fechamento.preparar": "Preparar fechamento do mês",
  "fin.extrato.importar": "Importar extrato bancário",
};
export const nomeOperacao = (recurso: string, operacao: string) => OPERACAO[`${recurso}.${operacao}`] ?? `${recurso}.${operacao}`;
export const temNomeAmigavel = (recurso: string, operacao: string) => `${recurso}.${operacao}` in OPERACAO;

export function rotuloUnidade(id: string | null | undefined, unidades: { id: string; nome: string }[] = []): string {
  if (!id) return "Grupo (todas)";
  return unidades.find((u) => u.id === id)?.nome ?? id;
}
