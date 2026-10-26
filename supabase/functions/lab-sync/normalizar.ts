// Converte uma linha da visão do ADM no formato do lote. Lista FECHADA de campos:
// qualquer coisa a mais (nome, telefone, receita, valores) é descartada mesmo que a visão vaze.
export type Linha = Record<string, unknown>;

const TEXTO = ["id", "unidade", "os", "ped", "tipo", "lab"] as const;
const LOGICO = ["urgente", "refeito", "cancelado", "nao_retirado", "saldo_aberto"] as const;

const data = (v: unknown): string | null => {
  if (v instanceof Date && !isNaN(v.getTime())) return v.toISOString().slice(0, 10);
  if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}/.test(v)) return v.slice(0, 10);
  return null;
};
const inteiro = (v: unknown): string | null => {
  const s = typeof v === "bigint" ? v.toString() : typeof v === "number" ? String(Math.trunc(v)) : typeof v === "string" ? v : "";
  return /^-?\d+$/.test(s) ? s : null;
};

export function normalizar(l: Linha): Linha {
  const o: Linha = {};
  for (const k of TEXTO) if (l[k] != null) o[k] = String(l[k]).slice(0, 80);
  const col = inteiro(l.col);
  if (col != null) o.col = Number(col);
  for (const k of LOGICO) o[k] = l[k] === true;
  const dv = data(l.dt_venda), pz = data(l.prazo);
  if (dv) o.dt_venda = dv;
  if (pz) o.prazo = pz;
  const ts = inteiro(l.ts), ent = inteiro(l.entrou_etapa_ms);
  if (ts) o.ts = ts;
  if (ent) o.entrou_etapa_ms = ent;
  return o;
}
