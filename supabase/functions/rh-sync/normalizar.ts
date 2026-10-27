// Converte as visões do RH 360 no formato do lote. Lista FECHADA de campos por visão: qualquer coisa a mais
// (CPF, endereço, telefone, salário, conteúdo de documento) é descartada mesmo que a visão vaze.
export type Obj = Record<string, unknown>;

const dia = (v: unknown): string | null => {
  if (v instanceof Date && !isNaN(v.getTime())) return v.toISOString().slice(0, 10);
  return typeof v === "string" && /^\d{4}-\d{2}-\d{2}/.test(v) ? v.slice(0, 10) : null;
};
const texto = (v: unknown, max = 120): string | null => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : v == null ? null : String(v).slice(0, max));
const num = (v: unknown): number | null => { const n = typeof v === "string" ? Number(v) : typeof v === "number" ? v : NaN; return Number.isFinite(n) ? n : null; };

const CAMPOS: Record<string, Record<string, "texto" | "dia" | "num" | "logico" | "instante">> = {
  vinculos: { vinculo_id: "texto", nome: "texto", loja: "texto", cargo: "texto", tipo: "texto", status: "texto", data_admissao: "dia",
    data_desligamento: "dia", jornada_semanal_horas: "num", escala: "texto" },
  ferias: { id: "texto", vinculo_id: "texto", inicio: "dia", fim: "dia", aquisitivo_inicio: "dia", aquisitivo_fim: "dia", programada: "logico" },
  desligamentos: { id: "texto", vinculo_id: "texto", modalidade: "texto", data_comunicacao: "dia", data_desligamento: "dia", status: "texto", concluido_em: "instante" },
  tarefas: { id: "texto", titulo: "texto", categoria: "texto", loja: "texto", prazo: "dia", prioridade: "texto", status: "texto" },
  documentos: { id: "texto", vinculo_id: "texto", categoria: "texto", vencimento: "dia", status: "texto" },
  mudancas: { id: "texto", vinculo_id: "texto", tipo: "texto", data: "dia" },
  uniformes: { id: "texto", peca: "texto", tamanho: "texto", estoque_minimo: "num", saldo: "num" },
};

export function normalizar(tipo: keyof typeof CAMPOS, l: Obj): Obj {
  const o: Obj = {};
  for (const [k, t] of Object.entries(CAMPOS[tipo])) {
    const v = l[k];
    o[k] = t === "dia" ? dia(v) : t === "num" ? num(v) : t === "logico" ? v === true
      : t === "instante" ? (v instanceof Date ? v.toISOString() : texto(v, 40)) : texto(v, k === "titulo" ? 200 : 120);
  }
  return o;
}
