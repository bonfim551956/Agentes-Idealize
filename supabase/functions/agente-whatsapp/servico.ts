// Idealize AI — agente no WhatsApp: entrada (webhook da Z-API) e notificador (cron). Dependências injetáveis para teste.
import { hostPermitido, iguais, lojaDoTexto, nomeArquivo, responder, type Deps, type Env } from "./logica.ts";

const MAX_BODY = 1024 * 1024;
const MAX_ARQ = 20 * 1024 * 1024;

export type Banco = {
  receber: (p: unknown) => Promise<Record<string, unknown>>;
  responder: (entrada: number, texto: string, erro?: string | null) => Promise<number | null>;
  marcarEnvio: (id: number, ok: boolean, erro?: string | null) => Promise<void>;
  fila: (limite: number) => Promise<{ id: number; telefone: string; texto: string }[]>;
  prepararAvisos: () => Promise<number>;
  consultar: (sql: string) => Promise<unknown>;
  conversarAviso: (entrada: number, i: Record<string, unknown>) => Promise<unknown>;
  envioIniciar: (entrada: number, unidade: string, nome: string, mime: string, tamanho: number, sha: string) => Promise<Record<string, unknown>>;
  envioRecebido: (id: string, tamanho: number, sha: string) => Promise<string>;
  cfg: (chave: string, padrao: string) => Promise<string>;
};
export type Fora = {
  fetch: typeof fetch;
  claude: Deps["claude"];
  depois: (p: Promise<unknown>) => void;   // EdgeRuntime.waitUntil
  guardar: (caminho: string, bytes: Uint8Array) => Promise<void>;   // armazenamento privado fin-envios
};

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });

export function configZapi(env: Env) {
  const instancia = env("SUP_ZAPI_INSTANCIA") ?? "", token = env("SUP_ZAPI_TOKEN") ?? "", clientToken = env("SUP_ZAPI_CLIENT_TOKEN") ?? "";
  if (!/^[A-Za-z0-9]{10,64}$/.test(instancia) || !/^[A-Za-z0-9]{10,64}$/.test(token) || clientToken.length < 10) return null;
  return { instancia, token, clientToken };
}

