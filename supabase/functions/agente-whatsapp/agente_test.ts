import { assert, assertEquals, assertStringIncludes } from "./_assert.ts";
import { hostPermitido, lojaDoTexto, nomeArquivo, paraWhatsapp, responder, sqlDeLeitura } from "./logica.ts";
import { atender, type Banco, type Fora } from "./servico.ts";

const UN = [{ id: "campinas", nome: "Campinas" }, { id: "sorocaba", nome: "Sorocaba" }, { id: "sao_vicente", nome: "São Vicente" }, { id: "piracicaba", nome: "Piracicaba" }];

Deno.test("loja pela legenda: nome, sem acento, sigla e ambiguidade", () => {
  assertEquals(lojaDoTexto("extrato São Vicente outubro", UN), "sao_vicente");
  assertEquals(lojaDoTexto("extrato sao vicente", UN), "sao_vicente");
  assertEquals(lojaDoTexto("stone SV", UN), "sao_vicente");
  assertEquals(lojaDoTexto("fatura campinas", UN), "campinas");
  assertEquals(lojaDoTexto("extrato", UN), null);
  assertEquals(lojaDoTexto("campinas e sorocaba", UN), null);
});

Deno.test("nome do arquivo seguro e extensão pelo tipo", () => {
  assertEquals(nomeArquivo("sicredi_123.ofx", "application/octet-stream"), "sicredi_123.ofx");
  assertEquals(nomeArquivo("../../etc/passwd", "application/pdf"), "etc_passwd.pdf");
  assertEquals(nomeArquivo(null, "image/jpeg"), "arquivo.jpg");
});

Deno.test("mídia só de host permitido e https", () => {
  assert(hostPermitido("https://storage.z-api.io/x.pdf", ["z-api.io"]));
  assert(!hostPermitido("http://storage.z-api.io/x.pdf", ["z-api.io"]));
  assert(!hostPermitido("https://z-api.io.evil.com/x", ["z-api.io"]));
});

Deno.test("só SQL de leitura passa", () => {
  assertEquals(sqlDeLeitura("select 1;"), "select 1");
  assert(sqlDeLeitura("with x as (select 1) select * from x"));
  assertEquals(sqlDeLeitura("delete from cx.alertas"), null);
  assertEquals(sqlDeLeitura("select 1; drop table x"), null);
  assertEquals(sqlDeLeitura("with x as (delete from t returning *) select * from x"), null);
  assertEquals(sqlDeLeitura("select set_config('role','postgres',false)"), null);
  assert(sqlDeLeitura("select * from cx.pagamentos where forma = 'credito' order by dia offset 0"));
});

Deno.test("texto do WhatsApp sem markdown pesado", () => {
  assertEquals(paraWhatsapp("## Título\n**Caixa** ok\n\n\n\nfim"), "Título\n*Caixa* ok\n\nfim");
});

Deno.test("laço com ferramenta: consulta e responde", async () => {
  let voltas = 0; const consultas: string[] = [];
  const r = await responder("m", "Diego", [], "o caixa de SV de 25/09 bateu?", {
    claude: async (c) => {
      voltas++;
      if (voltas === 1) return { stop_reason: "tool_use", content: [{ type: "tool_use", id: "t1", name: "consultar_banco", input: { sql: "select caixa, soma_formas from cx.dias where dia = '2026-09-25'" } }] };
      const ult = (c.messages as { content: unknown }[]).at(-1)!.content as { content: string }[];
      assertStringIncludes(ult[0].content, "6440");
      return { stop_reason: "end_turn", content: [{ type: "text", text: "**Não bateu**: R$ 6.440,00 × R$ 6.940,00." }] };
    },
    consultar: async (s) => { consultas.push(s); return { linhas: 1, dados: [{ caixa: 6440, soma_formas: 6940 }] }; },
    conversarAviso: async () => ({ ok: true }),
  });
  assertEquals(consultas.length, 1);
  assertEquals(r, "*Não bateu*: R$ 6.440,00 × R$ 6.940,00.");
});

Deno.test("laço recusa SQL que escreve sem chamar o banco", async () => {
  let chamou = false, voltas = 0;
  await responder("m", "Diego", [], "apaga o aviso", {
    claude: async (c) => {
      voltas++;
      if (voltas === 1) return { stop_reason: "tool_use", content: [{ type: "tool_use", id: "t1", name: "consultar_banco", input: { sql: "delete from cx.alertas" } }] };
      const ult = (c.messages as { content: unknown }[]).at(-1)!.content as { content: string }[];
      assertStringIncludes(ult[0].content, "leitura");
      return { stop_reason: "end_turn", content: [{ type: "text", text: "Eu só consulto." }] };
    },
    consultar: async () => { chamou = true; return {}; },
    conversarAviso: async () => ({}),
  });
  assert(!chamou);
});

