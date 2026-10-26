import { normalizar } from "./normalizar.ts";
import { iguais } from "./sync.ts";

const igual = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`); };

Deno.test("descarta campos fora da lista (dados pessoais)", () => {
  const o = normalizar({ id: "os_1", unidade: "campinas", col: 1, cliente: "Fulano", telefone: "5513999990001", receita: "x", valor_venda: 500 });
  igual(Object.keys(o).sort(), ["cancelado", "col", "id", "nao_retirado", "refeito", "saldo_aberto", "unidade", "urgente"]);
});
Deno.test("datas viram AAAA-MM-DD e bigint vira texto", () => {
  const o = normalizar({ id: "a", col: "4", dt_venda: new Date("2026-10-20T03:00:00Z"), prazo: "2026-10-30", ts: 1793000000000n, entrou_etapa_ms: 1792000000000 });
  igual([o.col, o.dt_venda, o.prazo, o.ts, o.entrou_etapa_ms], [4, "2026-10-20", "2026-10-30", "1793000000000", "1792000000000"]);
});
Deno.test("coluna inválida não entra (o banco ignora a linha)", () => {
  igual("col" in normalizar({ id: "a", col: "x" }), false);
});
Deno.test("lógicos só são verdadeiros se forem true", () => {
  igual(normalizar({ id: "a", col: 1, urgente: "sim", refeito: true }).urgente, false);
  igual(normalizar({ id: "a", col: 1, refeito: true }).refeito, true);
});
Deno.test("comparação de segredo", () => { igual(iguais("abc", "abc"), true); igual(iguais("abc", "abd"), false); igual(iguais("", "a"), false); });
