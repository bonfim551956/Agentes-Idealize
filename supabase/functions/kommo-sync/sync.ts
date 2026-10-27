// Idealize AI — sincronização do agente Comercial (Kommo), SÓ LEITURA (somente GET).
// Só roda com: segredo do worker, chave com.sync.ativo = true, agente ATIVO e token da Kommo.
import postgres from "npm:postgres@3.4.5";
import { evento, funil, lead, lista, usuario, type Obj } from "./normalizar.ts";

const EXECUTOR = "kommo-sync";
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

// Cliente mínimo: só GET, só no subdomínio configurado, paginação com limite de páginas.
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

async function todas(buscar: Buscar, caminho: string, chave: string, params: [string, string][], limite: number, maxPaginas = 50) {
  const itens: Obj[] = [];
  for (let page = 1; page <= maxPaginas; page++) {
    const r = await buscar(caminho, [...params, ["limit", String(limite)], ["page", String(page)]]);
    const xs = (((r?._embedded ?? {}) as Obj)[chave] ?? []) as Obj[];
    itens.push(...xs);
    if (!r || xs.length < limite || !((r._links ?? {}) as Obj).next) return itens;
    await espera(200); // fica bem abaixo do limite de 7 pedidos/s da Kommo
  }
  throw new Error(`Kommo ${caminho}: mais de ${maxPaginas} páginas na janela; leitura interrompida`);
}

export async function lerKommo(buscar: Buscar, desde: number, ate: number): Promise<Obj> {
  const usuarios = lista(await todas(buscar, "users", "users", [], 250), usuario);
  const pf = await buscar("leads/pipelines", []);
  const funis = lista((((pf?._embedded ?? {}) as Obj).pipelines ?? []) as Obj[], funil);
  const leads = lista(await todas(buscar, "leads", "leads",
    [["filter[updated_at][from]", String(desde)], ["filter[updated_at][to]", String(ate)]], 250), lead);
  const eventos = lista(await todas(buscar, "events", "events", [
    ["filter[type][]", "incoming_chat_message"], ["filter[type][]", "outgoing_chat_message"],
    ["filter[created_at][from]", String(desde)], ["filter[created_at][to]", String(ate)]], 100), evento);
  return { desde, ate, usuarios, funis, leads, eventos };
}

export async function executar(criarBusca?: () => Buscar): Promise<Record<string, unknown>> {
  const [{ ativo }] = await db()`select core.cfg('com.sync.ativo','false') = 'true' as ativo`;
  if (!ativo) return { status: "desligado" };
  const token = Deno.env.get("KOMMO_TOKEN"), sub = Deno.env.get("KOMMO_SUBDOMINIO");
  if (!token || !sub) return { status: "sem_credencial_da_kommo" };
  await db()`select com.agendar_sincronizacao()`;
  const rows = await db()`select id from core.reivindicar('comercial', ${EXECUTOR}, 600)`;
  if (!rows.length) return { tarefas: 0 }; // agente pausado, plataforma pausada ou nada na fila
  const tarefa = rows[0].id as string;
  const [{ j }] = await db()`select com.proxima_janela() as j`;
  let lote: Obj;
  try {
    lote = await lerKommo(criarBusca ? criarBusca() : clienteKommo(sub, token), Number(j.desde), Number(j.ate));
  } catch (e) {
    const erro = String(e instanceof Error ? e.message : e).slice(0, 300);
    log("leitura_falhou", { tarefa, erro });
    await db()`select core.registrar_execucao(${tarefa}::uuid, ${EXECUTOR}, 'erro', null, null, ${"leitura da Kommo: " + erro})`;
    return { tarefa, status: "erro_leitura" };
  }
  const [{ r }] = await db()`select com.concluir_sincronizacao(${tarefa}::uuid, ${EXECUTOR}, ${db().json(lote as any)}) as r`;
  const [{ v }] = await db()`select com.validar_sincronizacao(${tarefa}::uuid, ${VALIDADOR}) as v`;
  log("sincronizado", { tarefa, leads: r.leads, mensagens_novas: r.mensagens_novas, validacao: v });
  return { tarefa, resultado: r, validacao: v };
}

export async function fechar() { await sql?.end(); sql = null; }
