// Idealize AI — ciclo do Agente Supervisor.
// Só roda com: segredo do worker, sup.sync.ativo = true e agente ATIVO (roda mesmo com o modo seguro ligado).
// Lê a fonte só por GET / conexão só leitura. Envia aviso só se sup.enviar = true (senão fica em sombra no banco).
import postgres from "npm:postgres@3.4.5";
import { itensLab, lerAsaas, lerKommo, tokensAsaas, type Item, type Obj } from "./fontes.ts";
import { configZapi, enviar } from "./aviso.ts";
import { semSegredo } from "./segredo.ts";

const EXECUTOR = "supervisor-sync";
const VALIDADOR = "validador_sql";
let sql: ReturnType<typeof postgres> | null = null;
const db = () => (sql ??= postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 2, prepare: false, idle_timeout: 20 }));
const log = (evento: string, dados: Record<string, unknown>) => console.log(JSON.stringify({ app: EXECUTOR, evento, ...dados }));

export function iguais(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let d = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) d |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return d === 0;
}

async function lerLab(ids: string[], url: string): Promise<Item[]> {
  const adm = postgres(url, { max: 1, prepare: false, idle_timeout: 5, connect_timeout: 10 });
  try {
    const linhas = await adm.begin("read only", (t) => t`
      select id, col, cancelado, nao_retirado, ts from idealize_ai.lab_os where id::text = any(${ids})`) as unknown as Obj[];
    return itensLab(ids, linhas);
  } finally {
    await adm.end();
  }
}

// Sorteia no espelho e lê na fonte. Só confere agente que está ligado; falha de uma fonte não derruba as outras.
async function amostras(): Promise<{ lote: Record<string, Item[]>; pulos: Record<string, string> }> {
  const lote: Record<string, Item[]> = {}, pulos: Record<string, string> = {};
  const ligados = new Set((await db()`select agente_id from sup.v_saude where status = 'ativo' and sync_ativo`).map((r) => r.agente_id as string));
  const env = (k: string) => Deno.env.get(k);
  const fontes: [string, (ped: Obj[]) => Promise<Item[]> | null][] = [
    ["cobrancas", (ped) => { const tk = tokensAsaas(env("ASAAS_TOKENS")); return tk.size ? lerAsaas(ped as { id: string; unidade_id: string }[], tk) : null; }],
    ["comercial", (ped) => { const s = env("KOMMO_SUBDOMINIO"), t = env("KOMMO_TOKEN"); return s && t ? lerKommo(ped.map((p) => String(p.id)), s, t) : null; }],
    ["laboratorio", (ped) => { const u = env("ADM_LEITURA_DB_URL"); return u ? lerLab(ped.map((p) => String(p.id)), u) : null; }],
  ];
  for (const [agente, ler] of fontes) {
    if (!ligados.has(agente)) { pulos[agente] = "agente desligado"; continue; }
    try {
      const [{ p }] = await db()`select sup.amostra_pedir(${agente}) as p`;
      const pedidos = (p ?? []) as Obj[];
      if (!pedidos.length) { pulos[agente] = "espelho vazio"; continue; }
      const leitura = ler(pedidos);
      if (!leitura) { pulos[agente] = "sem credencial de leitura"; continue; }
      lote[agente] = await leitura;
    } catch (e) {
      pulos[agente] = "falha na leitura da fonte: " + semSegredo(e).slice(0, 120);
      log("amostra_falhou", { agente, erro: pulos[agente] });
    }
  }
  return { lote, pulos };
}

export async function executar(): Promise<Record<string, unknown>> {
  const [{ ativo }] = await db()`select core.cfg('sup.sync.ativo','false') = 'true' as ativo`;
  if (!ativo) return { status: "desligado" };
  await db()`select sup.agendar_verificacao()`;
  const rows = await db()`select id from core.reivindicar('supervisor', ${EXECUTOR}, 600)`;
  if (!rows.length) return { tarefas: 0 };
  const tarefa = rows[0].id as string;

  let am: Awaited<ReturnType<typeof amostras>>;
  try {
    am = await amostras();
  } catch (e) {
    const erro = semSegredo(e).slice(0, 300);
    await db()`select core.registrar_execucao(${tarefa}::uuid, ${EXECUTOR}, 'erro', null, null, ${"amostragem: " + erro})`;
    return { tarefa, status: "erro" };
  }
  const falhas = Object.fromEntries(Object.entries(am.pulos).filter(([, m]) => m.startsWith("falha")));
  const [{ r }] = await db()`select sup.concluir_verificacao(${tarefa}::uuid, ${EXECUTOR}, ${db().json(am.lote as any)}, ${db().json(falhas as any)}) as r`;
  await db()`select sup.preparar_mensagens(${tarefa}::uuid)`;
  const [{ v }] = await db()`select sup.validar_verificacao(${tarefa}::uuid, ${VALIDADOR}) as v`;

  // envio: só o que continua pendente depois da conferência (reprovada → avisos bloqueados)
  const pendentes = await db()`select id, texto from sup.mensagens where tarefa_id = ${tarefa}::uuid and status = 'pendente' order by id`;
  const enviados: Record<string, unknown>[] = [];
  if (pendentes.length) {
    const z = configZapi((k) => Deno.env.get(k));
    const [{ d }] = await db()`select sup.destinos() as d`;
    for (const m of pendentes) {
      const res = z ? await enviar(z, d as string[], m.texto as string) : { ok: false, erro: "sem credencial do Z-API" };
      await db()`select sup.mensagem_resultado(${m.id}::bigint, ${res.ok}, ${res.erro ?? null})`;
      enviados.push({ id: m.id, ok: res.ok });
    }
  }
  log("verificado", { tarefa, abertos: r.abertos, novos: r.novos, resolvidos: r.resolvidos, validacao: v, pulos: am.pulos, enviados });
  return { tarefa, resultado: r, validacao: v, pulos: am.pulos, enviados };
}

export async function fechar() { await sql?.end(); sql = null; }
