import { semSegredo } from "./segredo.ts";
Deno.test("Z-API: instância e chave do caminho somem", () => {
  const m = semSegredo(new Error("error sending request for url (https://api.z-api.io/instances/ABC123XYZ456/token/TOK987654321/send-text)"));
  if (m.includes("ABC123XYZ456") || m.includes("TOK987654321")) throw new Error(m);
});
Deno.test("endereço de banco some", () => {
  if (semSegredo("x postgresql://u.r:Senha123@h:5432/p").includes("Senha123")) throw new Error("vazou");
});
