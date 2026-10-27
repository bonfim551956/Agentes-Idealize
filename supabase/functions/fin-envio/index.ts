// Ponto de entrada: só serve. A lógica (testada) está em recebimento.ts.
import postgres from "npm:postgres@3.4.5";
import { receber } from "./recebimento.ts";

let sql: ReturnType<typeof postgres> | null = null;
const db = () => (sql ??= postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 2, prepare: false, idle_timeout: 20 }));

Deno.serve(async (req) => {
  try {
    return await receber(req, (k) => Deno.env.get(k), {
      recebido: async (id, tamanho, sha) => (await db()`select fin.envio_arquivo_recebido(${id}::uuid, ${tamanho}, ${sha}) as s`)[0].s as string,
    });
  } catch (e) {
    console.error(JSON.stringify({ app: "fin-envio", erro: String(e).slice(0, 300) }));
    return Response.json({ erro: "falha interna" }, { status: 500 });
  }
});
