import { evento, funil, lead, usuario } from "./normalizar.ts";
import { clienteKommo, iguais, lerKommo } from "./sync.ts";

const igual = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`); };

Deno.test("lead: só campos da lista, sem nome, contato ou campos personalizados", () => {
  const o = lead({ id: 100, name: "Cliente Fulano", price: 500, responsible_user_id: 7, status_id: 142, pipeline_id: 10,
    created_at: 1792000000, updated_at: 1792100000, closed_at: 1792100000, custom_fields_values: [{ values: [{ value: "5519999990000" }] }],
    _embedded: { contacts: [{ id: 1 }] } })!;
  igual(Object.keys(o).sort(), ["atualizado_em", "criado_em", "etapa_id", "fechado_em", "funil_id", "id", "responsavel_id", "valor"]);
  igual(JSON.stringify(o).includes("Fulano") || JSON.stringify(o).includes("5519"), false);
});
Deno.test("lead sem funil/etapa é descartado; sem responsável vira 0", () => {
  igual(lead({ id: 1, status_id: 2 }), null);
  igual(lead({ id: 1, pipeline_id: 3, status_id: 2, responsible_user_id: null })!.responsavel_id, 0);
});
Deno.test("etapas: 142 ganha, 143 perdida, type 1 entrada, demais abertas", () => {
  const f = funil({ id: 10, name: "Funil", _embedded: { statuses: [
    { id: 1, name: "Entrada", type: 1, sort: 10 }, { id: 2, name: "Contato", type: 0, sort: 20 },
    { id: 142, name: "Ganha", type: 0, sort: 10000 }, { id: 143, name: "Perdida", type: 0, sort: 11000 }] } })!;
  igual((f.etapas as { tipo: string }[]).map((e) => e.tipo), ["entrada", "aberta", "ganha", "perdida"]);
});
Deno.test("evento: sem texto da mensagem; só chat de lead/contato; atendente só na resposta", () => {
  const e = evento({ id: "abc", type: "incoming_chat_message", entity_type: "lead", entity_id: 100, created_by: 0, created_at: 1792000000,
    value_after: [{ message: { talk_id: 1, text: "oi quero óculos" } }] })!;
  igual(Object.keys(e).sort(), ["em", "entidade_id", "entidade_tipo", "id", "tipo"]);
  igual(evento({ id: "x", type: "outgoing_chat_message", entity_type: "lead", entity_id: 1, created_by: 7, created_at: 1792000000 })!.usuario_id, 7);
  igual(evento({ id: "y", type: "lead_status_changed", entity_type: "lead", entity_id: 1, created_at: 1792000000 }), null);
  igual(evento({ id: "z", type: "incoming_chat_message", entity_type: "company", entity_id: 1, created_at: 1792000000 }), null);
});
Deno.test("usuário: sem e-mail, inativo respeitado", () => {
  igual(usuario({ id: 7, name: "Ana", email: "ana@x.com", rights: { is_active: false } }), { id: 7, nome: "Ana", ativo: false });
});
Deno.test("cliente só faz GET no subdomínio configurado e trata 204", async () => {
  const pedidos: { url: string; metodo: string }[] = [];
  const f = ((u: URL, i: RequestInit) => { pedidos.push({ url: String(u), metodo: String(i.method) });
    return Promise.resolve(new Response(null, { status: 204 })); }) as unknown as typeof fetch;
  const b = clienteKommo("prevendasidealize", "tok", f);
  igual(await b("leads", [["page", "1"]]), null);
  igual(pedidos, [{ url: "https://prevendasidealize.kommo.com/api/v4/leads?page=1", metodo: "GET" }]);
  let recusou = false;
  try { clienteKommo("evil.com/x", "tok", f); } catch { recusou = true; }
  igual(recusou, true);
});
Deno.test("leitura completa pagina e monta o lote", async () => {
  const resp: Record<string, unknown> = {
    users: { _embedded: { users: [{ id: 7, name: "Ana", rights: { is_active: true } }] } },
    "leads/pipelines": { _embedded: { pipelines: [{ id: 10, name: "F", _embedded: { statuses: [{ id: 2, type: 0, sort: 1 }] } }] } },
    leads: { _embedded: { leads: [{ id: 100, pipeline_id: 10, status_id: 2, responsible_user_id: 7 }] } },
    events: { _embedded: { events: [{ id: "e1", type: "incoming_chat_message", entity_type: "lead", entity_id: 100, created_at: 1792000000 }] } },
  };
  const vistos: string[] = [];
  const lote = await lerKommo(async (c, p) => { vistos.push(c + "?" + p.map((x) => x.join("=")).join("&")); return resp[c] as never; }, 1791900000, 1792100000);
  igual([(lote.usuarios as unknown[]).length, (lote.funis as unknown[]).length, (lote.leads as unknown[]).length, (lote.eventos as unknown[]).length], [1, 1, 1, 1]);
  igual(vistos.some((v) => v.startsWith("events?filter[type][]=incoming_chat_message&filter[type][]=outgoing_chat_message&filter[created_at][from]=1791900000")), true);
});
Deno.test("comparação de segredo", () => { igual(iguais("abc", "abc"), true); igual(iguais("abc", "abd"), false); });
