// Idealize AI — webhook do canal WhatsApp do agente financeiro (Z-API "Ao receber").
// Só autentica, limita tamanho e entrega o evento ao banco (fin.receber_whatsapp), que decide tudo:
// canal desligado, grupo, remetente, permissão, duplicidade e criação da tarefa no core.
// Sem segredo configurado, recusa tudo (falha fechada).
import postgres from "npm:postgres@3.4.5";

const MAX_BODY = 512 * 1024;
let sql: ReturnType<typeof postgres> | null = null;
const db = () => (sql ??= postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 2, prepare: false, idle_timeout: 20 }));

export function iguais(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let d = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) d |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return d === 0;
}

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

export async function tratar(req: Request, entregar: (p: unknown) => Promise<unknown>, segredo: string | undefined) {
  if (req.method !== "POST") return json({ ok: true });
  if (!segredo) return json({ erro: "canal não configurado" }, 503);
  const s = new URL(req.url).searchParams.get("s") ?? "";
  if (!iguais(s, segredo)) return json({ erro: "não autorizado" }, 401);
  const raw = await req.text();
  if (raw.length > MAX_BODY) return json({ erro: "payload grande demais" }, 413);
  let b: unknown;
  try { b = JSON.parse(raw); } catch { return json({ erro: "json inválido" }, 400); }
  if (typeof b !== "object" || b === null || Array.isArray(b)) return json({ erro: "json inválido" }, 400);
  try {
    return json(await entregar(b));
  } catch (e) {
    console.error(JSON.stringify({ app: "fin-whatsapp-webhook", erro: String(e) }));
    return json({ erro: "falha interna" }, 500); // 5xx → Z-API reenvia; o banco deduplica
  }
}

export const entregarNoBanco = async (p: unknown) => {
  const [r] = await db()`select fin.receber_whatsapp(${db().json(p as any)}) as r`;
  return r.r;
};