async function sha256(b: Uint8Array) {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", b))].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/** Envia a fila de saída pela Z-API. */
export async function enviarFila(env: Env, b: Banco, f: typeof fetch): Promise<{ enviadas: number; erros: number }> {
  const z = configZapi(env);
  const fila = await b.fila(20);
  if (!fila.length) return { enviadas: 0, erros: 0 };
  if (!z) { for (const m of fila) await b.marcarEnvio(m.id, false, "Z-API sem chaves configuradas"); return { enviadas: 0, erros: fila.length }; }
  let enviadas = 0, erros = 0;
  for (const m of fila) {
    try {
      const r = await f(`https://api.z-api.io/instances/${z.instancia}/token/${z.token}/send-text`, {
        method: "POST", headers: { "content-type": "application/json", "client-token": z.clientToken },
        body: JSON.stringify({ phone: m.telefone, message: m.texto }), signal: AbortSignal.timeout(15_000) });
      await r.body?.cancel();
      if (r.ok) { enviadas++; await b.marcarEnvio(m.id, true); } else { erros++; await b.marcarEnvio(m.id, false, `HTTP ${r.status}`); }
    } catch (e) {
      erros++; await b.marcarEnvio(m.id, false, String((e as Error)?.name ?? "erro"));
    }
  }
  return { enviadas, erros };
}

/** Trata uma mensagem autorizada: texto → resposta; arquivo → envio da loja; áudio → pede texto. */
export async function tratar(env: Env, b: Banco, fora: Fora, m: Record<string, unknown>): Promise<void> {
  const id = Number(m.id);
  try {
    const tipo = String(m.tipo);
    if (tipo === "audio") { await b.responder(id, "Ainda não consigo ouvir áudio. Pode escrever a pergunta?"); return; }
    if (tipo === "documento" || tipo === "imagem") { await b.responder(id, await receberArquivo(b, fora, m));
      await enviarFila(env, b, fora.fetch).catch(() => null); return; }
    if (tipo !== "texto" || !String(m.texto ?? "").trim()) { await b.responder(id, "Por aqui eu entendo texto e arquivos (extrato, Stone, fatura, comprovante)."); return; }
    const modelo = await b.cfg("wa.modelo", "claude-sonnet-5-5");
    const texto = await responder(modelo, String(m.nome ?? ""), (m.historico as { de: string; texto: string }[]) ?? [], String(m.texto), {
      claude: fora.claude, consultar: b.consultar, conversarAviso: (i) => b.conversarAviso(id, i) });
    await b.responder(id, texto);
  } catch (e) {
    console.error(JSON.stringify({ app: "agente-whatsapp", erro: String((e as Error)?.message ?? e).slice(0, 200) }));
    await b.responder(id, "Tive um problema para responder agora. Tente de novo em alguns minutos.", String((e as Error)?.message ?? e)).catch(() => null);
  }
  await enviarFila(env, b, fora.fetch).catch(() => null);
}

export async function receberArquivo(b: Banco, fora: Fora, m: Record<string, unknown>): Promise<string> {
  const f = fora.fetch;
  const arq = (m.arquivo ?? {}) as { url?: string; nome?: string; mime?: string };
  const unidades = (m.unidades as { id: string; nome: string }[]) ?? [];
  const nome = nomeArquivo(arq.nome, arq.mime);
  const loja = lojaDoTexto(`${m.texto ?? ""} ${arq.nome ?? ""}`, unidades);
  if (!loja) return `Recebi ${nome}, mas não sei de qual loja é. Mande de novo com o nome da loja na legenda (ex.: "extrato São Vicente").`;
  const hosts = (await b.cfg("fin.whatsapp.midia_hosts", "z-api.io")).split(",").map((h) => h.trim()).filter(Boolean);
  if (!arq.url || !hostPermitido(arq.url, hosts)) return "Não consegui baixar o arquivo (endereço não permitido). Suba pelo painel em Enviar arquivos.";
  const r = await f(arq.url, { signal: AbortSignal.timeout(60_000) });
  if (!r.ok) { await r.body?.cancel(); return "Não consegui baixar o arquivo. Mande de novo ou suba pelo painel em Enviar arquivos."; }
  const bytes = new Uint8Array(await r.arrayBuffer());
  if (bytes.length < 1 || bytes.length > MAX_ARQ) return "O arquivo está vazio ou passa de 20 MB.";
  const sha = await sha256(bytes);
  const ini = await b.envioIniciar(Number(m.id), loja, nome, arq.mime ?? "application/octet-stream", bytes.length, sha);
  const lojaNome = unidades.find((u) => u.id === loja)?.nome ?? loja;
  if (ini.duplicado) return `Esse arquivo (${nome}) já tinha sido enviado para ${lojaNome}. Situação: ${String(ini.status)}.`;
  const caminho = String(ini.caminho ?? "");
  if (!/^[a-z0-9_]+\/\d{4}-\d{2}\/[0-9a-f-]{36}\.[a-z0-9]{2,5}$/.test(caminho)) throw new Error("caminho inesperado");
  await fora.guardar(caminho, bytes);
  await b.envioRecebido(String(ini.id), bytes.length, sha);
  return `Recebi ${nome} de ${lojaNome}. O agente financeiro vai ler em até 5 minutos e eu te aviso aqui quando terminar.`;
}

/** Ponto de entrada. POST ?s=<segredo> = webhook da Z-API; POST com x-worker-key = notificador (cron). */
export async function atender(req: Request, env: Env, b: Banco, fora: Fora): Promise<Response> {
  if (req.method !== "POST") return json({ ok: true });
  const chaveCron = env("SUP_WORKER_SECRET");
  const wk = req.headers.get("x-worker-key");
  if (wk !== null) {
    if (!chaveCron || !iguais(wk, chaveCron)) return json({ erro: "não autorizado" }, 401);
    if ((await b.cfg("wa.ativo", "false")) !== "true") return json({ desligado: true });
    const avisos = await b.prepararAvisos();
    return json({ avisos, ...(await enviarFila(env, b, fora.fetch)) });
  }

  const segredo = env("AGENTE_WA_SEGREDO");
  if (!segredo) return json({ erro: "canal não configurado" }, 503);
  if (!iguais(new URL(req.url).searchParams.get("s") ?? "", segredo)) return json({ erro: "não autorizado" }, 401);
  const raw = await req.text();
  if (raw.length > MAX_BODY) return json({ erro: "payload grande demais" }, 413);

  // 1) repassa TUDO ao webhook antigo, sem mudar nada (Finance AI, grupos, DDD 82)
  let repasse = 0;
  const antigo = env("FINANCE_WEBHOOK_URL");
  if (antigo) {
    try {
      const r = await fora.fetch(antigo, { method: "POST", headers: { "content-type": req.headers.get("content-type") ?? "application/json" }, body: raw, signal: AbortSignal.timeout(15_000) });
      repasse = r.status; await r.body?.cancel();
    } catch { repasse = 599; }
  }

  // 2) só o privado autorizado é tratado aqui (o banco decide e deduplica)
  let p: unknown;
  try { p = JSON.parse(raw); } catch { return json({ repasse, erro: "json inválido" }, repasse >= 500 ? 502 : 200); }
  if (typeof p === "object" && p && !Array.isArray(p)) {
    try {
      const d = await b.receber(p);
      if (d.acao === "tratar") fora.depois(tratar(env, b, fora, d));
    } catch (e) {
      console.error(JSON.stringify({ app: "agente-whatsapp", etapa: "receber", erro: String((e as Error)?.message ?? e).slice(0, 200) }));
    }
  }
  // se o repasse falhou, a Z-API reenvia (o banco ignora a repetição)
  return json({ ok: true, repasse }, repasse >= 500 ? 502 : 200);
}
