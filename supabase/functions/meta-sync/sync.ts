// Idealize AI — sincronização do agente de Marketing (Meta Ads), SÓ LEITURA (somente GET, permissão ads_read).
// Só roda com: segredo do worker, chave mkt.sync.ativo = true, agente ATIVO e pelo menos um token da Meta.
import postgres from "npm:postgres@3.4.5";
import { anuncio, campanha, conta, lista, metrica, type Obj } from "./normalizar.ts";

const EXECUTOR = "meta-sync";
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

// Um ou mais tokens (um por Business Manager), separados por vírgula ou quebra de linha
export const tokens = (s: string | undefined) => (s ?? "").split(/[\s,]+/).map((t) => t.trim()).filter((t) => t.length >= 20);

export type Buscar = (caminho: string, params: [string, string][]) => Promise<Obj[]>;

// Cliente mínimo: só GET, só em graph.facebook.com, segue a paginação da própria Meta com limite de páginas.
export function clienteMeta(token: string, versao: string, f: typeof fetch = fetch, maxPaginas = 40): Buscar {
  if (!/^v\d{1,2}\.\d$/.test(versao)) throw new Error("versão da Graph API inválida");
  return async (caminho, params) => {
    let u: URL | null = new URL(`https://graph.facebook.com/${versao}/${caminho}`);
    for (const [k, v] of params) u.searchParams.append(k, v);
    const itens: Obj[] = [];
    for (let pagina = 0; u; pagina++) {
      if (pagina >= maxPaginas) throw new Error(`Meta ${caminho}: mais de ${maxPaginas} páginas; leitura interrompida`);
      if (u.hostname !== "graph.facebook.com" || u.protocol !== "https:") throw new Error("paginação apontou para fora da Meta");
      let corpo: Obj | null = null;
      for (let tentativa = 0; ; tentativa++) {
        const r = await f(u, { method: "GET", headers: { authorization: `Bearer ${token}`, accept: "application/json" } });
        corpo = await r.json().catch(() => null) as Obj | null;
        const erro = (corpo?.error ?? null) as Obj | null;
        const limite = erro && [4, 17, 32, 613, 80000, 80004].includes(Number(erro.code));
        if ((r.status === 429 || limite) && tentativa < 3) { await espera(2000 * (tentativa + 1)); continue; }
        if (!r.ok || erro) throw new Error(`Meta ${caminho}: HTTP ${r.status}${erro ? ` código ${String(erro.code)}` : ""}`);
        break;
      }
      itens.push(...(Array.isArray(corpo?.data) ? (corpo!.data as Obj[]) : []));
      const prox = ((corpo?.paging ?? {}) as Obj).next;
      u = typeof prox === "string" ? new URL(prox) : null;
      if (u) { u.searchParams.delete("access_token"); await espera(150); }
    }
    return itens;
  };
}

export async function lerMeta(buscas: Buscar[], desde: string, ate: string): Promise<Obj> {
  const contas = new Map<string, Obj>(), dono = new Map<string, Buscar>();
  for (const b of buscas) {
    for (const c of lista(await b("me/adaccounts", [["fields", "account_id,name,account_status,disable_reason,currency"], ["limit", "100"]]), conta)) {
      if (!contas.has(c.id as string)) { contas.set(c.id as string, c); dono.set(c.id as string, b); }
    }
  }
  const campanhas = new Map<string, Obj>(); const metricas: Obj[] = []; const anuncios: Obj[] = [];
  for (const [id, b] of dono) {
    const act = `act_${id}`;
    for (const c of lista(await b(`${act}/campaigns`, [["fields", "id,name,objective,effective_status,daily_budget"], ["limit", "200"]]), (x) => campanha(x, id)))
      campanhas.set(c.id as string, c);
    const linhas = await b(`${act}/insights`, [["level", "campaign"], ["time_increment", "1"],
      ["time_range", JSON.stringify({ since: desde, until: ate })],
      ["fields", "campaign_id,campaign_name,spend,impressions,reach,clicks,actions"], ["limit", "500"]]);
    for (const l of linhas) {
      const m = metrica(l, id);
      if (!m) continue;
      metricas.push(m);
      if (!campanhas.has(m.campanha_id as string)) {   // campanha arquivada que ainda tem gasto na janela
        const c = campanha({ id: l.campaign_id, name: l.campaign_name }, id);
        if (c) campanhas.set(c.id as string, c);
      }
    }
    anuncios.push(...lista(await b(`${act}/ads`, [["fields", "id,name,campaign_id,effective_status"],
      ["filtering", JSON.stringify([{ field: "effective_status", operator: "IN", value: ["DISAPPROVED", "WITH_ISSUES"] }])],
      ["limit", "200"]]), (x) => anuncio(x, id)));
  }
  return { desde, ate, contas: [...contas.values()], campanhas: [...campanhas.values()], metricas, anuncios_problema: anuncios };
}

export async function executar(criarBuscas?: (versao: string) => Buscar[]): Promise<Record<string, unknown>> {
  const [{ ativo }] = await db()`select core.cfg('mkt.sync.ativo','false') = 'true' as ativo`;
  if (!ativo) return { status: "desligado" };
  const ts = tokens(Deno.env.get("META_TOKENS"));
  if (!ts.length) return { status: "sem_credencial_da_meta" };
  await db()`select mkt.agendar_sincronizacao()`;
  const rows = await db()`select id from core.reivindicar('marketing', ${EXECUTOR}, 900)`;
  if (!rows.length) return { tarefas: 0 }; // agente pausado, plataforma pausada ou nada na fila
  const tarefa = rows[0].id as string;
  const [{ j }] = await db()`select mkt.proxima_janela() as j`;
  let lote: Obj;
  try {
    const buscas = criarBuscas ? criarBuscas(j.versao) : ts.map((t) => clienteMeta(t, j.versao));
    lote = await lerMeta(buscas, String(j.desde), String(j.ate));
  } catch (e) {
    const erro = String(e instanceof Error ? e.message : e).slice(0, 300);
    log("leitura_falhou", { tarefa, erro });
    await db()`select core.registrar_execucao(${tarefa}::uuid, ${EXECUTOR}, 'erro', null, null, ${"leitura da Meta: " + erro})`;
    return { tarefa, status: "erro_leitura" };
  }
  const [{ r }] = await db()`select mkt.concluir_sincronizacao(${tarefa}::uuid, ${EXECUTOR}, ${db().json(lote as any)}) as r`;
  const [{ v }] = await db()`select mkt.validar_sincronizacao(${tarefa}::uuid, ${VALIDADOR}) as v`;
  log("sincronizado", { tarefa, contas: r.contas, linhas: r.linhas, validacao: v });
  return { tarefa, resultado: r, validacao: v };
}

export async function fechar() { await sql?.end(); sql = null; }
