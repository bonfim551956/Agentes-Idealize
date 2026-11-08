import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { CheckCircle2, ChevronDown, ChevronRight } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc } from "../lib/api";
import { dataHora, rotuloUnidade, type Tom } from "../lib/format";
import { Carregando, ErroCaixa, Etiqueta, Painel } from "./base";
import { casaBusca, type Periodo } from "./Filtros";

// "Já resolvidos": o que o agente (ou alguém) já resolveu fica guardado aqui, fechado, para não misturar com o que falta.
export type ItemResolvido = {
  id: number; tipo: string; referencia: string | null; unidade_id: string | null; dia: string | null; titulo: string | null;
  detalhe: Record<string, unknown> | null; status: string; aberto_em: string; resolvido_em: string; responsavel: string | null;
  sozinho: boolean; por: string | null;
};
type Resp = { de: string; ate: string; total: number; itens: ItemResolvido[] };

export function Resolvidos({ area, unidade, periodo, busca = "", tipos = [], rotulos, descrever }: {
  area: string; unidade?: string | null; periodo: Periodo; busca?: string; tipos?: string[];
  rotulos: Record<string, { rotulo: string; tom?: Tom }>;
  descrever?: (a: ItemResolvido) => { titulo: string; detalhe: string };
}) {
  const { eu } = useSessao();
  const [aberto, setAberto] = useState(false);
  const q = useQuery({ queryKey: ["resolvidos", area, unidade ?? "", periodo.de, periodo.ate],
    queryFn: () => rpc<Resp>("painel_avisos_resolvidos", { p_area: area, p_unidade: unidade || null, p_de: periodo.de, p_ate: periodo.ate }),
    refetchInterval: 300_000 });
  const itens = (q.data?.itens ?? []).filter((a) => (!tipos.length || tipos.includes(a.tipo))
    && casaBusca(busca, a.referencia, a.titulo, a.detalhe, a.responsavel));
  const id = `resolvidos-${area}`;
  return (
    <section className="mb-10" aria-labelledby={id}>
      <button type="button" id={id} aria-expanded={aberto} aria-controls={id + "-lista"} onClick={() => setAberto(!aberto)}
        className="flex w-full items-center gap-2 rounded-grande border border-linha bg-superficie px-4 py-3 text-left hover:bg-elevada">
        {aberto ? <ChevronDown className="h-4 w-4 shrink-0" aria-hidden /> : <ChevronRight className="h-4 w-4 shrink-0" aria-hidden />}
        <CheckCircle2 className="h-4 w-4 shrink-0 text-ok" aria-hidden />
        <span className="font-bold">Já resolvidos no período{q.data ? ` (${itens.length}${q.data.total > itens.length && !busca && !tipos.length ? ` de ${q.data.total}` : ""})` : ""}</span>
        <span className="ml-auto hidden text-sm text-suave sm:inline">{aberto ? "esconder" : "ficam guardados aqui, fora da lista do que falta"}</span>
      </button>
      {aberto && (
        <div id={id + "-lista"} className="mt-3">
          {q.isLoading ? <Carregando linhas={3} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !itens.length ? (
            <p className="px-4 text-sm text-suave">Nada resolvido neste período{busca || tipos.length ? " com esses filtros" : ""}.</p>
          ) : (
            <ul className="flex flex-col gap-2">
              {itens.map((a) => {
                const t = descrever?.(a) ?? { titulo: a.titulo ?? a.referencia ?? "", detalhe: "" };
                return (
                  <li key={a.id}>
                    <Painel className="flex flex-col gap-1 px-4 py-3 opacity-90 sm:flex-row sm:items-start sm:justify-between">
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2">
                          <Etiqueta tom="ok">{a.status === "explicado" ? "Explicado" : "Resolvido"}</Etiqueta>
                          <span className="text-sm text-suave">{rotulos[a.tipo]?.rotulo ?? a.tipo.replace(/_/g, " ")}</span>
                        </div>
                        {t.titulo && <p className="mt-1 font-bold">{t.titulo}</p>}
                        {t.detalhe && <p className="text-sm text-suave">{t.detalhe}</p>}
                        <p className="mt-1 text-xs text-suave">
                          {dataHora(a.resolvido_em)} · {a.sozinho ? "o agente viu que a situação deixou de existir" : `resolvido por ${a.por ?? "alguém da equipe"}`}
                        </p>
                      </div>
                      <div className="shrink-0 text-sm text-suave sm:text-right">
                        {a.unidade_id && <p>{rotuloUnidade(a.unidade_id, eu.unidades)}</p>}
                        {a.responsavel && <p>{a.responsavel}</p>}
                        <p className="text-xs">aberto {dataHora(a.aberto_em)}</p>
                      </div>
                    </Painel>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      )}
    </section>
  );
}
