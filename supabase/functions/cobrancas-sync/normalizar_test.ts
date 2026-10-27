import { cobrancaAsaas, parcelaAdm, tokensAsaas } from "./normalizar.ts";
import { iguais, lerAsaas } from "./sync.ts";

const igual = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`); };

Deno.test("parcela do ADM: só campos da lista (nome/CPF/telefone descartados)", () => {
  const p = parcelaAdm({ id: "p1", crediario_id: "c1", unidade: "saovicente", financeira: "asaas", numero: 2, num_parcelas: 10,
    valor: "150.00", dt_vencimento: new Date("2026-10-10T00:00:00Z"), status: "aberto", os: "1234", nome: "Fulano", cpf: "12345678900", telefone: "13999990000" })!;
  igual(JSON.stringify(p).match(/Fulano|12345678900|13999990000/), null);
  igual([p.valor, p.dt_vencimento, p.numero, p.os], [150, "2026-10-10", 2, "1234"]);
  igual(parcelaAdm({ id: "p1", crediario_id: "c1", valor: 10 }), null);
});
Deno.test("cobrança do Asaas: cartão fora, status desconhecido fora, data do pagamento do cliente", () => {
  igual(cobrancaAsaas({ id: "pay_1", value: 150, dueDate: "2026-10-10", status: "RECEIVED", billingType: "BOLETO", clientPaymentDate: "2026-10-09",
    paymentDate: "2026-10-11", customer: "cus_1", description: "Fulano parcela 2" }),
    { id: "pay_1", valor: 150, vencimento: "2026-10-10", status: "RECEIVED", pagamento: "2026-10-09", parcelamento: null });
  igual(cobrancaAsaas({ id: "pay_2", value: 100, dueDate: "2026-10-10", status: "CONFIRMED", billingType: "CREDIT_CARD" }), null);
  igual(cobrancaAsaas({ id: "pay_3", value: 100, dueDate: "2026-10-10", status: "REFUNDED", billingType: "PIX" }), null);
});
Deno.test("retrato do Asaas: pendentes, vencidas e pagas sem repetir", async () => {
  const pedidos: string[] = [];
  const f = ((u: URL, i: RequestInit) => {
    pedidos.push(`${i.method} ${u.search}`);
    const st = u.searchParams.get("status");
    const data = st === "PENDING" ? [{ id: "pay_p", value: 10, dueDate: "2026-11-01", status: "PENDING", billingType: "BOLETO" }]
      : st === "OVERDUE" ? [{ id: "pay_o", value: 20, dueDate: "2026-10-01", status: "OVERDUE", billingType: "BOLETO" }]
      : [{ id: "pay_r", value: 30, dueDate: "2026-10-05", status: "RECEIVED", billingType: "PIX", paymentDate: "2026-10-05" },
         { id: "pay_p", value: 10, dueDate: "2026-11-01", status: "PENDING", billingType: "BOLETO" }];
    return Promise.resolve(new Response(JSON.stringify({ hasMore: false, data })));
  }) as unknown as typeof fetch;
  const r = await lerAsaas("t".repeat(30), "2026-07-01", f);
  igual(r.map((x) => x.id).sort(), ["pay_o", "pay_p", "pay_r"]);
  igual(pedidos.every((p) => p.startsWith("GET ")), true);
});
Deno.test("tokens do Asaas por loja", () => { igual(tokensAsaas(`sao_vicente=${"x".repeat(30)}`)[0].unidade, "sao_vicente"); });
Deno.test("comparação de segredo", () => { igual(iguais("abc", "abc"), true); igual(iguais("abc", "abd"), false); });
