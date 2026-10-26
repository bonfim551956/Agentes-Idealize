// Ponto de entrada: só serve. A lógica (testada) está em handler.ts.
import { entregarNoBanco, tratar } from "./handler.ts";

Deno.serve((req) => tratar(req, entregarNoBanco, Deno.env.get("FIN_WEBHOOK_SECRET")));
