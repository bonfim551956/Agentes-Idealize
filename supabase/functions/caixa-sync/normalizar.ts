// Converte o que vem do ADM e do Asaas no formato do lote. Lista FECHADA de campos: loja, dia, forma, valor e o id
// da cobrança. Nome, CPF, e-mail do cliente e descrição da cobrança nunca passam daqui.
export type Obj = Record<string, unknown>;

const dia = (v: unknown): string | null => {
  if (v instanceof Date && !isNaN(v.getTime())) return v.toISOString().slice(0, 10);
  return typeof v === "string" && /^\d{4}-\d{2}-\d{2}/.test(v) ? v.slice(0, 10) : null;
};
const num = (v: unknown): number | null => {
  const n = typeof v === "string" ? Number(v) : typeof v === "number" ? v : NaN;
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
};
const texto = (v: unknown, max = 40): string | null => (typeof v === "string" ? v.trim().slice(0, max) : null);

export function diaAdm(r: Obj): Obj | null {
  const d = dia(r.data), u = texto(r.unidade);
  if (!d || !u) return null;
  return { unidade: u, data: d, status: texto(r.status, 20), caixa: num(r.caixa), dinheiro_gaveta: num(r.dinheiro_gaveta),
    deposito_valor: num(r.deposito_valor), deposito_data: dia(r.deposito_data) };
}

export function pagamentoAdm(r: Obj): Obj | null {
  const d = dia(r.data), u = texto(r.unidade), v = num(r.valor);
  if (!d || !u || v == null || v === 0 || !["venda", "entrega"].includes(String(r.origem))) return null;
  return { unidade: u, data: d, origem: r.origem, forma: texto(r.forma) ?? "", valor: v };
}

const RECEBIDO = new Set(["RECEIVED", "CONFIRMED", "RECEIVED_IN_CASH"]);

// Cobranças do Asaas → recebimentos. Cartão parcelado vira UM recebimento (soma das parcelas, no dia da venda);
// carnê/boleto/Pix parcelado é parcela de crediário (fica para o agente de Cobranças).
export function recebimentosAsaas(cobrancas: Obj[]): Obj[] {
  const cartaoParcelado = new Map<string, Obj>();
  const saida: Obj[] = [];
  for (const c of cobrancas) {
    const id = texto(c.id, 80), v = num(c.value), st = String(c.status ?? "");
    const d = dia(c.clientPaymentDate) ?? dia(c.confirmedDate) ?? dia(c.paymentDate);
    if (!id || !/^[A-Za-z0-9_-]{3,80}$/.test(id) || v == null || v <= 0 || !d || !RECEBIDO.has(st)) continue;
    const parc = texto(c.installment, 80);
    if (parc && /^[A-Za-z0-9_-]{3,80}$/.test(parc) && c.billingType === "CREDIT_CARD") {
      const g = cartaoParcelado.get(parc);
      if (g) { g.valor = Math.round(((g.valor as number) + v) * 100) / 100; if ((d as string) < (g.dia as string)) g.dia = d; }
      else cartaoParcelado.set(parc, { id: parc, dia: d, forma: "asaas", valor: v, parcela: false });
      continue;
    }
    saida.push({ id, dia: d, forma: "asaas", valor: v, parcela: Boolean(parc) });
  }
  return [...saida, ...cartaoParcelado.values()];
}

// ASAAS_TOKENS: uma linha (ou item separado por vírgula) por loja: "unidade=chave"
export function tokensAsaas(s: string | undefined): { unidade: string; token: string }[] {
  return (s ?? "").split(/[\n,]+/).map((l) => l.trim()).flatMap((l) => {
    const i = l.indexOf("=");
    if (i < 1) return [];
    const unidade = l.slice(0, i).trim(), token = l.slice(i + 1).trim();
    return /^[a-z_]{2,40}$/.test(unidade) && token.length >= 20 ? [{ unidade, token }] : [];
  });
}
