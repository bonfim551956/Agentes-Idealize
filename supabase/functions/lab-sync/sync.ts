// Idealize AI — sincronização do agente de Laboratório (só leitura do kanban no Sistema ADM).
// Só roda com: segredo do worker, chave lab.sync.ativo = true, agente ATIVO e credencial de leitura do ADM.
import postgres from "npm:postgres@3.4.5";
import { normalizar } from "./normalizar.ts";

const EXECUTOR = "lab-sync";
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

// Lê o ADM por uma conexão própria, só leitura, numa visão sem dados pessoais.
export async function lerAdm(url: string): Promise<Record<string, unknown>[]> {
  const adm = postgres(url, { max: 1, prepare: false, idle_timeout: 5, connect_timeout: 10 });
  try {
    return await adm.begin("read only", (t) => t`
      select id, unidade, os, ped, tipo, lab, col, dt_venda, prazo, urgente, refeito, cancelado, nao_retirado,
             saldo_aberto, ts, entrou_etapa_ms
      from idealize_ai.lab_os
      where col not in (5, 6, 7) or ts > (extract(epoch from now() - interval '3 days') * 1000)`) as unknown as Record<string, unknown>[];
  } finally {
    await adm.end();
  }
}

export async function executar(ler = lerAdm): Promise<Record<string, unknown>> {
  const [{ ativo }] = await db()`select core.cfg('lab.sync.ativo','false') = 'true' as ativo`;
  if (!ativo) return { status: "desligado" };
  const url = Deno.env.get("ADM_LEITURA_DB_URL");
  if (!url) return { status: "sem_credencial_do_adm" };
  await db()`select lab.agendar_sincronizacao()`;
  const rows = await db()`select id from core.reivindicar('laboratorio', ${EXECUTOR}, 300)`;
  if (!rows.length) return { tarefas: 0 }; // agente pausado, plataforma pausada ou nada na fila
  const tarefa = rows[0].id as string;
  let linhas: Record<string, unknown>[];
  try {
    linhas = (await ler(url)).map(normalizar);
  } catch (e) {
    const erro = String(e instanceof Error ? e.message : e).slice(0, 300);
    log("leitura_falhou", { tarefa, erro });
    // nada foi gravado: erro seguro, com nova tentativa e espera
    await db()`select core.registrar_execucao(${tarefa}::uuid, ${EXECUTOR}, 'erro', null, null, ${"leitura do ADM: " + erro})`;
    return { tarefa, status: "erro_leitura" };
  }
  const [{ r }] = await db()`select lab.concluir_sincronizacao(${tarefa}::uuid, ${EXECUTOR}, ${db().json(linhas as any)}) as r`;
  const [{ v }] = await db()`select lab.validar_sincronizacao(${tarefa}::uuid, ${VALIDADOR}) as v`;
  log("sincronizado", { tarefa, recebidas: r.recebidas, aplicadas: r.aplicadas, validacao: v });
  return { tarefa, resultado: r, validacao: v };
}

export async function fechar() { await sql?.end(); sql = null; }
