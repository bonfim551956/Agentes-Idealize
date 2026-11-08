// Idealize AI — agente no WhatsApp: liga a lógica ao banco, à Z-API, ao Claude e ao armazenamento.
import postgres from "npm:postgres@3.4.5";
import { atender, type Banco } from "./servico.ts";

let sql: ReturnType<typeof postgres> | null = null;
const db = () => (sql ??= postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 3, prepare: false, idle_timeout: 20 }));
const env = (k: string) => Deno.env.get(k);

const banco: Banco = {
  receber: async (p) => (await db()`select wa.receber(${db().json(p as never)}) r`)[0].r,
  responder: async (e, t, erro = null) => (await db()`select wa.responder(${e}, ${t}, ${erro}) r`)[0].r,
  marcarEnvio: async (id, ok, erro = null) => { await db()`select wa.marcar_envio(${id}, ${ok}, ${erro})`; },
  fila: async (n) => (await db()`select wa.fila(${n}) r`)[0].r,
  prepararAvisos: async () => (await db()`select wa.preparar_avisos() r`)[0].r,
  cfg: async (k, padrao) => (await db()`select core.cfg(${k}, ${padrao}) r`)[0].r,
  conversarAviso: async (e, i) => (await db()`select wa.aviso_conversar(${e}, ${String(i.tipo ?? "")}, ${String(i.referencia ?? "")},
    ${String(i.mensagem_pessoa ?? "")}, ${String(i.resposta ?? "")}, ${i.explicar === true}) r`)[0].r,
  envioIniciar: async (e, u, nome, mime, tam, sha) => (await db()`select wa.envio_iniciar(${e}, ${u}, ${nome}, ${mime}, ${tam}, ${sha}) r`)[0].r,
  avisosPegar: async (n) => (await db()`select public.agente_avisos_pegar(${n}) r`)[0].r,
  avisoResponder: async (id, t) => (await db()`select public.agente_aviso_responder(${id}, ${t}) r`)[0].r,
  envioRecebido: async (id, tam, sha) => (await db()`select fin.envio_arquivo_recebido(${id}::uuid, ${tam}, ${sha}) r`)[0].r,
  // pergunta: transação SOMENTE LEITURA, com o papel wa_leitura e tempo máximo
  consultar: (q) => db().begin(async (t) => {
    await t.unsafe("set transaction read only");
    await t.unsafe("set local role wa_leitura");
    await t.unsafe("set local statement_timeout = '8s'");
    const linhas = await t.unsafe(`select * from (${q}) _q limit 200`);
    return { linhas: linhas.length, dados: linhas };
  }),
};

async function claude(corpo: Record<string, unknown>) {
  const key = env("ANTHROPIC_API_KEY");
  if (!key) throw new Error("chave da IA não configurada");
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST", signal: AbortSignal.timeout(90_000),
    headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify(corpo),
  });
  if (!r.ok) throw new Error(`IA respondeu HTTP ${r.status}`);
  return await r.json();
}

async function guardar(caminho: string, bytes: Uint8Array) {
  const servico = env("SUPABASE_SERVICE_ROLE_KEY")!;
  const chaves: Record<string, string> = servico.startsWith("eyJ") ? { apikey: servico, authorization: `Bearer ${servico}` } : { apikey: servico };
  const r = await fetch(`${env("SUPABASE_URL")}/storage/v1/object/fin-envios/${caminho}`, {
    method: "POST", headers: { ...chaves, "content-type": "application/octet-stream", "x-upsert": "false" }, body: bytes });
  await r.body?.cancel();
  if (!r.ok) throw new Error(`armazenamento HTTP ${r.status}`);
}

// deno-lint-ignore no-explicit-any
const depois = (p: Promise<unknown>) => { const er = (globalThis as any).EdgeRuntime; if (er?.waitUntil) er.waitUntil(p); else void p; };

Deno.serve((req) => atender(req, env, banco, { fetch, claude, depois, guardar }));
