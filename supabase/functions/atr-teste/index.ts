// Idealize AI — teste único dos segredos da Atribuição. SÓ LEITURA. Devolve só ok/não ok, nunca valores.
// Só responde enquanto core.config 'atr.teste_ate' estiver no futuro.
import postgres from "npm:postgres@3.4.5";

async function hash(s: string) {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, "0")).join("");
}
const curto = (e: unknown) => String(e instanceof Error ? e.message : e).replace(/postgres(ql)?:\/\/\S+/g, "[endereço]").slice(0, 160);

Deno.serve(async () => {
  const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 1, prepare: false, idle_timeout: 5 });
  try {
    const [{ liberado }] = await sql`select coalesce(core.cfg('atr.teste_ate', '') <> '' and core.cfg('atr.teste_ate', '')::timestamptz > now(), false) as liberado`;
    if (!liberado) return new Response("teste encerrado", { status: 403 });
    const env = (k: string) => Deno.env.get(k) ?? "";
    const r: Record<string, unknown> = {};
    const chave = env("ATR_CHAVE_TELEFONE"), worker = env("ATR_WORKER_SECRET"), tok = env("KOMMO_TOKEN"), sub = env("KOMMO_SUBDOMINIO").trim(), adm = env("ADM_LEITURA_DB_URL");
    r.ATR_CHAVE_TELEFONE = chave ? (chave.length >= 32 ? "ok" : `curta (${chave.length} caracteres; precisa de 32+)`) : "não existe";
    if (!worker) r.ATR_WORKER_SECRET = "não existe";
    else {
      const [{ igual }] = await sql`select coalesce((select encode(sha256(convert_to(decrypted_secret, 'UTF8')), 'hex') from vault.decrypted_secrets where name = 'atr_worker_secret') = ${await hash(worker)}, false) as igual`;
      r.ATR_WORKER_SECRET = igual ? "ok (igual à cópia do Vault)" : "existe, mas DIFERENTE da cópia no Vault";
    }
    r.KOMMO_SUBDOMINIO = !sub ? "não existe" : /^[a-z0-9-]{2,63}$/.test(sub) ? "ok" : "formato inválido (use só a parte antes de .kommo.com)";
    if (!tok) r.KOMMO_TOKEN = "não existe";
    else if (r.KOMMO_SUBDOMINIO !== "ok") r.KOMMO_TOKEN = "não testado (subdomínio inválido)";
    else {
      try {
        const k = await fetch(`https://${sub}.kommo.com/api/v4/account`, { method: "GET", headers: { authorization: `Bearer ${tok}`, accept: "application/json" }, signal: AbortSignal.timeout(15000) });
        await k.body?.cancel();
        r.KOMMO_TOKEN = k.ok ? "ok (Kommo aceitou)" : `Kommo recusou (HTTP ${k.status})`;
      } catch (e) { r.KOMMO_TOKEN = "falha ao chamar a Kommo: " + curto(e); }
    }
    const problemas = (u: string) => {
      const p: string[] = [];
      const t = u.trim();
      if (t !== u) p.push("tem espaço no começo ou no fim");
      if (/\s/.test(t)) p.push("tem espaço no meio");
      if (!/^postgres(ql)?:\/\//.test(t)) p.push("não começa com postgresql://");
      if (/\[|\]/.test(t)) p.push("ainda tem colchetes [ ] (troque [YOUR-PASSWORD] pela senha, sem os colchetes)");
      if ((t.match(/@/g) ?? []).length > 1) p.push("a senha tem @ (precisa virar %40) ou há @ a mais");
      if (/:\/\/[^:@/]+:[^@]*[#\/?][^@]*@/.test(t)) p.push("a senha tem # / ou ? (precisam virar %23 %2F %3F)");
      if (!/:\/\/idealize_ai_leitor[.:]/.test(t)) p.push("o usuário não é idealize_ai_leitor");
      if (!/(pooler\.supabase\.com|supabase\.co)(:\d+)?\//.test(t)) p.push("o servidor não parece ser do Supabase");
      return p;
    };
    if (!adm) {
      const parecidos = Object.keys(Deno.env.toObject()).filter((k) => /adm|leitura|db_url|url/i.test(k) && !/^SUPABASE_/.test(k));
      r.ADM_LEITURA_DB_URL = "não existe" + (parecidos.length ? ` (nomes parecidos encontrados: ${parecidos.map((k) => JSON.stringify(k)).join(", ")})` : " (nenhum nome parecido)");
    }
    else if (problemas(adm).length) r.ADM_LEITURA_DB_URL = "endereço com problema: " + problemas(adm).join("; ");
    else {
      let c: ReturnType<typeof postgres> | null = null;
      try {
        c = postgres(adm, { max: 1, prepare: false, idle_timeout: 2, connect_timeout: 10 });
        const [{ n, usuario }] = await c.begin("read only", (t) => t`select (select count(*) from (select 1 from idealize_ai.vendas_atribuicao limit 1) x)::int as n, current_user as usuario`) as any;
        r.ADM_LEITURA_DB_URL = usuario === "idealize_ai_leitor" ? (n === 1 ? "ok (lê a visão de vendas)" : "conectou, mas a visão veio vazia") : `conectou com o usuário errado (${usuario}); use idealize_ai_leitor`;
      } catch (e) { r.ADM_LEITURA_DB_URL = "não conectou: " + curto(e); }
      finally { await c?.end(); }
    }
    return Response.json(r);
  } catch (e) {
    return Response.json({ erro: curto(e) }, { status: 500 });
  } finally {
    await sql.end();
  }
});
