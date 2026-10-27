// Idealize AI — worker do agente financeiro: canal WhatsApp e arquivos enviados pelo painel (central de envio).
// Só roda se: segredo configurado, canal ligado (fin.whatsapp.ativo) ou leitura de envios ligada (fin.envios.ativo), e agente financeiro ATIVO.
// Ordem por tarefa: mídia → storage → IA → banco (execução + resultado na mesma transação) → validador independente.
// Falha antes de gravar = "erro" (nova tentativa com espera). Queda depois de gravar = lease vence → "incerta" → humano.
import postgres from "npm:postgres@3.4.5";
import { baixar, detectar, MidiaRecusada, sha256 } from "./midia.ts";
import { IaSemExtracao, lerResposta, montarRequisicao } from "./ia.ts";
import { detectarEnvio, LeituraInvalida, lerOfx, lerRespostaEnvio, planilhaParaTexto, requisicaoEnvio } from "./envios.ts";

const EXECUTOR = "fin-worker";
const VALIDADOR = "validador_sql";
const BUCKET = "fin-documentos";
let sql: ReturnType<typeof postgres> | null = null;
const db = () => (sql ??= postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 3, prepare: false, idle_timeout: 20 }));
const log = (evento: string, dados: Record<string, unknown>) =>
  console.log(JSON.stringify({ app: EXECUTOR, evento, ...dados }));

function iguais(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let d = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) d |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return d === 0;
}

async function guardar(path: string, mime: string, bytes: Uint8Array) {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth: Record<string, string> = key.startsWith("eyJ") ? { apikey: key, Authorization: `Bearer ${key}` } : { apikey: key };
  const r = await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/${BUCKET}/${path}`, {
    method: "POST", headers: { ...auth, "Content-Type": mime, "x-upsert": "true" }, body: bytes, signal: AbortSignal.timeout(30_000),
  });
  if (!r.ok) throw new Error(`storage ${r.status}`);
}

async function chamarIa(req: unknown) {
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) throw new Error("ANTHROPIC_API_KEY não configurada");
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify(req), signal: AbortSignal.timeout(120_000),
  });
  if (!r.ok) throw new Error(`Claude API ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return await r.json();
}

async function processar(t: { id: string; unidade_id: string }) {
  const [{ c: ctx }] = await db()`select fin.contexto_tarefa_whatsapp(${t.id}::uuid) as c`;
  const m = ctx.mensagem;
  try {
    let bytes: Uint8Array;
    try {
      bytes = await baixar(m.url, ctx.config.midia_hosts, Number(ctx.config.max_midia_mb) * 1024 * 1024);
    } catch (e) {
      if (e instanceof MidiaRecusada) return await semRegistro(t.id, e.message);
      throw e;
    }
    const tipo = detectar(bytes);
    if (!tipo) return await semRegistro(t.id, "formato não suportado (aceitos: JPG, PNG, WEBP, PDF)");
    const hash = await sha256(bytes);
    const [ano, mes] = String(ctx.hoje).split("-");
    const path = `${t.unidade_id}/${ano}/${mes}/${hash}.${tipo.ext}`;
    await guardar(path, tipo.mime, bytes);

    const resp = await chamarIa(montarRequisicao(ctx.config.modelo, tipo.mime, bytes, m.texto, ctx.hoje));
    const { extracao, uso } = lerResposta(resp);

    const doc = { sha256: hash, storage_path: path, mime: tipo.mime, tamanho: bytes.length };
    const [{ r }] = await db()`select fin.concluir_extracao(${t.id}::uuid, ${EXECUTOR}, ${db().json(doc)}, ${db().json(extracao)}) as r`;
    await db()`select core.registrar_custo('financeiro', 0, false, ${ctx.config.modelo}, ${t.id}::uuid, ${t.unidade_id},
               ${uso.entrada}, ${uso.saida}, 'whatsapp_comprovante')`;
    const [{ v }] = await db()`select fin.validar_registro_whatsapp(${t.id}::uuid, ${VALIDADOR}) as v`;
    log("tarefa_ok", { tarefa: t.id, validacao: v, lancamentos: r.lancamentos?.length ?? 0 });
  } catch (e) {
    const erro = e instanceof IaSemExtracao ? `IA: ${e.message}` : String(e instanceof Error ? e.message : e);
    log("tarefa_erro", { tarefa: t.id, erro });
    // nada foi gravado no banco nesta tentativa (concluir_extracao é atômica) → erro seguro, com nova tentativa
    await db()`select core.registrar_execucao(${t.id}::uuid, ${EXECUTOR}, 'erro', null, null, ${erro.slice(0, 500)})`
      .catch((x) => log("registrar_erro_falhou", { tarefa: t.id, erro: String(x) })); // lease vencerá → incerta
  }
}

