// Idealize AI — sincronização do agente de Caixa. SÓ LEITURA: ADM por usuário só leitura numa visão sem clientes;
// Asaas só GET em /payments. Só roda com: segredo do worker, cx.sync.ativo = true, agente ATIVO e credencial do ADM.
import postgres from "npm:postgres@3.4.5";
import { diaAdm, pagamentoAdm, recebimentosAsaas, tokensAsaas, type Obj } from "./normalizar.ts";

const EXECUTOR = "caixa-sync";
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

export async function lerAdm(url: string, desde: string, ate: string): Promise<{ dias: Obj[]; pagamentos: Obj[] }> {
  const adm = postgres(url, { max: 1, prepare: false, idle_timeout: 5, connect_timeout: 10 });
  try {
    return await adm.begin("read only", async (t) => ({
      dias: (await t`select unidade, data, status, caixa, dinheiro_gaveta, deposito_valor, deposito_data
                     from idealize_ai.caixa_dias where data between ${desde}::date and ${ate}::date`) as unknown as Obj[],
      pagamentos: (await t`select unidade, data, origem, forma, valor
                           from idealize_ai.caixa_pagamentos where data between ${desde}::date and ${ate}::date`) as unknown as Obj[],
    }));
  } finally {
    await adm.end();
  }
}

// Cliente mínimo do Asaas: só GET em api.asaas.com/v3/payments, paginação por offset com limite.
export async function cobrancasAsaas(token: string, params: [string, string][], f: typeof fetch = fetch, maxPaginas = 50): Promise<Obj[]> {
  const itens: Obj[] = [];
  for (let pagina = 0, offset = 0; ; pagina++) {
    if (pagina >= maxPaginas) throw new Error(`Asaas: mais de ${maxPaginas} páginas; leitura interrompida`);
    const u = new URL("https://api.asaas.com/v3/payments");
    for (const [k, v] of params) u.searchParams.append(k, v);
    u.searchParams.set("limit", "100"); u.searchParams.set("offset", String(offset));
    let corpo: Obj | null = null;
    for (let tentativa = 0; ; tentativa++) {
      const r = await f(u, { method: "GET", headers: { access_token: token, accept: "application/json", "user-agent": "idealize-ai" } });
      if (r.status === 429 && tentativa < 3) { await espera(3000 * (tentativa + 1)); continue; }
      if (!r.ok) throw new Error(`Asaas: HTTP ${r.status}`);
      corpo = await r.json() as Obj;
      break;
    }
    const dados = Array.isArray(corpo?.data) ? (corpo!.data as Obj[]) : [];
    itens.push(...dados);
    if (!corpo?.hasMore || !dados.length) return itens;
    offset += dados.length;
    await espera(200);
  }
}

export async function lerAsaas(token: string, desde: string, ate: string, f: typeof fetch = fetch): Promise<Obj[]> {
  const recebidas = await cobrancasAsaas(token, [["paymentDate[ge]", desde], ["paymentDate[le]", ate]], f);
  // cartão aprovado que ainda não caiu na conta: status CONFIRMED, sem data de pagamento
  const inicio = new Date(Date.parse(desde) - 5 * 86400000).toISOString().slice(0, 10);
  const confirmadas = await cobrancasAsaas(token, [["status", "CONFIRMED"], ["dateCreated[ge]", inicio], ["dateCreated[le]", ate]], f);
  const vistos = new Set<string>();
  return recebimentosAsaas([...recebidas, ...confirmadas].filter((c) => {
    const id = String(c.id); if (vistos.has(id)) return false; vistos.add(id); return true;
  })).filter((r) => (r.dia as string) >= desde && (r.dia as string) <= ate);
}

export async function executar(): Promise<Record<string, unknown>> {
  const [{ ativo }] = await db()`select core.cfg('cx.sync.ativo','false') = 'true' as ativo`;
  if (!ativo) return { status: "desligado" };
  const url = Deno.env.get("ADM_LEITURA_DB_URL");
  if (!url) return { status: "sem_credencial_do_adm" };
  await db()`select cx.agendar_sincronizacao()`;
  const rows = await db()`select id from core.reivindicar('caixa', ${EXECUTOR}, 900)`;
  if (!rows.length) return { tarefas: 0 };
  const tarefa = rows[0].id as string;
  const [{ j }] = await db()`select cx.proxima_janela() as j`;
  const desde = String(j.desde), ate = String(j.ate);
  let lote: Obj;
  try {
    const adm = await lerAdm(url, desde, ate);
    const asaas: Obj[] = [];
    for (const { unidade, token } of tokensAsaas(Deno.env.get("ASAAS_TOKENS"))) {
      asaas.push({ unidade_id: unidade, ate, pagamentos: await lerAsaas(token, desde, ate) });
    }
    lote = { desde, ate, adm: { dias: adm.dias.flatMap((x) => diaAdm(x) ?? []), pagamentos: adm.pagamentos.flatMap((x) => pagamentoAdm(x) ?? []) }, asaas };
  } catch (e) {
    const erro = String(e instanceof Error ? e.message : e).slice(0, 300);
    log("leitura_falhou", { tarefa, erro });
    await db()`select core.registrar_execucao(${tarefa}::uuid, ${EXECUTOR}, 'erro', null, null, ${"leitura: " + erro})`;
    return { tarefa, status: "erro_leitura" };
  }
  const [{ r }] = await db()`select cx.concluir_sincronizacao(${tarefa}::uuid, ${EXECUTOR}, ${db().json(lote as any)}) as r`;
  const [{ v }] = await db()`select cx.validar_sincronizacao(${tarefa}::uuid, ${VALIDADOR}) as v`;
  log("sincronizado", { tarefa, dias: r.dias, pagamentos: r.pagamentos, recebimentos: r.recebimentos, validacao: v });
  return { tarefa, resultado: r, validacao: v };
}

export async function fechar() { await sql?.end(); sql = null; }
