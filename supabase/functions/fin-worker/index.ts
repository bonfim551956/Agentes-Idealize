// Ponto de entrada: só serve. A lógica (testada) está em worker.ts.
import { executarLote, iguais } from "./worker.ts";

Deno.serve(async (req) => {
  const chave = Deno.env.get("FIN_WORKER_SECRET");
  if (!chave) return new Response("worker não configurado", { status: 503 });
  if (!iguais(req.headers.get("x-worker-key") ?? "", chave)) return new Response("não autorizado", { status: 401 });
  return Response.json(await executarLote());
});
