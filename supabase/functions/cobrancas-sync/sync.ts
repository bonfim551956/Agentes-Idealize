// Idealize AI — sincronização do agente de Cobranças. SÓ LEITURA: ADM por usuário só leitura numa visão sem dados
// pessoais; Asaas só GET em /payments. Só roda com: segredo do worker, cob.sync.ativo = true, agente ATIVO e credencial do ADM.
import postgres from "npm:postgres@3.4.5";
import { cobrancaAsaas, parcelaAdm, tokensAsaas, type Obj } from "./normalizar.ts";

const EXECUTOR = "cobrancas-sync";
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

export async function lerAdm(url: string): Promise<Obj[]> {
  const adm = postgres(url, { max: 1, prepare: false, idle_timeout: 5, connect_timeout: 10 });
  try {
    return await adm.begin("read only", (t) => t`
      select id, crediario_id, unidade, financeira, numero, num_parcelas, valor, dt_vencimento, dt_pagamento, status, os, os_fake,
             carne_status, renegociado, dt_compra, valor_crediario, valor_entrada, entrada_paga, dt_entrada
      from idealize_ai.crediario_parcelas`) as unknown as Obj[];
  } finally {
    await adm.end();
  }
}

export async function cobrancasAsaas(token: string, params: [string, string][], f: typeof fetch = fetch, maxPaginas = 60): Promise<Obj[]> {
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

// Retrato do Asaas da loja: tudo em aberto (pendente/vencido) + o que foi pago desde a data informada
export async function lerAsaas(token: string, pagosDesde: string, f: typeof fetch = fetch): Promise<Obj[]> {
  const listas = [
    await cobrancasAsaas(token, [["status", "PENDING"]], f),
    await cobrancasAsaas(token, [["status", "OVERDUE"]], f),
    await cobrancasAsaas(token, [["paymentDate[ge]", pagosDesde]], f),
  ];
  const vistos = new Map<string, Obj>();
  for (const c of listas.flat()) { const n = cobrancaAsaas(c); if (n && !vistos.has(n.id as string)) vistos.set(n.id as string, n); }
  return [...vistos.values()];
}

export async function executar(): Promise<Record<string, unknown>> {
  const [{ ativo }] = await db()`select core.cfg('cob.sync.ativo','false') = 'true' as ativo`;
  if (!ativo) return { status: "desligado" };
  const url = Deno.env.get("ADM_LEITURA_DB_URL");
  if (!url) return { status: "sem_credencial_do_adm" };
  await db()`select cob.agendar_sincronizacao()`;
  const rows = await db()`select id from core.reivindicar('cobrancas', ${EXECUTOR}, 900)`;
  if (!rows.length) return { tarefas: 0 };
  const tarefa = rows[0].id as string;
  const [{ j }] = await db()`select cob.janela_asaas() as j`;
  let lote: Obj;
  try {
    const parcelas = (await lerAdm(url)).flatMap((x) => parcelaAdm(x) ?? []);
    const asaas: Obj[] = [];
    for (const { unidade, token } of tokensAsaas(Deno.env.get("ASAAS_TOKENS"))) {
      asaas.push({ unidade_id: unidade, cobrancas: await lerAsaas(token, String(j.pagos_desde)) });
    }
    lote = { parcelas, asaas };
  } catch (e) {
    const erro = String(e instanceof Error ? e.message : e).slice(0, 300);
    log("leitura_falhou", { tarefa, erro });
    await db()`select core.registrar_execucao(${tarefa}::uuid, ${EXECUTOR}, 'erro', null, null, ${"leitura: " + erro})`;
    return { tarefa, status: "erro_leitura" };
  }
  const [{ r }] = await db()`select cob.concluir_sincronizacao(${tarefa}::uuid, ${EXECUTOR}, ${db().json(lote as any)}) as r`;
  const [{ v }] = await db()`select cob.validar_sincronizacao(${tarefa}::uuid, ${VALIDADOR}) as v`;
  log("sincronizado", { tarefa, parcelas: r.parcelas, cobrancas_asaas: r.cobrancas_asaas, validacao: v });
  return { tarefa, resultado: r, validacao: v };
}

export async function fechar() { await sql?.end(); sql = null; }
