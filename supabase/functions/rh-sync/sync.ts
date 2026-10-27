// Idealize AI — sincronização do agente de RH. SÓ LEITURA no RH 360, por usuário próprio, em visões sem dados sensíveis.
// Só roda com: segredo do worker, rh.sync.ativo = true, agente ATIVO e credencial de leitura do RH 360.
import postgres from "npm:postgres@3.4.5";
import { normalizar, type Obj } from "./normalizar.ts";

const EXECUTOR = "rh-sync";
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

export async function lerRh(url: string): Promise<Obj> {
  const rh = postgres(url, { max: 1, prepare: false, idle_timeout: 5, connect_timeout: 10 });
  try {
    return await rh.begin("read only", async (t) => ({
      vinculos: (await t`select vinculo_id, nome, loja, cargo, tipo, status, data_admissao, data_desligamento, jornada_semanal_horas, escala, aniversario
                         from idealize_ai.rh_vinculos`).map((x) => normalizar("vinculos", x as Obj)),
      ferias: (await t`select id, vinculo_id, inicio, fim, aquisitivo_inicio, aquisitivo_fim, programada from idealize_ai.rh_ferias`)
        .map((x) => normalizar("ferias", x as Obj)),
      desligamentos: (await t`select id, vinculo_id, modalidade, data_comunicacao, data_desligamento, status, concluido_em from idealize_ai.rh_desligamentos`)
        .map((x) => normalizar("desligamentos", x as Obj)),
      tarefas: (await t`select id, titulo, categoria, loja, prazo, prioridade, status from idealize_ai.rh_tarefas`).map((x) => normalizar("tarefas", x as Obj)),
      documentos: (await t`select id, vinculo_id, categoria, vencimento, status from idealize_ai.rh_documentos_vencimento`)
        .map((x) => normalizar("documentos", x as Obj)),
      mudancas: (await t`select id, vinculo_id, tipo, data from idealize_ai.rh_mudancas`).map((x) => normalizar("mudancas", x as Obj)),
      uniformes: (await t`select id, peca, tamanho, estoque_minimo, saldo from idealize_ai.rh_uniformes`).map((x) => normalizar("uniformes", x as Obj)),
    }));
  } finally {
    await rh.end();
  }
}

export async function executar(): Promise<Record<string, unknown>> {
  const [{ ativo }] = await db()`select core.cfg('rh.sync.ativo','false') = 'true' as ativo`;
  if (!ativo) return { status: "desligado" };
  const url = Deno.env.get("RH_LEITURA_DB_URL");
  if (!url) return { status: "sem_credencial_do_rh360" };
  await db()`select rh.agendar_sincronizacao()`;
  const rows = await db()`select id from core.reivindicar('rh', ${EXECUTOR}, 600)`;
  if (!rows.length) return { tarefas: 0 };
  const tarefa = rows[0].id as string;
  let lote: Obj;
  try {
    lote = await lerRh(url);
  } catch (e) {
    const erro = String(e instanceof Error ? e.message : e).slice(0, 300);
    log("leitura_falhou", { tarefa, erro });
    await db()`select core.registrar_execucao(${tarefa}::uuid, ${EXECUTOR}, 'erro', null, null, ${"leitura do RH 360: " + erro})`;
    return { tarefa, status: "erro_leitura" };
  }
  const [{ r }] = await db()`select rh.concluir_sincronizacao(${tarefa}::uuid, ${EXECUTOR}, ${db().json(lote as any)}) as r`;
  const [{ v }] = await db()`select rh.validar_sincronizacao(${tarefa}::uuid, ${VALIDADOR}) as v`;
  log("sincronizado", { tarefa, vinculos: r.vinculos, validacao: v });
  return { tarefa, resultado: r, validacao: v };
}

export async function fechar() { await sql?.end(); sql = null; }