async function baixarEnvio(caminho: string): Promise<Uint8Array> {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth: Record<string, string> = key.startsWith("eyJ") ? { apikey: key, Authorization: `Bearer ${key}` } : { apikey: key };
  const r = await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/fin-envios/${caminho}`, { headers: auth, signal: AbortSignal.timeout(60_000) });
  if (!r.ok) throw new Error(`storage ${r.status}`);
  return new Uint8Array(await r.arrayBuffer());
}

// Arquivo enviado pelo painel: lê (OFX sem IA; o resto pela IA) e entrega a leitura ao banco, que confere e decide
async function processarEnvio(t: { id: string; unidade_id: string }) {
  try {
    const [{ e }] = await db()`select to_jsonb(x) as e from fin.envios x where x.tarefa_id = ${t.id}::uuid`;
    const bytes = await baixarEnvio(e.caminho);
    const d = detectarEnvio(e.nome_arquivo, bytes);
    if (!d) throw new LeituraInvalida("formato do arquivo não reconhecido");
    let leitura: Record<string, unknown>;
    if (d.formato === "ofx") {
      leitura = lerOfx(bytes);
    } else {
      const [{ cfg }] = await db()`select jsonb_build_object('modelo', core.cfg('fin.whatsapp.modelo','claude-sonnet-5-5'),
        'hoje', (now() at time zone 'America/Sao_Paulo')::date,
        'categorias', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome)), '[]') from fin.categorias where ativo and natureza = 'despesa')) as cfg`;
      const conteudo = d.formato === "planilha" ? planilhaParaTexto(bytes) : d.formato === "texto" ? new TextDecoder().decode(bytes).slice(0, 300_000) : bytes;
      const resp = await chamarIa(requisicaoEnvio(cfg.modelo, d, conteudo, { tipo_declarado: e.tipo_declarado, nome: e.nome_arquivo,
        hoje: String(cfg.hoje), categorias: cfg.categorias }));
      const r = lerRespostaEnvio(resp, new Set((cfg.categorias as { id: string }[]).map((c) => c.id)));
      leitura = r.leitura;
      await db()`select core.registrar_custo('financeiro', 0, false, ${cfg.modelo}, ${t.id}::uuid, ${t.unidade_id},
                 ${r.uso.entrada}, ${r.uso.saida}, 'envio_documento')`;
    }
    const [{ r }] = await db()`select fin.envio_registrar_leitura(${t.id}::uuid, ${EXECUTOR}, ${db().json(leitura as any)}) as r`;
    const [{ v }] = await db()`select fin.validar_envio(${t.id}::uuid, ${VALIDADOR}) as v`;
    log("envio_ok", { tarefa: t.id, envio: e.id, tipo: r.tipo, status: r.status, validacao: v });
  } catch (x) {
    const erro = String(x instanceof Error ? x.message : x).slice(0, 300);
    log("envio_erro", { tarefa: t.id, erro });
    await db()`select fin.envio_erro_leitura(${t.id}::uuid, ${EXECUTOR}, ${erro})`
      .catch((y) => log("registrar_erro_falhou", { tarefa: t.id, erro: String(y) }));
  }
}

async function semRegistro(tarefa: string, motivo: string) {
  await db()`select fin.encerrar_sem_registro(${tarefa}::uuid, ${EXECUTOR}, ${motivo})`;
  await db()`select fin.validar_registro_whatsapp(${tarefa}::uuid, ${VALIDADOR})`;
  log("sem_registro", { tarefa, motivo });
}

export async function executarLote(prazoMs = 45_000): Promise<Record<string, unknown>> {
  const [{ ativo, envios }] = await db()`select core.cfg('fin.whatsapp.ativo','false') = 'true' as ativo,
    core.cfg('fin.envios.ativo','false') = 'true' as envios`;
  if (!ativo && !envios) return { status: "desligado" };
  if (envios) await db()`select fin.agendar_envios()`;
  const limite = Date.now() + prazoMs;
  let n = 0;
  while (Date.now() < limite) {
    const rows = await db()`select id, unidade_id, tipo from core.reivindicar('financeiro', ${EXECUTOR}, 300)`;
    if (!rows.length) break; // agente pausado ou fila vazia
    if (rows[0].tipo === "fin_envio") await processarEnvio(rows[0] as any);
    else await processar(rows[0] as any);
    n++;
  }
  return { tarefas: n };
}

export async function fechar() { await sql?.end(); sql = null; }

export { iguais };