function fakeBanco(acao: Record<string, unknown>, extra: Partial<Banco> = {}) {
  const log: string[] = [];
  const b: Banco = {
    receber: async () => { log.push("receber"); return acao; },
    responder: async (_e, t) => { log.push(`responder:${t}`); return 1; },
    marcarEnvio: async (id, ok) => { log.push(`marcar:${id}:${ok}`); },
    fila: async () => [],
    prepararAvisos: async () => { log.push("preparar"); return 0; },
    consultar: async () => ({}),
    conversarAviso: async () => ({}),
    envioIniciar: async () => ({ duplicado: false, id: "11111111-1111-1111-1111-111111111111", caminho: "sao_vicente/2026-11/11111111-1111-1111-1111-111111111111.pdf" }),
    envioRecebido: async () => "lendo",
    cfg: async (k, p) => (k === "wa.ativo" ? "true" : k === "fin.whatsapp.midia_hosts" ? "z-api.io" : p),
    avisosPegar: async () => [],
    avisoResponder: async () => 1,
    ...extra,
  };
  return { b, log };
}
const env = (o: Record<string, string>) => (k: string) => o[k];

Deno.test("webhook: sem segredo certo recusa; repassa tudo ao webhook antigo", async () => {
  const { b, log } = fakeBanco({ acao: "ignorar" });
  const chamadas: string[] = [];
  const fora: Fora = { fetch: (async (u: string, i: RequestInit) => { chamadas.push(`${u}|${i.body}`); return new Response("ok"); }) as typeof fetch,
    claude: async () => ({ content: [], stop_reason: "end_turn" }), depois: () => {}, guardar: async () => {} };
  const e = env({ AGENTE_WA_SEGREDO: "s3gredo-longo", FINANCE_WEBHOOK_URL: "https://antigo.example/finance-webhook?s=x" });
  const r401 = await atender(new Request("https://f/agente-whatsapp?s=errado", { method: "POST", body: "{}" }), e, b, fora);
  assertEquals(r401.status, 401);
  const corpo = JSON.stringify({ type: "ReceivedCallback", isGroup: true, phone: "1203", messageId: "A1", text: { message: "oi" } });
  const r = await atender(new Request("https://f/agente-whatsapp?s=s3gredo-longo", { method: "POST", body: corpo, headers: { "content-type": "application/json" } }), e, b, fora);
  assertEquals(r.status, 200);
  assertEquals(chamadas, [`https://antigo.example/finance-webhook?s=x|${corpo}`]);
  assertEquals(log, ["receber"]);
});

Deno.test("webhook: repasse falhou → 502 para a Z-API reenviar", async () => {
  const { b } = fakeBanco({ acao: "ignorar" });
  const fora: Fora = { fetch: (async () => new Response("x", { status: 500 })) as unknown as typeof fetch,
    claude: async () => ({ content: [], stop_reason: "end_turn" }), depois: () => {}, guardar: async () => {} };
  const r = await atender(new Request("https://f/x?s=s3gredo-longo", { method: "POST", body: "{}" }), env({ AGENTE_WA_SEGREDO: "s3gredo-longo", FINANCE_WEBHOOK_URL: "https://a.example" }), b, fora);
  assertEquals(r.status, 502);
});

Deno.test("arquivo com a loja na legenda vira envio e é guardado", async () => {
  const { b, log } = fakeBanco({ acao: "tratar", id: 7, tipo: "documento", texto: "extrato SV", nome: "Diego",
    arquivo: { url: "https://storage.z-api.io/a.pdf", nome: "sicredi.pdf", mime: "application/pdf" }, unidades: UN });
  const guardados: string[] = []; let tarefa: Promise<unknown> | null = null;
  const fora: Fora = { fetch: (async (u: string) => u.includes("z-api.io/a.pdf") ? new Response(new Uint8Array([37, 80, 68, 70])) : new Response("ok")) as typeof fetch,
    claude: async () => ({ content: [], stop_reason: "end_turn" }), depois: (p) => { tarefa = p; }, guardar: async (c) => { guardados.push(c); } };
  const r = await atender(new Request("https://f/x?s=s3gredo-longo", { method: "POST", body: "{}" }), env({ AGENTE_WA_SEGREDO: "s3gredo-longo" }), b, fora);
  assertEquals(r.status, 200);
  await tarefa;
  assertEquals(guardados, ["sao_vicente/2026-11/11111111-1111-1111-1111-111111111111.pdf"]);
  assert(log.some((l) => l.startsWith("responder:Recebi sicredi.pdf de São Vicente")));
});

