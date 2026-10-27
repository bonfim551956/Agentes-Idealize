// Supervisor — leitura da FONTE para a conferência por amostragem. Só GET / só leitura.
// Cada leitor devolve, por id, {id, encontrado, campos} com uma lista FECHADA de campos (nada pessoal).
// A comparação com o espelho é feita no banco (sup.amostra_registrar), não aqui.
export type Obj = Record<string, unknown>;
export type Item = { id: string; encontrado: boolean; campos?: Obj };

const espera = (ms: number) => new Promise((r) => setTimeout(r, ms));
const num = (v: unknown) => (typeof v === "number" && isFinite(v) ? v : typeof v === "string" && v.trim() !== "" && isFinite(Number(v)) ? Number(v) : null);
const dia = (v: unknown) => (typeof v === "string" && /^\d{4}-\d{2}-\d{2}/.test(v) ? v.slice(0, 10) : null);

export function tokensAsaas(s: string | undefined): Map<string, string> {
  const m = new Map<string, string>();
  for (const l of (s ?? "").split(/[\n,]+/).map((x) => x.trim())) {
    const i = l.indexOf("=");
    if (i < 1) continue;
    const u = l.slice(0, i).trim(), t = l.slice(i + 1).trim();
    if (/^[a-z_]{2,40}$/.test(u) && t.length >= 20) m.set(u, t);
  }
  return m;
}

export function camposAsaas(c: Obj): Item | null {
  const id = typeof c.id === "string" ? c.id : null;
  if (!id) return null;
  if (c.deleted === true) return { id, encontrado: false };
  return { id, encontrado: true, campos: { status: String(c.status ?? ""), valor: num(c.value), pagamento: dia(c.clientPaymentDate) ?? dia(c.paymentDate) } };
}

export function camposKommo(l: Obj): Item | null {
  if (typeof l.id !== "number") return null;
  if (l.is_deleted === true) return { id: String(l.id), encontrado: false };
  return { id: String(l.id), encontrado: true, campos: { funil_id: num(l.pipeline_id), etapa_id: num(l.status_id),
    responsavel_id: num(l.responsible_user_id), valor: num(l.price) ?? 0, atualizado_em: num(l.updated_at) } };
}

export function camposLab(r: Obj): Item | null {
  if (r.id == null) return null;
  const ts = typeof r.ts === "bigint" ? Number(r.ts) : num(r.ts);
  return { id: String(r.id), encontrado: true, campos: { col: num(r.col), cancelado: r.cancelado === true, nao_retirado: r.nao_retirado === true, ts } };
}

async function getJson(f: typeof fetch, u: URL, headers: Record<string, string>): Promise<{ status: number; corpo: Obj | null }> {
  for (let tentativa = 0; ; tentativa++) {
    const r = await f(u, { method: "GET", headers: { accept: "application/json", ...headers } });
    if (r.status === 429 && tentativa < 3) { await r.body?.cancel(); await espera(1500 * (tentativa + 1)); continue; }
    if (r.status === 404 || r.status === 204) { await r.body?.cancel(); return { status: r.status, corpo: null }; }
    if (!r.ok) { await r.body?.cancel(); throw new Error(`HTTP ${r.status}`); }
    return { status: r.status, corpo: await r.json() as Obj };
  }
}

// Asaas: um GET por cobrança, com a chave da loja dela
export async function lerAsaas(pedidos: { id: string; unidade_id: string }[], tokens: Map<string, string>, f: typeof fetch = fetch): Promise<Item[]> {
  const saida: Item[] = [];
  for (const p of pedidos) {
    const token = tokens.get(p.unidade_id);
    if (!token || !/^[A-Za-z0-9_-]{3,80}$/.test(p.id)) continue;   // sem chave da loja: não confere esse item
    const { corpo } = await getJson(f, new URL(`https://api.asaas.com/v3/payments/${p.id}`), { access_token: token, "user-agent": "idealize-ai" });
    const it = corpo ? camposAsaas(corpo) : { id: p.id, encontrado: false };
    if (it) saida.push(it);
    await espera(150);
  }
  return saida;
}

export async function lerKommo(ids: string[], sub: string, token: string, f: typeof fetch = fetch): Promise<Item[]> {
  if (!/^[a-z0-9-]{2,63}$/.test(sub)) throw new Error("subdomínio da Kommo inválido");
  const saida: Item[] = [];
  for (const id of ids) {
    if (!/^[0-9]{1,15}$/.test(id)) continue;
    const { corpo } = await getJson(f, new URL(`https://${sub}.kommo.com/api/v4/leads/${id}`), { authorization: `Bearer ${token}` });
    const it = corpo ? camposKommo(corpo) : { id, encontrado: false };
    if (it) saida.push(it);
    await espera(150);
  }
  return saida;
}

// ADM: lê as OS sorteadas pela mesma visão sem dados pessoais do agente de Laboratório
export function itensLab(ids: string[], linhas: Obj[]): Item[] {
  const porId = new Map(linhas.map((r) => [String(r.id), r]));
  return ids.map((id) => (porId.has(id) ? camposLab(porId.get(id)!)! : { id, encontrado: false }));
}
