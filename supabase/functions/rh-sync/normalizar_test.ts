import { normalizar } from "./normalizar.ts";
import { iguais } from "./sync.ts";

const igual = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`); };

Deno.test("vínculo: só campos da lista; CPF, salário e endereço descartados", () => {
  const v = normalizar("vinculos", { vinculo_id: "abc", nome: "ANA", loja: "CAMPINAS", tipo: "clt_experiencia", status: "ativo",
    data_admissao: new Date("2026-09-17T00:00:00Z"), jornada_semanal_horas: "44", cpf: "12345678900", salario_base: 3000, logradouro: "RUA X" });
  igual(Object.keys(v).sort(), ["cargo","data_admissao","data_desligamento","escala","jornada_semanal_horas","loja","nome","status","tipo","vinculo_id"]);
  igual([v.data_admissao, v.jornada_semanal_horas], ["2026-09-17", 44]);
  igual(JSON.stringify(v).match(/12345678900|3000|RUA X/), null);
});
Deno.test("documento: só categoria, vencimento e situação (nenhum conteúdo)", () => {
  igual(Object.keys(normalizar("documentos", { id: "d1", vinculo_id: "v", categoria: "exames_ocupacionais", vencimento: "2026-12-01",
    status: "aprovado", storage_path: "x/aso.pdf", observacoes: "APTO" })).sort(), ["categoria","id","status","vencimento","vinculo_id"]);
});
Deno.test("férias: datas e marcação de programada", () => {
  const f = normalizar("ferias", { id: "f", vinculo_id: "v", inicio: "2026-11-02", fim: "2026-11-11", programada: true });
  igual([f.inicio, f.fim, f.programada], ["2026-11-02", "2026-11-11", true]);
});
Deno.test("comparação de segredo", () => { igual(iguais("abc", "abc"), true); igual(iguais("abc", "abd"), false); });
