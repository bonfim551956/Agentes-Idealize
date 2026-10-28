// Ponto de entrada: só serve. A lógica está em sync.ts / normalizar.ts.
import { executar, iguais } from "./sync.ts";
import { semSegredo } from "./segredo.ts";

Deno.serve(async (req) => {
  const chave = Deno.env.get("LAB_WORKER_SECRET");
  if (!chave) return new Response("sincronização não configurada", { status: 503 });
  if (!iguais(req.headers.get("x-worker-key") ?? "", chave)) return new Response("não autorizado", { status: 401 });
  try {
    return Response.json(await executar());
  } catch (e) {
    console.error(JSON.stringify({ app: "lab-sync", erro: semSegredo(e) }));
    return Response.json({ erro: "falha interna" }, { status: 500 });
  }
});
