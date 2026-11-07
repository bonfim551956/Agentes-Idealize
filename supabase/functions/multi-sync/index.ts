// Idealize AI — conferência do Multicrediário (pedido do Diego, 07/11/2026). SÓ LEITURA no ADM: usuário só leitura numa
// visão sem nome nem CPF (o CPF vem só como código). Copia os carnês Multicrédito dos últimos ~15 meses (parcela recebida hoje pode ser de venda antiga) e as parcelas das unidades conferidas
// e chama multi.receber_adm(), que confere com o que o robô leu no Multicrediário. Chamada às 7h40 pelo agendador.
import postgres from "npm:postgres@3.4.5";
import { semSegredo } from "./segredo.ts";

const iguais = (a: string, b: string) => {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let d = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) d |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return d === 0;
};

Deno.serve(async (req) => {
  const chave = Deno.env.get("COB_WORKER_SECRET");
  if (!chave) return new Response("não configurado", { status: 503 });
  if (!iguais(req.headers.get("x-worker-key") ?? "", chave)) return new Response("não autorizado", { status: 401 });
  const url = Deno.env.get("ADM_LEITURA_DB_URL");
  if (!url) return Response.json({ status: "sem_credencial_do_adm" });
  const db = postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 1, prepare: false, idle_timeout: 5 });
  const adm = postgres(url, { max: 1, prepare: false, idle_timeout: 5, connect_timeout: 10 });
  try {
    const [{ u }] = await db`select string_to_array(regexp_replace(core.cfg('multi.unidades_adm','saovicente'),'\\s','','g'),',') as u`;
    const { vendas, parcelas } = await adm.begin("read only", async (t) => {
      const vendas = await t`
        select crediario_id, unidade, os, os_fake, dt_compra::text, valor_compra, valor_crediario, valor_entrada, num_parcelas, status, cpf_hash
          from idealize_ai.crediario_vendas where unidade = any(${u}) and dt_compra >= current_date - 450`;
      const ids = vendas.map((v) => v.crediario_id as string);
      const parcelas = ids.length ? await t`
        select id, crediario_id, numero, valor, dt_vencimento::text, dt_pagamento::text, status
          from idealize_ai.crediario_parcelas where crediario_id = any(${ids})` : [];
      return { vendas, parcelas };
    });
    const [{ r }] = await db`select multi.receber_adm(${db.json(vendas as any)}, ${db.json(parcelas as any)}) as r`;
    console.log(JSON.stringify({ app: "multi-sync", evento: "conferido", vendas: vendas.length, parcelas: parcelas.length, resultado: r }));
    return Response.json(r);
  } catch (e) {
    console.error(JSON.stringify({ app: "multi-sync", erro: semSegredo(e) }));
    return Response.json({ erro: "falha interna" }, { status: 500 });
  } finally {
    await adm.end(); await db.end();
  }
});
