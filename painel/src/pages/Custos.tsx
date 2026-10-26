import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import * as Tabs from "@radix-ui/react-tabs";
import { rpc, type Custos as C } from "../lib/api";
import { dolar, numero } from "../lib/format";
import { Cabecalho, Campo, Carregando, ErroCaixa, Painel, Tabela, Vazio, cx, entradaCls, td, th } from "../ui/base";

const DIM: Record<string, string> = {
  agente: "Agente", departamento: "Departamento", unidade: "Unidade", modelo: "Modelo de IA",
  integracao: "Integração", tipo_tarefa: "Tipo de tarefa", dia: "Dia",
};
const hoje = () => new Date().toISOString().slice(0, 10);
const inicioMes = () => hoje().slice(0, 8) + "01";

export function Custos() {
  const [inicio, setInicio] = useState(inicioMes());
  const [fim, setFim] = useState(hoje());
  const q = useQuery({ queryKey: ["custos", inicio, fim], queryFn: () => rpc<C>("painel_custos", { p_inicio: inicio, p_fim: fim }) });

  return (
    <>
      <Cabecalho titulo="Custos de IA"
        descricao="Valores informados pelos agentes, na moeda da API (dólar). Confirmado vem da cobrança; estimado é o cálculo do próprio agente e nunca é somado como se fosse confirmado."
        acoes={<div className="flex gap-2">
          <Campo id="c-inicio" rotulo="De"><input id="c-inicio" type="date" className={entradaCls} value={inicio} max={fim} onChange={(e) => e.target.value && setInicio(e.target.value)} /></Campo>
          <Campo id="c-fim" rotulo="Até"><input id="c-fim" type="date" className={entradaCls} value={fim} min={inicio} max={hoje()} onChange={(e) => e.target.value && setFim(e.target.value)} /></Campo>
        </div>} />
      {q.isLoading ? <Carregando /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const c = q.data!;
        return (
          <>
            <dl className="mb-12 grid grid-cols-1 gap-4 sm:grid-cols-3">
              {[["Confirmado", dolar(c.total.confirmado)], ["Estimado (não confirmado)", dolar(c.total.estimado)], ["Registros de consumo", numero(c.total.registros)]].map(([r, v]) => (
                <Painel key={r} className="px-6 py-4"><dt className="text-sm text-suave">{r}</dt><dd className="mt-1 text-xl font-bold">{v}</dd></Painel>
              ))}
            </dl>
            {c.limites && (
              <section className="mb-12">
                <h2 className="mb-4 text-lg">Limites mensais por agente</h2>
                <ul className="flex flex-col gap-4">
                  {c.limites.map((l) => (
                    <li key={l.agente_id}>
                      <div className="mb-1 flex justify-between text-sm"><span className="font-bold">{l.nome}</span>
                        <span>{dolar(l.consumo_mes)} {l.limite != null ? `de ${dolar(l.limite)}` : "(sem limite definido)"}</span></div>
                      {l.limite != null && (
                        <div className="h-2 overflow-hidden rounded-full bg-elevada" role="meter" aria-valuemin={0} aria-valuemax={100} aria-valuenow={l.percentual ?? 0} aria-label={`Consumo do ${l.nome}`}>
                          <div className={cx("h-full", (l.percentual ?? 0) >= 100 ? "bg-critico" : (l.percentual ?? 0) >= 80 ? "bg-atencao" : "bg-lente")}
                            style={{ width: `${Math.min(100, l.percentual ?? 0)}%` }} />
                        </div>
                      )}
                    </li>
                  ))}
                </ul>
              </section>
            )}
            {!c.total.registros ? (
              <Vazio titulo="Nenhum consumo registrado no período">Os agentes registram cada chamada de IA com modelo, tokens e valor. Com o canal do WhatsApp desligado, é normal não haver consumo.</Vazio>
            ) : (
              <Tabs.Root defaultValue="agente">
                <Tabs.List aria-label="Agrupar por" className="mb-4 flex flex-wrap gap-2">
                  {Object.keys(DIM).filter((d) => c.por[d]).map((d) => (
                    <Tabs.Trigger key={d} value={d} className="rounded-medio border border-linha bg-superficie px-3 py-1 text-sm data-[state=active]:border-lente data-[state=active]:bg-lente-clara data-[state=active]:font-bold data-[state=active]:text-lente">
                      {DIM[d]}
                    </Tabs.Trigger>
                  ))}
                </Tabs.List>
                {Object.entries(c.por).map(([d, itens]) => (
                  <Tabs.Content key={d} value={d}>
                    <Tabela rotulo={`Custos por ${DIM[d]}`}>
                      <thead><tr><th className={th}>{DIM[d]}</th><th className={th}>Confirmado</th><th className={th}>Estimado</th><th className={th}>Tokens de entrada</th><th className={th}>Tokens de saída</th><th className={th}>Registros</th></tr></thead>
                      <tbody>{itens.map((i) => (
                        <tr key={i.chave}><td className={td}>{i.chave}</td><td className={td}>{dolar(i.confirmado)}</td><td className={td}>{dolar(i.estimado)}</td>
                          <td className={td}>{numero(i.tokens_entrada)}</td><td className={td}>{numero(i.tokens_saida)}</td><td className={td}>{numero(i.registros)}</td></tr>
                      ))}</tbody>
                    </Tabela>
                  </Tabs.Content>
                ))}
              </Tabs.Root>
            )}
          </>
        );
      })()}
    </>
  );
}
