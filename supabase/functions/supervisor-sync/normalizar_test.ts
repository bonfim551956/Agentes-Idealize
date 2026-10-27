import { camposAsaas, camposKommo, itensLab, lerAsaas, lerKommo, tokensAsaas } from "./fontes.ts";
import { configZapi, enviar } from "./aviso.ts";
import { iguais } from "./sync.ts";

const igual = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`); };
const resposta = (status: number, corpo?: unknown) => new Response(corpo === undefined ? null : JSON.stringify(corpo), { status });

Deno.test("Asaas: só status, valor e data de pagamento; cobrança removida = não encontrada", () => {
  igual(camposAsaas({ id: "pay_1", status: "RECEIVED", value: 70, paymentDate: "2026-10-20", customer: "cus_x", description: "Fulano" }),
    { id: "pay_1", encontrado: true, campos: { status: "RECEIVED", valor: 70, pagamento: "2026-10-20" } });
  igual(camposAsaas({ id: "pay_2", deleted: true, status: "PENDING", value: 1 }), { id: "pay_2", encontrado: false });
});
Deno.test("Kommo: funil, etapa, responsável, valor e data de atualização; nada de nome ou contato", () => {
  igual(camposKommo({ id: 9, pipeline_id: 1, status_id: 2, responsible_user_id: 3, price: 0, updated_at: 1700000000, name: "Fulano", _embedded: { contacts: [] } }),
    { id: "9", encontrado: true, campos: { funil_id: 1, etapa_id: 2, responsavel_id: 3, valor: 0, atualizado_em: 1700000000 } });
});
Deno.test("Asaas: um GET por cobrança com a chave da loja; 404 vira não encontrada; loja sem chave é pulada", async () => {
  const chamadas: string[] = [];
  const f = ((u: URL, init: RequestInit) => {
    chamadas.push(`${init.method} ${u.pathname} ${(init.headers as Record<string, string>).access_token}`);
    return Promise.resolve(u.pathname.endsWith("pay_b") ? resposta(404) : resposta(200, { id: "pay_a", status: "PENDING", value: 10 }));
  }) as typeof fetch;
  const r = await lerAsaas([{ id: "pay_a", unidade_id: "sv" }, { id: "pay_b", unidade_id: "sv" }, { id: "pay_c", unidade_id: "outra" }],
    tokensAsaas("sv=" + "k".repeat(30)), f);
  igual(r.map((x) => [x.id, x.encontrado]), [["pay_a", true], ["pay_b", false]]);
  igual(chamadas.every((c) => c.startsWith("GET /v3/payments/") && c.endsWith("k".repeat(30))), true);
});
Deno.test("Kommo: só GET, id inválido ignorado, subdomínio validado", async () => {
  const metodos: string[] = [];
  const f = ((u: URL, init: RequestInit) => { metodos.push(init.method!); return Promise.resolve(resposta(204)); }) as typeof fetch;
  igual(await lerKommo(["123", "abc"], "idealize", "t", f), [{ id: "123", encontrado: false }]);
  igual(metodos, ["GET"]);
  let erro = ""; try { await lerKommo(["1"], "evil.com/x", "t", f); } catch (e) { erro = String(e); }
  igual(erro.includes("subdomínio"), true);
});
Deno.test("ADM/laboratório: OS que sumiu da visão = não encontrada", () => {
  igual(itensLab(["1", "2"], [{ id: 1, col: 3, cancelado: false, nao_retirado: true, ts: 1700000000000n }]),
    [{ id: "1", encontrado: true, campos: { col: 3, cancelado: false, nao_retirado: true, ts: 1700000000000 } }, { id: "2", encontrado: false }]);
});
Deno.test("Z-API: sem credencial completa não envia; envia para cada destino válido e só dá ok se todos aceitarem", async () => {
  igual(configZapi(() => undefined), null);
  const z = configZapi((k) => ({ SUP_ZAPI_INSTANCIA: "A1B2C3D4E5", SUP_ZAPI_TOKEN: "T1T2T3T4T5", SUP_ZAPI_CLIENT_TOKEN: "C".repeat(20) } as Record<string, string>)[k])!;
  const corpos: string[] = [];
  let n = 0;
  const f = ((_u: string, init: RequestInit) => { corpos.push(String(init.body)); n++; return Promise.resolve(resposta(n === 2 ? 500 : 200, {})); }) as typeof fetch;
  const r = await enviar(z, ["5513999990000", "123", "5511988887777"], "oi", f);
  igual(corpos.length, 2);
  igual(JSON.parse(corpos[0]), { phone: "5513999990000", message: "oi" });
  igual(r.ok, false);
  igual((await enviar(z, ["123"], "oi", f)).ok, false);
});
Deno.test("segredo do worker comparado em tempo constante", () => {
  igual([iguais("abc", "abc"), iguais("abc", "abd"), iguais("abc", "ab")], [true, false, false]);
});
