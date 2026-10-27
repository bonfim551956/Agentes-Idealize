import { diaAdm, pagamentoAdm, recebimentosAsaas, tokensAsaas } from "./normalizar.ts";
import { cobrancasAsaas, iguais, lerAsaas } from "./sync.ts";

const igual = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`); };

Deno.test("ADM: só loja, dia, forma e valor; valor zero e origem estranha descartados", () => {
  igual(pagamentoAdm({ unidade: "saovicente", data: new Date("2026-10-24T00:00:00Z"), origem: "venda", forma: "pix", valor: "600", cliente: "Fulano" }),
    { unidade: "saovicente", data: "2026-10-24", origem: "venda", forma: "pix", valor: 600 });
  igual(pagamentoAdm({ unidade: "x", data: "2026-10-24", origem: "venda", forma: "pix", valor: 0 }), null);
  igual(pagamentoAdm({ unidade: "x", data: "2026-10-24", origem: "outra", forma: "pix", valor: 10 }), null);
  igual(diaAdm({ unidade: "campinas", data: "2026-10-26", status: "aberto", caixa: "15125", fechado_por: "Fulana" })!.caixa, 15125);
});
Deno.test("Asaas: data do cliente, cartão parcelado somado, carnê marcado como parcela, cancelado fora", () => {
  const r = recebimentosAsaas([
    { id: "pay_1", value: 300, status: "RECEIVED", billingType: "PIX", clientPaymentDate: "2026-10-20", paymentDate: "2026-10-21", customer: "cus_1" },
    { id: "pay_2", value: 100, status: "CONFIRMED", billingType: "CREDIT_CARD", installment: "ins_9", confirmedDate: "2026-10-22" },
    { id: "pay_3", value: 100, status: "CONFIRMED", billingType: "CREDIT_CARD", installment: "ins_9", confirmedDate: "2026-10-22" },
    { id: "pay_4", value: 150, status: "RECEIVED", billingType: "BOLETO", installment: "ins_7", paymentDate: "2026-10-23" },
    { id: "pay_5", value: 50, status: "REFUNDED", billingType: "PIX", paymentDate: "2026-10-23" },
  ]);
  igual(r, [{ id: "pay_1", dia: "2026-10-20", forma: "asaas", valor: 300, parcela: false },
            { id: "pay_4", dia: "2026-10-23", forma: "asaas", valor: 150, parcela: true },
            { id: "ins_9", dia: "2026-10-22", forma: "asaas", valor: 200, parcela: false }]);
});
Deno.test("tokens do Asaas por loja; linha inválida descartada; '=' dentro da chave preservado", () => {
  const t = tokensAsaas(`campinas=$aact_prod_${"a".repeat(30)}==\nsorocaba = ${"b".repeat(25)}\nlixo\nx=curto`);
  igual(t.map((x) => x.unidade), ["campinas", "sorocaba"]);
  igual(t[0].token.endsWith("=="), true);
});
Deno.test("cliente do Asaas só faz GET em api.asaas.com e pagina por offset", async () => {
  const pedidos: string[] = [];
  const f = ((u: URL, i: RequestInit) => {
    pedidos.push(`${i.method} ${u.origin}${u.pathname} offset=${u.searchParams.get("offset")}`);
    const off = Number(u.searchParams.get("offset"));
    return Promise.resolve(new Response(JSON.stringify({ hasMore: off === 0, data: off === 0 ? [{ id: "pay_1" }] : [{ id: "pay_2" }] })));
  }) as unknown as typeof fetch;
  const itens = await cobrancasAsaas("t".repeat(30), [["status", "RECEIVED"]], f);
  igual(itens.length, 2);
  igual(pedidos, ["GET https://api.asaas.com/v3/payments offset=0", "GET https://api.asaas.com/v3/payments offset=1"]);
});
Deno.test("leitura do Asaas junta recebidas e cartões confirmados sem repetir e respeita a janela", async () => {
  const f = ((u: URL) => {
    const data = u.searchParams.get("status") === "CONFIRMED"
      ? [{ id: "pay_c", value: 90, status: "CONFIRMED", billingType: "CREDIT_CARD", confirmedDate: "2026-10-25" },
         { id: "pay_r", value: 10, status: "RECEIVED", billingType: "PIX", paymentDate: "2026-10-24" }]
      : [{ id: "pay_r", value: 10, status: "RECEIVED", billingType: "PIX", paymentDate: "2026-10-24" },
         { id: "pay_v", value: 70, status: "RECEIVED", billingType: "PIX", clientPaymentDate: "2026-10-10", paymentDate: "2026-10-20" }];
    return Promise.resolve(new Response(JSON.stringify({ hasMore: false, data })));
  }) as unknown as typeof fetch;
  const r = await lerAsaas("t".repeat(30), "2026-10-20", "2026-10-26", f);
  igual(r.map((x) => x.id).sort(), ["pay_c", "pay_r"]);
});
Deno.test("comparação de segredo", () => { igual(iguais("abc", "abc"), true); igual(iguais("abc", "abd"), false); });
