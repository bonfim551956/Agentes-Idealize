import { semSegredo } from "./segredo.ts";
const igual = (a: unknown, b: unknown) => { if (a !== b) throw new Error(`esperado ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`); };

Deno.test("endereço mal formado com senha não aparece (caso de 28/10)", () => {
  const m = semSegredo(new Error("Invalid URL: 'postgresql://leitor.ref:Abc123Senha@aws-1-sa-east-1.pooler.supabase.com: 5432/postgres'"));
  if (m.includes("Abc123Senha")) throw new Error(m);
  igual(m, "Invalid URL: '[endereço] 5432/postgres'");
});
Deno.test("senha com espaço, password=, token: e Bearer somem", () => {
  const m = semSegredo("a postgresql://u.r:abc def@h:5432/p b password=xyz123 token: tk999 Bearer eyJabc.def");
  for (const s of ["abc def", "xyz123", "tk999", "eyJabc"]) if (m.includes(s)) throw new Error(m);
});
Deno.test("erro comum continua igual", () => igual(semSegredo("HTTP 503"), "HTTP 503"));
