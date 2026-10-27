import { chaveTelefone, codigoTelefone, contatoPrincipal, importarChave, origemLead, telefonesContato } from "./normalizar.ts";
import { iguais, lerLeads } from "./sync.ts";

const igual = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`); };

Deno.test("mesmo cliente com 55, parênteses, sem o nono dígito ou com 0 vira a mesma chave", () => {
  const k = chaveTelefone("(13) 99649-9669");
  igual([chaveTelefone("+55 13 99649-9669"), chaveTelefone("5513996499669"), chaveTelefone("013 9649-9669"), chaveTelefone("13 9649 9669")], [k, k, k, k]);
  igual([chaveTelefone("9649-9669"), chaveTelefone(""), chaveTelefone(null)], [null, null, null]);
});
Deno.test("código é HMAC de 64 hex, depende da chave e não contém o número", async () => {
  const a = await importarChave("a".repeat(40)), b = await importarChave("b".repeat(40));
  const ca = await codigoTelefone("(13) 99649-9669", a), cb = await codigoTelefone("(13) 99649-9669", b);
  igual(/^[0-9a-f]{64}$/.test(ca!), true);
  igual(ca === cb, false);
  igual(ca!.includes("96499669"), false);
  igual(await codigoTelefone("5513996499669", a), ca);
});
Deno.test("origem: etiquetas e UTM; número com cara de telefone é apagado, id de campanha fica", () => {
  const o = origemLead({ _embedded: { tags: [{ name: "Meta Ads" }] }, custom_fields_values: [
    { field_code: "UTM_CAMPAIGN", values: [{ value: "120224971222790644" }] },
    { field_name: "Origem", values: [{ value: "anúncio 13996499669" }] },
    { field_name: "Observação", values: [{ value: "cliente Fulano" }] }] })!;
  igual(o.includes("120224971222790644"), true);
  igual(o.includes("13996499669") || o.includes("Fulano"), false);
});
Deno.test("contato principal e telefone do contato", () => {
  igual(contatoPrincipal({ _embedded: { contacts: [{ id: 1 }, { id: 2, is_main: true }] } }), 2);
  igual(telefonesContato({ custom_fields_values: [{ field_code: "PHONE", values: [{ value: "+5513996499669" }] }, { field_code: "EMAIL", values: [{ value: "x@y" }] }] }),
    ["+5513996499669"]);
});
Deno.test("leitura dos leads: só GET, telefone sai como código, nada de telefone no resultado", async () => {
  const chave = await importarChave("c".repeat(40));
  const pedidos: string[] = [];
  const buscar = async (c: string, p: [string, string][]) => {
    pedidos.push(c);
    if (c === "leads") return { _embedded: { leads: [{ id: 10, pipeline_id: 7, responsible_user_id: 901, created_at: 1792000000, _embedded: { contacts: [{ id: 5, is_main: true }] } },
      { id: 11, pipeline_id: 7, created_at: 1792000001, _embedded: { contacts: [] } }] } };
    if (c === "contacts") { igual(p.some(([k, v]) => k === "filter[id][]" && v === "5"), true);
      return { _embedded: { contacts: [{ id: 5, name: "Fulano", custom_fields_values: [{ field_code: "PHONE", values: [{ value: "(13) 99649-9669" }] }] }] } }; }
    return null;
  };
  const r = await lerLeads(buscar as never, 1, 2, chave);
  igual(r.length, 2);
  igual(/^[0-9a-f]{64}$/.test(String(r[0].tel_hash)), true);
  igual(r[1].tel_hash, null);
  igual([r[0].responsavel_id, r[1].responsavel_id], [901, null]);
  igual(JSON.stringify(r).match(/Fulano|9649|99649/), null);
});
Deno.test("comparação de segredo", () => { igual(iguais("abc", "abc"), true); igual(iguais("abc", "abd"), false); });
