// Ponta a ponta: código real do worker + Postgres real local. Simulados: download, storage e Claude.
// NÃO valida Z-API, Storage nem a API da Anthropic de verdade.
import { assert, assertEquals } from "./_assert.ts";
import postgres from "npm:postgres@3.4.5";

const URL_DB = Deno.env.get("SUPABASE_DB_URL")!;
const db = postgres(URL_DB, { max: 2, prepare: false });
Deno.env.set("SUPABASE_URL", "https://projeto.supabase.co");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "sb_secret_teste");
Deno.env.set("ANTHROPIC_API_KEY", "teste");

const jpg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 2, 3, 4, 5]);
let iaStatus = 200;
let iaChamadas = 0;
const respostaIa = {
  content: [{ type: "tool_use", name: "extrair", input: {
    tipo_documento: "comprovante_pagamento",
    itens: [{ valor: 350, data: "2026-10-20", favorecido: "LAB E2E", favorecido_doc: "12345678000199",
              id_transacao: "E1234567820261020000000000000777", confianca: { valor: 0.98, data: 0.97 } }],
    texto_usuario: { valor: null, descricao: "lab" },
  } }],
  usage: { input_tokens: 1200, output_tokens: 90 },
};
globalThis.fetch = ((input: RequestInfo | URL, _init?: RequestInit) => {
  const u = String(input);
  if (u.includes("z-api.io")) return Promise.resolve(new Response(jpg, { status: 200 }));
  if (u.includes("/storage/v1/object/")) return Promise.resolve(new Response("{}", { status: 200 }));
  if (u.includes("api.anthropic.com")) {
    iaChamadas++;
    return Promise.resolve(iaStatus === 200 ? Response.json(respostaIa) : new Response("sobrecarga", { status: iaStatus }));
  }
  return Promise.reject(new Error("rede bloqueada no teste: " + u));
}) as typeof fetch;

const { executarLote, fechar } = await import("./worker.ts");
const payload = (id: string, url: string) => ({ type: "ReceivedCallback", messageId: id, isGroup: true,
  phone: "120000000000000777-group", participantPhone: "5513999997777", image: { imageUrl: url, mimeType: "image/jpeg" } });

Deno.test({ name: "e2e: desligado não processa nada", sanitizeOps: false, sanitizeResources: false }, async () => {
  assertEquals(await executarLote(2000), { status: "desligado" });
});

Deno.test({ name: "e2e: comprovante → lançamento pendente validado; IA fora do ar → nova tentativa sem gravar; host estranho → sem registro", sanitizeOps: false, sanitizeResources: false }, async () => {
  await db`update core.config set valor='true' where chave='fin.whatsapp.ativo'`;
  await db`update core.agentes set status='ativo' where id='financeiro'`;
  try {
    // 1) caminho feliz
    const [{ r }] = await db`select fin.receber_whatsapp(${db.json(payload("E2E-1", "https://m.z-api.io/1.jpg"))}) as r`;
    assertEquals(r.tarefa_status, "pronta");
    assertEquals((await executarLote(10_000)).tarefas, 1);
    const [t1] = await db`select status from core.tarefas where id = ${r.tarefa}::uuid`;
    assertEquals(t1.status, "concluida");
    const [l] = await db`select l.status, l.unidade_id, l.categoria_id, l.valor::text v from fin.lancamentos l
      join fin.lancamento_documentos ld on ld.lancamento_id = l.id join fin.documentos d on d.id = ld.documento_id
      where d.tarefa_id = ${r.tarefa}::uuid`;
    assertEquals([l.status, l.unidade_id, l.categoria_id, l.v], ["pendente", "u_e2e", "laboratorio", "350.00"]);
    const [c] = await db`select tokens_in, confirmado from core.custos where tarefa_id = ${r.tarefa}::uuid`;
    assertEquals([c.tokens_in, c.confirmado], [1200, false]);

    // 2) IA fora do ar: nada é gravado, tarefa volta para a fila com espera
    iaStatus = 529;
    const [{ r: r2 }] = await db`select fin.receber_whatsapp(${db.json(payload("E2E-2", "https://m.z-api.io/2.jpg"))}) as r`;
    await executarLote(10_000);
    const [t2] = await db`select status, tentativas, proximo_em > now() espera from core.tarefas where id = ${r2.tarefa}::uuid`;
    assertEquals([t2.status, t2.tentativas, t2.espera], ["pronta", 1, true]);
    const [{ n }] = await db`select count(*)::int n from fin.documentos where tarefa_id = ${r2.tarefa}::uuid`;
    assertEquals(n, 0);
    iaStatus = 200;

    // 3) URL fora da allowlist: não baixa, não chama IA, encerra sem registro e passa na validação
    const antes = iaChamadas;
    const [{ r: r3 }] = await db`select fin.receber_whatsapp(${db.json(payload("E2E-3", "https://evil.example.com/x.jpg"))}) as r`;
    await executarLote(10_000);
    const [t3] = await db`select status from core.tarefas where id = ${r3.tarefa}::uuid`;
    const [m3] = await db`select status, motivo from fin.whatsapp_mensagens where tarefa_id = ${r3.tarefa}::uuid`;
    assertEquals([t3.status, m3.status], ["concluida", "sem_registro"]);
    assertEquals(iaChamadas, antes);
    assert(String(m3.motivo).includes("host"));
  } finally {
    await db`update core.agentes set status='pausado' where id='financeiro'`;
    await db`update core.config set valor='false' where chave='fin.whatsapp.ativo'`;
    await fechar(); await db.end();
  }
});
