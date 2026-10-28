// Idealize AI — conferência única da chave da Anthropic. SÓ LEITURA (lista de modelos, sem custo). Nunca devolve a chave.
// Só responde enquanto core.config 'atr.teste_ate' estiver no futuro.
// (Esta função de conferência é reaproveitada a cada credencial nova: Asaas, ADM, RH 360, Anthropic.)
import postgres from "npm:postgres@3.4.5";

Deno.serve(async () => {
  const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 1, prepare: false, idle_timeout: 5 });
  try {
    const [{ liberado, modelo }] = await sql`select coalesce(core.cfg('atr.teste_ate', '') <> '' and core.cfg('atr.teste_ate', '')::timestamptz > now(), false) as liberado,
      core.cfg('fin.whatsapp.modelo', 'claude-sonnet-5-5') as modelo`;
    if (!liberado) return new Response("teste encerrado", { status: 403 });
    const bruto = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
    if (!bruto) return Response.json({ ANTHROPIC_API_KEY: "não existe" });
    const k = bruto.trim();
    const r: Record<string, unknown> = { espaco_nas_pontas: k !== bruto, formato_ok: /^sk-ant-[A-Za-z0-9_-]{20,}$/.test(k), tamanho: k.length, modelo_configurado: modelo };
    const resp = await fetch("https://api.anthropic.com/v1/models?limit=100", { headers: { "x-api-key": k, "anthropic-version": "2023-06-01" }, signal: AbortSignal.timeout(15000) });
    r.anthropic = resp.ok ? "ok (chave aceita)" : `recusou (HTTP ${resp.status})`;
    if (resp.ok) {
      const ids = (((await resp.json()) as { data?: { id: string }[] }).data ?? []).map((m) => m.id);
      r.modelo_disponivel = ids.includes(modelo);
      r.modelos = ids.filter((i) => /sonnet|opus|haiku/.test(i)).slice(0, 12);
    } else await resp.body?.cancel();
    return Response.json(r);
  } catch (e) {
    return Response.json({ erro: String(e instanceof Error ? e.message : e).replace(/sk-ant-\S+/g, "[oculto]").slice(0, 160) }, { status: 500 });
  } finally {
    await sql.end();
  }
});
