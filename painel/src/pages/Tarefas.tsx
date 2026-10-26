import { useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { ListChecks, Search } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type Agente, type TarefaResumo } from "../lib/api";
import { dataHora, dinheiro, nomeOperacao, relativo, rotuloUnidade, STATUS_TAREFA } from "../lib/format";
import { Botao, Cabecalho, Carregando, ErroCaixa, Etiqueta, Tabela, Vazio, cx, entradaCls, td, tdn, th } from "../ui/base";

const FILTROS: { id: string; rotulo: string; status: string[] | null }[] = [
  { id: "todas", rotulo: "Todas", status: null },
  { id: "andamento", rotulo: "Em andamento", status: ["pendente", "pronta", "executando", "validando"] },
  { id: "aguardando_aprovacao", rotulo: "Aguardando aprovação", status: ["aguardando_aprovacao"] },
  { id: "incerta", rotulo: "Incertas", status: ["incerta"] },
  { id: "bloqueada", rotulo: "Bloqueadas", status: ["bloqueada"] },
  { id: "falhou", rotulo: "Falharam", status: ["falhou"] },
  { id: "concluida", rotulo: "Concluídas", status: ["concluida"] },
  { id: "encerradas", rotulo: "Canceladas ou rejeitadas", status: ["cancelada", "rejeitada"] },
];
const PAGINA = 50;

export function Tarefas() {
  const { eu } = useSessao();
  const [sp, setSp] = useSearchParams();
  const filtro = FILTROS.find((f) => f.id === (sp.get("status") ?? "todas")) ?? FILTROS[0];
  const agente = sp.get("agente") || null;
  const unidade = sp.get("unidade") || null;
  const busca = sp.get("q") || null;
  const soAtrasadas = sp.get("atrasadas") === "1";
  const [texto, setTexto] = useState(busca ?? "");
  const agentes = useQuery({ queryKey: ["agentes", 30], queryFn: () => rpc<Agente[]>("painel_agentes", { p_dias: 30 }) });

  const q = useInfiniteQuery({
    queryKey: ["tarefas", filtro.id, agente, unidade, busca],
    queryFn: ({ pageParam }) => rpc<TarefaResumo[]>("painel_tarefas", {
      p_status: filtro.status, p_agente: agente, p_unidade: unidade, p_busca: busca, p_limite: PAGINA, p_antes: pageParam,
    }),
    initialPageParam: null as string | null,
    getNextPageParam: (ult) => (ult.length === PAGINA ? ult[ult.length - 1].atualizado_em : undefined),
  });
  const linhas = (q.data?.pages.flat() ?? []).filter((t) => !soAtrasadas || t.atrasada);

  const mudar = (k: string, v: string | null) => {
    const n = new URLSearchParams(sp);
    if (v) n.set(k, v); else n.delete(k);
    setSp(n, { replace: true });
  };

  return (
    <>
      <Cabecalho titulo="Tarefas" descricao="Tudo o que os agentes receberam, com o estado atual e o histórico de cada uma." />
      <div className="mb-6 flex flex-col gap-4">
        <div role="group" aria-label="Filtrar por estado" className="flex flex-wrap gap-2">
          {FILTROS.map((f) => (
            <button key={f.id} onClick={() => mudar("status", f.id === "todas" ? null : f.id)} aria-pressed={f.id === filtro.id}
              className={cx("rounded-medio border px-3 py-1 text-sm",
                f.id === filtro.id ? "border-lente bg-lente-clara font-bold text-lente" : "border-linha bg-superficie hover:bg-elevada")}>
              {f.rotulo}
            </button>
          ))}
          {soAtrasadas && <button onClick={() => mudar("atrasadas", null)} aria-pressed
            className="rounded-medio border border-atencao bg-atencao-fundo px-3 py-1 text-sm font-bold text-atencao">Só atrasadas (remover)</button>}
        </div>
        <div className="grid grid-cols-1 gap-2 sm:grid-cols-[1fr_200px_200px]">
          <form role="search" onSubmit={(e) => { e.preventDefault(); mudar("q", texto.trim() || null); }} className="relative">
            <label htmlFor="busca-tarefa" className="sr-only">Buscar tarefa</label>
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-suave" aria-hidden />
            <input id="busca-tarefa" className={entradaCls + " pl-10"} placeholder="Buscar por código, tipo ou motivo"
              value={texto} onChange={(e) => setTexto(e.target.value)} />
          </form>
          <label className="sr-only" htmlFor="f-agente">Agente</label>
          <select id="f-agente" className={entradaCls} value={agente ?? ""} onChange={(e) => mudar("agente", e.target.value || null)}>
            <option value="">Todos os agentes</option>
            {agentes.data?.map((a) => <option key={a.id} value={a.id}>{a.nome}</option>)}
          </select>
          <label className="sr-only" htmlFor="f-unidade">Unidade</label>
          <select id="f-unidade" className={entradaCls} value={unidade ?? ""} onChange={(e) => mudar("unidade", e.target.value || null)}>
            <option value="">Todas as unidades</option>
            {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
          </select>
        </div>
      </div>

      {q.isLoading ? <Carregando /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !linhas.length ? (
        <Vazio titulo="Nenhuma tarefa com esses filtros" icone={<ListChecks className="h-6 w-6" />}>
          Mude o estado, o agente ou a unidade para ampliar a busca.
        </Vazio>
      ) : (
        <>
          <Tabela rotulo="Tarefas">
            <thead><tr>
              <th className={th}>Tarefa</th><th className={th}>Estado</th><th className={th}>Unidade</th>
              <th className={th}>Valor</th><th className={th}>Tentativas</th><th className={th}>Atualizada</th>
            </tr></thead>
            <tbody>
              {linhas.map((t) => (
                <tr key={t.id} className="hover:bg-elevada/60">
                  <td className={td}>
                    <Link to={`/tarefas/${t.id}`} className="font-bold text-lente hover:underline">{nomeOperacao(t.recurso, t.operacao)}</Link>
                    <span className="block text-xs text-suave">{t.recurso}.{t.operacao}, agente {t.agente_id}</span>
                    {t.motivo && <span className="mt-1 block max-w-md text-xs text-suave">{t.motivo}</span>}
                  </td>
                  <td className={td}>
                    <div className="flex flex-col items-start gap-1">
                      <Etiqueta tom={STATUS_TAREFA[t.status]?.tom}>{STATUS_TAREFA[t.status]?.rotulo ?? t.status}</Etiqueta>
                      {t.atrasada && <Etiqueta tom="atencao">Atrasada</Etiqueta>}
                    </div>
                  </td>
                  <td className={td}>{rotuloUnidade(t.unidade_id, eu.unidades)}</td>
                  <td className={tdn}>{t.valor != null ? dinheiro(t.valor) : "—"}</td>
                  <td className={td}>{t.tentativas}</td>
                  <td className={td} title={dataHora(t.atualizado_em)}>{relativo(t.atualizado_em)}</td>
                </tr>
              ))}
            </tbody>
          </Tabela>
          {q.hasNextPage && (
            <div className="mt-4"><Botao onClick={() => q.fetchNextPage()} carregando={q.isFetchingNextPage}>Carregar mais tarefas</Botao></div>
          )}
        </>
      )}
    </>
  );
}
