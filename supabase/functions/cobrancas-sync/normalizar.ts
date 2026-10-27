// Converte o crediário do ADM e as cobranças do Asaas no formato do lote. Lista FECHADA de campos: parcela, valor,
// vencimento, situação e número da OS. Nome, CPF, telefone, e-mail e descrição da cobrança nunca passam daqui.
export type Obj = Record<string, unknown>;

const dia = (v: unknown): string | null => {
  if (v instanceof Date && !isNaN(v.getTime())) return v.toISOString().slice(0, 10);
  return typeof v === "string" && /^\d{4}-\d{2}-\d{2}/.test(v) ? v.slice(0, 10) : null;
};
const num = (v: unknown): number | null => {
  const n = typeof v === "string" ? Number(v) : typeof v === "number" ? v : NaN;
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
};
const inteiro = (v: unknown): number | null => { const n = num(v); return n == null ? null : Math.trunc(n); };
const texto = (v: unknown, max = 80): string | null => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);
const logico = (v: unknown) => v === true;

export function parcelaAdm(r: Obj): Obj | null {
  const id = texto(r.id), carne = texto(r.crediario_id), v = num(r.valor), venc = dia(r.dt_vencimento);
  if (!id || !carne || v == null || !venc) return null;
  return { id, crediario_id: carne, unidade: texto(r.unidade, 40), financeira: texto(r.financeira, 20), numero: inteiro(r.numero),
    num_parcelas: inteiro(r.num_parcelas), valor: v, dt_vencimento: venc, dt_pagamento: dia(r.dt_pagamento), status: texto(r.status, 20),
    os: texto(r.os, 40), os_fake: logico(r.os_fake), carne_status: texto(r.carne_status, 20), renegociado: logico(r.renegociado),
    dt_compra: dia(r.dt_compra), valor_crediario: num(r.valor_crediario), valor_entrada: num(r.valor_entrada),
    entrada_paga: logico(r.entrada_paga), dt_entrada: dia(r.dt_entrada) };
}

const STATUS = new Set(["PENDING", "OVERDUE", "RECEIVED", "CONFIRMED", "RECEIVED_IN_CASH"]);

// Só carnê/boleto/Pix: cobrança de cartão é venda à vista parcelada no cartão (fica no agente de Caixa)
export function cobrancaAsaas(c: Obj): Obj | null {
  const id = texto(c.id), v = num(c.value), venc = dia(c.dueDate), st = String(c.status ?? "");
  if (!id || !/^[A-Za-z0-9_-]{3,80}$/.test(id) || v == null || v <= 0 || !venc || !STATUS.has(st) || c.billingType === "CREDIT_CARD") return null;
  return { id, valor: v, vencimento: venc, status: st, pagamento: dia(c.clientPaymentDate) ?? dia(c.paymentDate),
    parcelamento: texto(c.installment) };
}

export function tokensAsaas(s: string | undefined): { unidade: string; token: string }[] {
  return (s ?? "").split(/[\n,]+/).map((l) => l.trim()).flatMap((l) => {
    const i = l.indexOf("=");
    if (i < 1) return [];
    const unidade = l.slice(0, i).trim(), token = l.slice(i + 1).trim();
    return /^[a-z_]{2,40}$/.test(unidade) && token.length >= 20 ? [{ unidade, token }] : [];
  });
}
