import { receber, sha256 } from "./recebimento.ts";

const igual = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`); };
const env = (k: string) => ({ SUPABASE_URL: "https://x.supabase.co", SUPABASE_ANON_KEY: "anon", SUPABASE_SERVICE_ROLE_KEY: "sb_secret_x",
  PAINEL_ORIGENS: "https://painel.test" } as Record<string, string>)[k];
const ID = "11111111-2222-3333-4444-555555555555";
const pedido = (campos: Record<string, string | File>, auth = "Bearer " + "a".repeat(40)) => {
  const f = new FormData(); for (const [k, v] of Object.entries(campos)) f.append(k, v);
  return new Request("https://x/fin-envio", { method: "POST", headers: { authorization: auth, origin: "https://painel.test" }, body: f });
};

Deno.test("sem login não envia; tipo inválido e arquivo vazio recusados", async () => {
  const banco = { recebido: () => Promise.resolve("recebido") };
  igual((await receber(pedido({ unidade: "sv" }, ""), env, banco)).status, 401);
  igual((await receber(pedido({ unidade: "sv", tipo: "virus", arquivo: new File(["x"], "a.pdf") }), env, banco)).status, 400);
  igual((await receber(pedido({ unidade: "sv", arquivo: new File([], "a.pdf") }), env, banco)).status, 400);
});

Deno.test("fluxo: banco confere como a pessoa → grava sem sobrescrever → confirma hash e tamanho refeitos", async () => {
  const chamadas: { u: string; h: Record<string, string>; b?: string }[] = [];
  let recebido: unknown[] = [];
  const f = ((u: string, init: RequestInit) => {
    chamadas.push({ u, h: init.headers as Record<string, string>, b: typeof init.body === "string" ? init.body : undefined });
    if (u.includes("/rpc/")) return Promise.resolve(Response.json({ duplicado: false, id: ID, caminho: `sao_vicente/2026-10/${ID}.pdf` }));
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as typeof fetch;
  const r = await receber(pedido({ unidade: "sao_vicente", tipo: "fatura", arquivo: new File(["%PDF-1.7 fatura"], "fatura.pdf", { type: "application/pdf" }) }), env,
    { recebido: (...a) => { recebido = a; return Promise.resolve("recebido"); } }, f);
  igual(r.status, 200);
  igual(await r.json(), { duplicado: false, id: ID, status: "recebido" });
  igual(chamadas[0].h.authorization, "Bearer " + "a".repeat(40));                       // RPC com o login da pessoa
  igual(JSON.parse(chamadas[0].b!).p_sha256, await sha256(new TextEncoder().encode("%PDF-1.7 fatura")));
  igual([chamadas[1].u.endsWith(`/storage/v1/object/fin-envios/sao_vicente/2026-10/${ID}.pdf`), chamadas[1].h["x-upsert"]], [true, "false"]);
  igual(recebido, [ID, 15, await sha256(new TextEncoder().encode("%PDF-1.7 fatura"))]);
  igual(r.headers.get("access-control-allow-origin"), "https://painel.test");
});

Deno.test("arquivo repetido: não grava de novo; recusa do banco chega à pessoa", async () => {
  let gravou = false;
  const dup = ((u: string) => { if (!u.includes("/rpc/")) gravou = true; return Promise.resolve(Response.json({ duplicado: true, id: ID, status: "lancado" })); }) as typeof fetch;
  const r = await receber(pedido({ unidade: "sv", arquivo: new File(["x"], "a.pdf") }), env, { recebido: () => Promise.resolve("x") }, dup);
  igual([(await r.json()).duplicado, gravou], [true, false]);
  const nega = (() => Promise.resolve(Response.json({ message: "sem permissão para enviar_documento na unidade sv" }, { status: 403 }))) as typeof fetch;
  const n = await receber(pedido({ unidade: "sv", arquivo: new File(["x"], "a.pdf") }), env, { recebido: () => Promise.resolve("x") }, nega);
  igual([n.status, (await n.json()).erro.includes("sem permissão")], [403, true]);
});
