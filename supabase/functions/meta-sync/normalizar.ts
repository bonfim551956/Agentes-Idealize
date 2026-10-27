// Converte as respostas da Marketing API (Graph) no formato do lote. Lista FECHADA de campos: só números da conta,
// campanha e anúncio, nomes, status e métricas agregadas. Nenhum dado de pessoa (público, lead, comentário) passa daqui.
export type Obj = Record<string, unknown>;

const idMeta = (v: unknown): string | null => {
  const s = typeof v === "number" ? String(v) : typeof v === "string" ? v.replace(/^act_/, "") : "";
  return /^[0-9]{5,25}$/.test(s) ? s : null;
};
const inteiro = (v: unknown): number => {
  const n = typeof v === "string" ? Number(v) : typeof v === "number" ? v : NaN;
  return Number.isFinite(n) && n >= 0 ? Math.trunc(n) : 0;
};
const dinheiro = (v: unknown): number => {
  const n = typeof v === "string" ? Number(v) : typeof v === "number" ? v : NaN;
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) / 100 : 0;
};
const texto = (v: unknown, max = 200): string | null => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);
const dia = (v: unknown): string | null => (typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null);

export function conta(a: Obj): Obj | null {
  const id = idMeta(a.account_id ?? a.id);
  const status = Number(a.account_status);
  if (!id || !Number.isInteger(status)) return null;
  return { id, nome: texto(a.name, 120) ?? id, status_meta: status, motivo_bloqueio: inteiro(a.disable_reason), moeda: texto(a.currency, 3) ?? "BRL" };
}

export function campanha(c: Obj, contaId: string): Obj | null {
  const id = idMeta(c.id);
  if (!id) return null;
  const orc = c.daily_budget == null ? null : dinheiro(c.daily_budget) / 100; // a Meta manda em centavos
  return { id, conta_id: contaId, nome: texto(c.name) ?? `Campanha ${id}`, objetivo: texto(c.objective, 60),
    status: texto(c.effective_status, 40), orcamento_diario: orc };
}

// Tipos de ação contados como resultado (o primeiro presente vence, para não contar duas vezes)
const CONVERSAS = ["onsite_conversion.messaging_conversation_started_7d"];
const LEADS = ["lead", "onsite_conversion.lead_grouped", "offsite_conversion.fb_pixel_lead"];
const VISITAS = ["landing_page_view", "omni_landing_page_view"];
function acao(acoes: Obj[], tipos: string[]): number {
  for (const t of tipos) {
    const a = acoes.find((x) => x.action_type === t);
    if (a) return inteiro(a.value);
  }
  return 0;
}

export function metrica(r: Obj, contaId: string): Obj | null {
  const camp = idMeta(r.campaign_id), d = dia(r.date_start);
  if (!camp || !d) return null;
  const acoes = Array.isArray(r.actions) ? (r.actions as Obj[]) : [];
  return { campanha_id: camp, conta_id: contaId, dia: d, gasto: dinheiro(r.spend), impressoes: inteiro(r.impressions),
    alcance: inteiro(r.reach), cliques: inteiro(r.clicks), conversas: acao(acoes, CONVERSAS), leads: acao(acoes, LEADS),
    visitas: acao(acoes, VISITAS) };
}

export function anuncio(a: Obj, contaId: string): Obj | null {
  const id = idMeta(a.id), st = texto(a.effective_status, 40);
  if (!id || !st || !["DISAPPROVED", "WITH_ISSUES"].includes(st)) return null;
  return { id, conta_id: contaId, campanha_id: idMeta(a.campaign_id), nome: texto(a.name) ?? `Anúncio ${id}`, status: st };
}

export const lista = <T>(xs: Obj[], f: (x: Obj) => T | null): T[] => xs.flatMap((x) => { const r = f(x); return r == null ? [] : [r]; });
