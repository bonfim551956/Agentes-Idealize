// Idealize AI — teste único da chave do Asaas. SÓ LEITURA (GET /v3/payments com limit=1, lê só o totalCount).
// Devolve apenas contagens: nenhum nome, CPF, valor ou id. Só responde enquanto core.config 'asaas.teste_ate' estiver no futuro.
import postgres from "npm:postgres@3.4.5";

const STATUS = ["PENDING", "OVERDUE", "RECEIVED", "CONFIRMED"] as const;

function lojas(s: string | undefined) {
  return (s ?? "").split(/[\n,]+/).map((l) => l.trim()).filter(Boolean).map((l) => {
    const i = l.indexOf("=");
    const unidade = i > 0 ? l.slice(0, i).trim() : "";
    const token = i > 0 ? l.slice(i + 1).trim() : "";
    return { unidade, token, valida: /^[a-z_]{2,40}$/.test(unidade) && token.length >= 20, so_chave: l.startsWith("$aact") };
  });
}

Deno.serve(async () => {
  const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 1, prepare: false, idle_timeout: 5 });
  try {
    const [{ liberado }] = await sql`select coalesce(core.cfg('asaas.teste_ate', '') <> '' and core.cfg('asaas.teste_ate', '')::timestamptz > now(), false) as liberado`;
    if (!liberado) return new Response("teste encerrado", { status: 403 });
    const bruto = Deno.env.get("ASAAS_TOKENS");
    const itens = lojas(bruto);
    const saida: Record<string, unknown>[] = [];
    for (const l of itens) {
      if (!l.valida) { saida.push({ linha_invalida: true, parece_so_a_chave: l.so_chave, unidade: l.unidade || null }); continue; }
      const r: Record<string, unknown> = { unidade: l.unidade, ambiente: l.token.includes("_prod_") ? "producao" : (l.token.includes("_hmlg_") ? "sandbox" : "desconhecido") };
      for (const st of STATUS) {
        const u = new URL("https://api.asaas.com/v3/payments");
        u.searchParams.set("status", st); u.searchParams.set("limit", "1");
        const resp = await fetch(u, { method: "GET", headers: { access_token: l.token, accept: "application/json", "user-agent": "idealize-ai" } });
        r.http = resp.status;
        if (!resp.ok) { await resp.body?.cancel(); r.aceita = false; break; }
        const j = await resp.json() as { totalCount?: number };
        r.aceita = true; r[st.toLowerCase()] = j.totalCount ?? null;
      }
      saida.push(r);
    }
    return Response.json({ segredo_existe: Boolean(bruto), linhas: itens.length, lojas: saida });
  } catch (e) {
    console.error(JSON.stringify({ app: "asaas-teste", erro: String(e).slice(0, 200) }));
    return Response.json({ erro: "falha interna" }, { status: 500 });
  } finally {
    await sql.end();
  }
});
