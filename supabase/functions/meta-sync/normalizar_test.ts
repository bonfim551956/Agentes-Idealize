import { anuncio, campanha, conta, metrica } from "./normalizar.ts";
import { clienteMeta, iguais, lerMeta, tokens } from "./sync.ts";

const igual = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`); };

Deno.test("métrica: conversas, leads e visitas sem contar duas vezes; só campos da lista", () => {
  const m = metrica({ campaign_id: "52568233317239", campaign_name: "[MENSAGEM] Campinas", date_start: "2026-10-25", date_stop: "2026-10-25",
    spend: "766.84", impressions: "51234", reach: "30111", clicks: "812", cpm: "14.9",
    actions: [{ action_type: "onsite_conversion.messaging_conversation_started_7d", value: "52" },
      { action_type: "lead", value: "3" }, { action_type: "onsite_conversion.lead_grouped", value: "3" },
      { action_type: "omni_landing_page_view", value: "9" }] }, "961713916565369")!;
  igual(m, { campanha_id: "52568233317239", conta_id: "961713916565369", dia: "2026-10-25", gasto: 766.84, impressoes: 51234,
    alcance: 30111, cliques: 812, conversas: 52, leads: 3, visitas: 9 });
});
Deno.test("conta: tira o act_, guarda status e motivo; campanha: orçamento de centavos para reais", () => {
  igual(conta({ id: "act_1441410073197795", account_id: "1441410073197795", name: "CA IDEALIZE SOROCABA", account_status: 3, disable_reason: 0, currency: "BRL" }),
    { id: "1441410073197795", nome: "CA IDEALIZE SOROCABA", status_meta: 3, motivo_bloqueio: 0, moeda: "BRL" });
  igual(campanha({ id: "120224971222790644", name: "ESCALA", objective: "OUTCOME_ENGAGEMENT", effective_status: "ACTIVE", daily_budget: "15000" }, "1")!.orcamento_diario, 150);
});
Deno.test("anúncio: só reprovado ou com problema", () => {
  igual(anuncio({ id: "120200000000001", name: "Video", campaign_id: "120200000000002", effective_status: "DISAPPROVED" }, "1")!.status, "DISAPPROVED");
  igual(anuncio({ id: "120200000000001", name: "Video", effective_status: "ACTIVE" }, "1"), null);
});
Deno.test("tokens separados por vírgula ou linha; curtos descartados", () => {
  igual(tokens(`${"a".repeat(30)}, ${"b".repeat(30)}\n x`).length, 2);
  igual(tokens(undefined), []);
});
Deno.test("cliente só faz GET na Meta, sem token na URL, e não segue paginação para fora", async () => {
  const pedidos: { url: string; metodo: string; auth: string }[] = [];
  let n = 0;
  const f = ((u: URL, i: RequestInit) => {
    pedidos.push({ url: String(u), metodo: String(i.method), auth: String((i.headers as Record<string, string>).authorization) });
    n++;
    const corpo = n === 1 ? { data: [{ id: 1 }], paging: { next: "https://graph.facebook.com/v23.0/me/adaccounts?after=X&access_token=VAZOU" } }
      : n === 2 ? { data: [{ id: 2 }], paging: { next: "https://evil.example/roubar" } } : { data: [] };
    return Promise.resolve(new Response(JSON.stringify(corpo), { status: 200 }));
  }) as unknown as typeof fetch;
  const b = clienteMeta("t".repeat(40), "v23.0", f);
  let recusou = false;
  try { await b("me/adaccounts", [["limit", "100"]]); } catch (e) { recusou = /fora da Meta/.test(String(e)); }
  igual(recusou, true);
  igual(pedidos.every((p) => p.metodo === "GET" && p.auth.startsWith("Bearer ") && !p.url.includes("access_token")), true);
});
Deno.test("erro de limite da Meta tenta de novo; token inválido falha", async () => {
  let n = 0;
  const f = (() => { n++; return Promise.resolve(new Response(JSON.stringify(n === 1 ? { error: { code: 190 } } : { data: [] }), { status: 400 })); }) as unknown as typeof fetch;
  let falhou = false;
  try { await clienteMeta("t".repeat(40), "v23.0", f)("me/adaccounts", []); } catch (e) { falhou = /código 190/.test(String(e)); }
  igual([falhou, n], [true, 1]);
});
Deno.test("leitura completa: contas sem repetir entre tokens, campanha arquivada vinda das métricas", async () => {
  const resp = (c: string): Record<string, unknown>[] => c === "me/adaccounts"
    ? [{ account_id: "961713916565369", name: "CA Campinas Idealize", account_status: 1 }]
    : c.endsWith("/campaigns") ? [{ id: "52568233317239", name: "[MENSAGEM]", effective_status: "ACTIVE" }]
    : c.endsWith("/insights") ? [{ campaign_id: "52568233317239", date_start: "2026-10-25", spend: "10" },
                                 { campaign_id: "52500000000001", campaign_name: "Antiga", date_start: "2026-10-25", spend: "5" }]
    : [{ id: "120200000000001", name: "V", effective_status: "WITH_ISSUES" }];
  const vistos: string[] = [];
  const b = async (c: string, p: [string, string][]) => { vistos.push(c + "?" + p.map((x) => x.join("=")).join("&")); return resp(c) as never; };
  const lote = await lerMeta([b, b], "2026-10-24", "2026-10-26");
  igual([(lote.contas as unknown[]).length, (lote.campanhas as unknown[]).length, (lote.metricas as unknown[]).length, (lote.anuncios_problema as unknown[]).length], [1, 2, 2, 1]);
  igual(vistos.some((v) => v.includes('time_range={"since":"2026-10-24","until":"2026-10-26"}')), true);
});
Deno.test("comparação de segredo", () => { igual(iguais("abc", "abc"), true); igual(iguais("abc", "abd"), false); });
