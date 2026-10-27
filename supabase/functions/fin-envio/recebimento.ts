// Idealize AI — recebimento de arquivos da central de envio do painel.
// Quem envia é a PESSOA logada (o login e o 2FA dela vão junto): o banco confere a permissão na loja,
// recusa formato/tamanho e avisa arquivo repetido. Esta função só grava o arquivo no armazenamento privado
// e confirma ao banco o hash e o tamanho refeitos sobre os bytes recebidos. Não lê nem lança nada.
export type Env = (k: string) => string | undefined;
export type Banco = { recebido: (id: string, tamanho: number, sha: string) => Promise<string> };

export const TIPOS = ["auto", "extrato", "fatura", "stone", "comprovante", "boleto", "nota"];
const MAX = 20 * 1024 * 1024;

export async function sha256(b: Uint8Array): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", b))].map((x) => x.toString(16).padStart(2, "0")).join("");
}

export function cors(origem: string | null, env: Env): Record<string, string> {
  const permitidas = (env("PAINEL_ORIGENS") ?? "https://idealize-ai-painel.vercel.app").split(",").map((s) => s.trim()).filter(Boolean);
  const ok = origem && permitidas.includes(origem) ? origem : permitidas[0];
  return { "access-control-allow-origin": ok, "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
    "access-control-allow-methods": "POST, OPTIONS", vary: "origin" };
}

const resp = (status: number, corpo: unknown, h: Record<string, string>) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...h, "content-type": "application/json" } });

export async function receber(req: Request, env: Env, banco: Banco, f: typeof fetch = fetch): Promise<Response> {
  const h = cors(req.headers.get("origin"), env);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: h });
  if (req.method !== "POST") return resp(405, { erro: "use POST" }, h);
  const auth = req.headers.get("authorization") ?? "";
  if (!/^Bearer [A-Za-z0-9._-]{20,}$/.test(auth)) return resp(401, { erro: "faça login no painel" }, h);
  const url = env("SUPABASE_URL"), anon = env("SUPABASE_ANON_KEY"), servico = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !servico) return resp(503, { erro: "recebimento não configurado" }, h);

  let form: FormData;
  try { form = await req.formData(); } catch { return resp(400, { erro: "envio inválido" }, h); }
  const arquivo = form.get("arquivo"), unidade = String(form.get("unidade") ?? ""), tipo = String(form.get("tipo") ?? "auto");
  const conta = form.get("conta") ? String(form.get("conta")) : null;
  if (!(arquivo instanceof File)) return resp(400, { erro: "nenhum arquivo" }, h);
  if (!TIPOS.includes(tipo)) return resp(400, { erro: "tipo inválido" }, h);
  if (arquivo.size < 1 || arquivo.size > MAX) return resp(400, { erro: "arquivo vazio ou acima de 20 MB" }, h);
  const bytes = new Uint8Array(await arquivo.arrayBuffer());
  const hash = await sha256(bytes);

  // 1) o banco, como a própria pessoa: permissão, formato, tamanho, repetido
  const r = await f(`${url}/rest/v1/rpc/painel_envio_iniciar`, { method: "POST",
    headers: { apikey: anon, authorization: auth, "content-type": "application/json" },
    body: JSON.stringify({ p_unidade: unidade, p_tipo: tipo, p_conta: conta, p_nome: arquivo.name, p_mime: arquivo.type || "application/octet-stream",
      p_tamanho: bytes.length, p_sha256: hash }) });
  const corpo = await r.json().catch(() => null) as Record<string, unknown> | null;
  if (!r.ok) return resp(r.status === 401 || r.status === 403 ? 403 : 400, { erro: String(corpo?.message ?? "envio recusado").slice(0, 200) }, h);
  if (corpo?.duplicado) return resp(200, { duplicado: true, id: corpo.id, status: corpo.status }, h);
  const id = String(corpo?.id ?? ""), caminho = String(corpo?.caminho ?? "");
  if (!/^[0-9a-f-]{36}$/.test(id) || !/^[a-z0-9_]+\/\d{4}-\d{2}\/[0-9a-f-]{36}\.[a-z0-9]{2,5}$/.test(caminho)) return resp(500, { erro: "resposta inesperada" }, h);

  // 2) grava no armazenamento privado (sem sobrescrever)
  const chaves: Record<string, string> = servico.startsWith("eyJ") ? { apikey: servico, authorization: `Bearer ${servico}` } : { apikey: servico };
  const g = await f(`${url}/storage/v1/object/fin-envios/${caminho}`, { method: "POST",
    headers: { ...chaves, "content-type": "application/octet-stream", "x-upsert": "false" }, body: bytes });
  if (!g.ok) { await g.body?.cancel(); return resp(502, { erro: "não consegui guardar o arquivo; tente de novo" }, h); }
  await g.body?.cancel();

  // 3) confirma ao banco o que realmente chegou
  const st = await banco.recebido(id, bytes.length, hash);
  return resp(200, { duplicado: false, id, status: st }, h);
}