Deno.test("arquivo sem loja: pede a loja e não grava nada", async () => {
  let iniciou = false;
  const { b, log } = fakeBanco({ acao: "tratar", id: 8, tipo: "documento", texto: "", arquivo: { url: "https://storage.z-api.io/a.pdf", nome: "extrato.pdf" }, unidades: UN },
    { envioIniciar: async () => { iniciou = true; return {}; } });
  let tarefa: Promise<unknown> | null = null;
  const fora: Fora = { fetch: (async () => new Response("ok")) as unknown as typeof fetch, claude: async () => ({ content: [], stop_reason: "end_turn" }),
    depois: (p) => { tarefa = p; }, guardar: async () => {} };
  await atender(new Request("https://f/x?s=s3gredo-longo", { method: "POST", body: "{}" }), env({ AGENTE_WA_SEGREDO: "s3gredo-longo" }), b, fora);
  await tarefa;
  assert(!iniciou);
  assert(log.some((l) => l.includes("não sei de qual loja")));
});

Deno.test("cron: só com a chave do worker; envia a fila pela Z-API", async () => {
  const marcados: string[] = []; const enviados: string[] = [];
  const { b } = fakeBanco({}, { fila: async () => [{ id: 3, telefone: "5513900000000", texto: "Urgente" }], marcarEnvio: async (id, ok) => { marcados.push(`${id}:${ok}`); } });
  const fora: Fora = { fetch: (async (u: string, i: RequestInit) => { enviados.push(`${u.includes("send-text")}|${i.body}`); return new Response("{}"); }) as typeof fetch,
    claude: async () => ({ content: [], stop_reason: "end_turn" }), depois: () => {}, guardar: async () => {} };
  const e = env({ SUP_WORKER_SECRET: "chave-cron", SUP_ZAPI_INSTANCIA: "ABCDEFGHIJ12", SUP_ZAPI_TOKEN: "TOKEN1234567", SUP_ZAPI_CLIENT_TOKEN: "clienttoken123" });
  assertEquals((await atender(new Request("https://f/x", { method: "POST", headers: { "x-worker-key": "errada" } }), e, b, fora)).status, 401);
  const r = await atender(new Request("https://f/x", { method: "POST", headers: { "x-worker-key": "chave-cron" } }), e, b, fora);
  assertEquals((await r.json()).enviadas, 1);
  assertEquals(marcados, ["3:true"]);
  assertEquals(enviados, [`true|${JSON.stringify({ phone: "5513900000000", message: "Urgente" })}`]);
});

Deno.test("cron responde o \"Falar com o agente\" do painel mesmo com o WhatsApp desligado", async () => {
  const respostas: string[] = [];
  const { b } = fakeBanco({}, {
    cfg: async (k, p) => (k === "wa.ativo" ? "false" : p),
    avisosPegar: async () => [{ id: 9, tipo: "caixa_inconsistente", unidade_id: "sao_vicente", acao: "comentar", texto: "o valor entrou duplicado", aviso: { dia: "2026-09-25" }, conversa: [] }],
    avisoResponder: async (_id, t) => { respostas.push(t); return 1; },
  });
  let sistemaUsado = "";
  const fora: Fora = { fetch: (async () => new Response("{}")) as unknown as typeof fetch,
    claude: async (c) => { sistemaUsado = String(c.system); return { stop_reason: "end_turn", content: [{ type: "text", text: "Confirmado." }] }; },
    depois: () => {}, guardar: async () => {} };
  const r = await atender(new Request("https://f/x", { method: "POST", headers: { "x-worker-key": "k" } }), env({ SUP_WORKER_SECRET: "k" }), b, fora);
  const j = await r.json();
  assertEquals(j.respostasPainel, 1);
  assertEquals(respostas, ["Confirmado."]);
  assertStringIncludes(sistemaUsado, "painel");
  assertStringIncludes(sistemaUsado, "NUNCA cite nomes de tabelas");
});
