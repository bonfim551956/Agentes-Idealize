// Download e validação de mídia: só HTTPS, só hosts permitidos, limite de tamanho e tipo real pelos bytes.
export type Tipo = { mime: string; ext: string };

export function detectar(b: Uint8Array): Tipo | null {
  const s = (i: number, n: number) => String.fromCharCode(...b.slice(i, i + n));
  if (b.length < 12) return null;
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return { mime: "image/jpeg", ext: "jpg" };
  if (b[0] === 0x89 && s(1, 3) === "PNG") return { mime: "image/png", ext: "png" };
  if (s(0, 4) === "RIFF" && s(8, 4) === "WEBP") return { mime: "image/webp", ext: "webp" };
  if (s(0, 5) === "%PDF-") return { mime: "application/pdf", ext: "pdf" };
  return null;
}

export function hostPermitido(url: string, hosts: string): boolean {
  let u: URL;
  try { u = new URL(url); } catch { return false; }
  if (u.protocol !== "https:" || u.username || u.password) return false;
  const lista = hosts.split(",").map((h) => h.trim().toLowerCase()).filter(Boolean);
  const h = u.hostname.toLowerCase();
  return lista.some((x) => h === x || h.endsWith("." + x));
}

export class MidiaRecusada extends Error {}

export async function baixar(url: string, hosts: string, maxBytes: number, f: typeof fetch = fetch): Promise<Uint8Array> {
  if (!hostPermitido(url, hosts)) throw new MidiaRecusada("host de mídia não permitido");
  const r = await f(url, { signal: AbortSignal.timeout(30_000), redirect: "manual" });
  if (r.status >= 300 && r.status < 400) throw new MidiaRecusada("redirecionamento recusado");
  if (r.status === 404 || r.status === 410) throw new MidiaRecusada(`mídia indisponível (HTTP ${r.status})`);
  if (!r.ok) throw new Error(`download falhou: HTTP ${r.status}`); // transitório → nova tentativa
  if (Number(r.headers.get("content-length") ?? 0) > maxBytes) throw new MidiaRecusada("mídia maior que o limite");
  const buf = new Uint8Array(await r.arrayBuffer());
  if (buf.length > maxBytes) throw new MidiaRecusada("mídia maior que o limite");
  return buf;
}

export async function sha256(b: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", b));
  return [...h].map((x) => x.toString(16).padStart(2, "0")).join("");
}
