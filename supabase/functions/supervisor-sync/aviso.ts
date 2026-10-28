// Supervisor — envio do aviso pelo Z-API (texto). Só para os destinos que o banco devolve (sup.destinos()).
import { semSegredo } from "./segredo.ts";

export type Zapi = { instancia: string; token: string; clientToken: string };

export function configZapi(env: (k: string) => string | undefined): Zapi | null {
  const instancia = env("SUP_ZAPI_INSTANCIA") ?? "", token = env("SUP_ZAPI_TOKEN") ?? "", clientToken = env("SUP_ZAPI_CLIENT_TOKEN") ?? "";
  if (!/^[A-Za-z0-9]{10,64}$/.test(instancia) || !/^[A-Za-z0-9]{10,64}$/.test(token) || clientToken.length < 10) return null;
  return { instancia, token, clientToken };
}

// Envia para todos; só conta como enviado se TODOS os destinos aceitaram.
export async function enviar(z: Zapi, destinos: string[], texto: string, f: typeof fetch = fetch): Promise<{ ok: boolean; erro?: string }> {
  const validos = destinos.filter((d) => /^55[0-9]{10,11}$/.test(d));
  if (!validos.length) return { ok: false, erro: "nenhum destino válido" };
  const u = `https://api.z-api.io/instances/${z.instancia}/token/${z.token}/send-text`;
  const erros: string[] = [];
  for (const phone of validos) {
    try {
      const r = await f(u, { method: "POST", headers: { "content-type": "application/json", "client-token": z.clientToken },
        body: JSON.stringify({ phone, message: texto }) });
      if (!r.ok) erros.push(`HTTP ${r.status}`);
      await r.body?.cancel();
    } catch (e) {
      erros.push(semSegredo(e).slice(0, 80));
    }
  }
  return erros.length ? { ok: false, erro: `${erros.length} de ${validos.length} falharam: ${erros.join("; ")}` } : { ok: true };
}
