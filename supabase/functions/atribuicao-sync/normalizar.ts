// Atribuição: o telefone só existe em memória, para virar um código irreversível (HMAC-SHA256 com segredo da plataforma).
// O lote nunca leva telefone, nome ou e-mail: só o código, a loja (pelo funil), a data e a origem do lead.
export type Obj = Record<string, unknown>;

// Mesma pessoa com ou sem 55, 0 ou o nono dígito: DDD + 8 últimos dígitos
export function chaveTelefone(bruto: unknown): string | null {
  let d = String(bruto ?? "").replace(/\D/g, "");
  if (d.startsWith("55") && d.length >= 12) d = d.slice(2);
  d = d.replace(/^0+/, "");
  if (d.length < 10 || d.length > 11) return null;
  return d.slice(0, 2) + d.slice(-8);
}

export async function codigoTelefone(bruto: unknown, chave: CryptoKey): Promise<string | null> {
  const k = chaveTelefone(bruto);
  if (!k) return null;
  const sig = await crypto.subtle.sign("HMAC", chave, new TextEncoder().encode(k));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export const importarChave = (segredo: string) =>
  crypto.subtle.importKey("raw", new TextEncoder().encode(segredo), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);

// Origem do lead: etiquetas e campos de UTM/origem/campanha. Número solto de 10 a 13 dígitos (cara de telefone) é apagado.
const CAMPO_ORIGEM = /utm|origem|campanha|campaign|fonte|source|anuncio|an[uú]ncio|ad_id|adset/i;
export function origemLead(l: Obj): string | null {
  const partes: string[] = [];
  const emb = (l._embedded ?? {}) as Obj;
  for (const t of (Array.isArray(emb.tags) ? emb.tags : []) as Obj[]) if (typeof t.name === "string") partes.push(`#${t.name}`);
  for (const c of (Array.isArray(l.custom_fields_values) ? l.custom_fields_values : []) as Obj[]) {
    const nome = String(c.field_code ?? c.field_name ?? "");
    if (!CAMPO_ORIGEM.test(nome)) continue;
    const vals = ((Array.isArray(c.values) ? c.values : []) as Obj[]).map((v) => String(v.value ?? "")).filter(Boolean);
    if (vals.length) partes.push(`${nome}=${vals.join(",")}`);
  }
  const s = partes.join("; ").replace(/(^|[^0-9])[0-9]{10,13}(?![0-9])/g, "$1#").slice(0, 300);
  return s || null;
}

export function contatoPrincipal(l: Obj): number | null {
  const cs = (((l._embedded ?? {}) as Obj).contacts ?? []) as Obj[];
  const c = cs.find((x) => x.is_main) ?? cs[0];
  return typeof c?.id === "number" ? c.id : null;
}

export function telefonesContato(c: Obj): string[] {
  return ((Array.isArray(c.custom_fields_values) ? c.custom_fields_values : []) as Obj[])
    .filter((f) => f.field_code === "PHONE")
    .flatMap((f) => ((f.values ?? []) as Obj[]).map((v) => String(v.value ?? "")));
}
