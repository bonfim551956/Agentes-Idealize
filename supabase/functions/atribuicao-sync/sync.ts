// Idealize AI — sincronização do agente de Atribuição. SÓ LEITURA: Kommo (só GET) e ADM (usuário só leitura).
// Telefone vira código HMAC em memória e é descartado. Só roda com segredo do worker, atr.sync.ativo = true,
// agente ATIVO, chave do telefone (ATR_CHAVE_TELEFONE), token da Kommo e leitura do ADM.
import postgres from "npm:postgres@3.4.5";
import { codigoTelefone, contatoPrincipal, importarChave, origemLead, telefonesContato, type Obj } from "./normalizar.ts";

const EXECUTOR = "atribuicao-sync";
const VALIDADOR = "validador_sql";
let sql: ReturnType<typeof postgres> | null = null;
const db = () => (sql ??= postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 2, prepare: false, idle_timeout: 20 }));
const log = (evento: string, dados: Record<string, unknown>) => console.log(JSON.stringify({ app: EXECUTOR, evento, ...dados }));
const espera = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function iguais(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let d = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) d |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return d === 0;
}

export type Buscar = (caminho: string, params: [string, string][]) => Promise<Obj | null>;
export function clienteKommo(subdominio: string, token: string, f: typeof fetch = fetch): Buscar {
  if (!/^[a-z0-9-]{2,63}$/.test(subdominio)) throw new Error("subdomínio da Kommo inválido");
  return async (caminho, params) => {
    const u = new URL(`https://${subdominio}.kommo.com/api/v4/${caminho}`);
    for (const [k, v] of params) u.searchParams.append(k, v);
    for (let tentativa = 0; ; tentativa++) {
      const r = await f(u, { method: "GET", headers: { authorization: `Bearer ${token}`, accept: "application/json" } });
      if (r.status === 204) return null;
      if (r.status === 429 && tentativa < 3) { await espera(1000 * (tentativa + 1)); continue; }
      if (!r.ok) throw new Error(`Kommo ${caminho}: HTTP ${r.status}`);
      return await r.json() as Obj;
    }
  };
}

export async function lerLeads(buscar: Buscar, desde: number, ate: number, chave: CryptoKey): Promise<Obj[]> {
  const leads: Obj[] = [];
  for (let page = 1; page <= 200; page++) {
    const r = await buscar("leads", [["with", "contacts"], ["filter[created_at][from]", String(desde)], ["filter[created_at][to]", String(ate)],
      ["limit", "250"], ["page", String(page)]]);
    const xs = (((r?._embedded ?? {}) as Obj).leads ?? []) as Obj[];
    leads.push(...xs);
    if (!r || xs.length < 250) break;
    await espera(200);
    if (page === 200) throw new Error("Kommo: leads demais na janela; leitura interrompida");
  }
  // telefones dos contatos principais, em lotes de 50 ids
  const ids = [...new Set(leads.map(contatoPrincipal).filter((x): x is number => x != null))];
  const telefone = new Map<number, string>();
  for (let i = 0; i < ids.length; i += 50) {
    const r = await buscar("contacts", ids.slice(i, i + 50).map((id) => ["filter[id][]", String(id)] as [string, string]).concat([["limit", "250"]]));
    for (const c of (((r?._embedded ?? {}) as Obj).contacts ?? []) as Obj[]) {
      const t = telefonesContato(c)[0];
      if (t && typeof c.id === "number") telefone.set(c.id, t);
    }
    await espera(200);
  }
  const saida: Obj[] = [];
  for (const l of leads) {
    if (typeof l.id !== "number" || typeof l.created_at !== "number") continue;
    const cid = contatoPrincipal(l);
    saida.push({ id: l.id, funil_id: l.pipeline_id ?? null,
      responsavel_id: typeof l.responsible_user_id === "number" ? l.responsible_user_id : null, criado_em: l.created_at,
      tel_hash: cid != null && telefone.has(cid) ? await codigoTelefone(telefone.get(cid), chave) : null, origem: origemLead(l) });
  }
  telefone.clear();
  return saida;
}

export async function lerVendas(url: string, chave: CryptoKey): Promise<Obj[]> {
  const adm = postgres(url, { max: 1, prepare: false, idle_timeout: 5, connect_timeout: 10 });
  try {
    const linhas = await adm.begin("read only", (t) => t`
      select id, unidade, dt_venda, tipo, valor_venda, telefone_digitos from idealize_ai.vendas_atribuicao
      where dt_venda >= current_date - 400`) as unknown as Obj[];
    const saida: Obj[] = [];
    for (const v of linhas) {
      const dia = v.dt_venda instanceof Date ? v.dt_venda.toISOString().slice(0, 10) : String(v.dt_venda ?? "").slice(0, 10);
      saida.push({ id: String(v.id), unidade: String(v.unidade ?? ""), dia, tipo: String(v.tipo ?? ""), valor: Number(v.valor_venda ?? 0) || 0,
        tel_hash: await codigoTelefone(v.telefone_digitos, chave) });
    }
    return saida;
  } finally {
    await adm.end();
  }
}

export async function executar(): Promise<Record<string, unknown>> {
  const [{ ativo }] = await db()`select core.cfg('atr.sync.ativo','false') = 'true' as ativo`;
  if (!ativo) return { status: "desligado" };
  const segredo = Deno.env.get("ATR_CHAVE_TELEFONE"), url = Deno.env.get("ADM_LEITURA_DB_URL");
  const token = Deno.env.get("KOMMO_TOKEN"), sub = Deno.env.get("KOMMO_SUBDOMINIO");
  if (!segredo || segredo.length < 32) return { status: "sem_chave_do_telefone" };
  if (!url || !token || !sub) return { status: "sem_credencial" };
  await db()`select atr.agendar_sincronizacao()`;
  const rows = await db()`select id from core.reivindicar('atribuicao', ${EXECUTOR}, 900)`;
  if (!rows.length) return { tarefas: 0 };
  const tarefa = rows[0].id as string;
  const [{ j }] = await db()`select atr.janela() as j`;
  let lote: Obj;
  try {
    const chave = await importarChave(segredo);
    lote = { leads: await lerLeads(clienteKommo(sub, token), Number(j.leads_desde), Number(j.ate), chave), vendas: await lerVendas(url, chave) };
  } catch (e) {
    const erro = String(e instanceof Error ? e.message : e).slice(0, 300);
    log("leitura_falhou", { tarefa, erro });
    await db()`select core.registrar_execucao(${tarefa}::uuid, ${EXECUTOR}, 'erro', null, null, ${"leitura: " + erro})`;
    return { tarefa, status: "erro_leitura" };
  }
  const [{ r }] = await db()`select atr.concluir_sincronizacao(${tarefa}::uuid, ${EXECUTOR}, ${db().json(lote as any)}) as r`;
  const [{ v }] = await db()`select atr.validar_sincronizacao(${tarefa}::uuid, ${VALIDADOR}) as v`;
  log("sincronizado", { tarefa, leads: r.leads, vendas: r.vendas, conversoes: r.conversoes, validacao: v });
  return { tarefa, resultado: r, validacao: v };
}

export async function fechar() { await sql?.end(); sql = null; }
