import { useState } from "react";
import { useInfiniteQuery, useMutation } from "@tanstack/react-query";
import { FileSearch, ShieldCheck, ShieldX } from "lucide-react";
import { rpc, type EventoAuditoria } from "../lib/api";
import { dataHora, numero } from "../lib/format";
import { traduzir } from "../lib/erros";
import { Botao, Cabecalho, Carregando, Dados, ErroCaixa, Painel, Vazio, entradaCls } from "../ui/base";

const ENTIDADES: Record<string, string> = {
  tarefa: "Tarefas", agente: "Agentes", agentes: "Agentes (cadastro)", config: "Configurações", principal: "Pessoas",
  principal_papeis: "Papéis", politicas: "Políticas", politica: "Políticas (painel)", incidente: "Incidentes",
  "fin.lancamento": "Lançamentos", "fin.pendencia": "Pendências", "fin.fechamento": "Fechamentos", integracoes: "Integrações",
};
const PAGINA = 100;

export function Auditoria() {
  const [entidade, setEntidade] = useState("");
  const [busca, setBusca] = useState("");
  const [buscaAtiva, setBuscaAtiva] = useState<string | null>(null);
  const verificar = useMutation({ mutationFn: () => rpc<{ integra: boolean; primeiro_adulterado: number | null; eventos: number; verificado_em: string }>("painel_auditoria_verificar") });
  const q = useInfiniteQuery({
    queryKey: ["auditoria", entidade, buscaAtiva],
    queryFn: ({ pageParam }) => rpc<EventoAuditoria[]>("painel_auditoria", { p_entidade: entidade || null, p_busca: buscaAtiva, p_limite: PAGINA, p_antes: pageParam }),
    initialPageParam: null as number | null,
    getNextPageParam: (u) => (u.length === PAGINA ? u[u.length - 1].id : undefined),
  });
  const linhas = q.data?.pages.flat() ?? [];

  return (
    <>
      <Cabecalho titulo="Histórico auditado"
        descricao="Cada evento é encadeado ao anterior por um código (hash). Se alguém alterar ou apagar um registro direto no banco, a verificação acusa onde."
        acoes={<Botao variante="primario" carregando={verificar.isPending} onClick={() => verificar.mutate()}>Verificar integridade agora</Botao>} />
      {verificar.data && (
        <div role="status" className={"mb-8 flex items-center gap-3 rounded-grande px-6 py-4 " + (verificar.data.integra ? "bg-ok-fundo text-ok" : "bg-critico-fundo text-critico")}>
          {verificar.data.integra ? <ShieldCheck className="h-6 w-6" aria-hidden /> : <ShieldX className="h-6 w-6" aria-hidden />}
          <p className="font-bold">{verificar.data.integra
            ? `Íntegro: ${numero(verificar.data.eventos)} eventos conferidos em ${dataHora(verificar.data.verificado_em)}.`
            : `Adulteração detectada a partir do evento nº ${verificar.data.primeiro_adulterado}. Pause a plataforma e acione o responsável técnico.`}</p>
        </div>
      )}
      {verificar.error && <div className="mb-8"><ErroCaixa erro={traduzir(verificar.error)} /></div>}
      <div className="mb-6 grid grid-cols-1 gap-2 sm:grid-cols-[240px_1fr]">
        <label className="sr-only" htmlFor="a-ent">Assunto</label>
        <select id="a-ent" className={entradaCls} value={entidade} onChange={(e) => setEntidade(e.target.value)}>
          <option value="">Todos os assuntos</option>
          {Object.entries(ENTIDADES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
        <form role="search" onSubmit={(e) => { e.preventDefault(); setBuscaAtiva(busca.trim() || null); }}>
          <label className="sr-only" htmlFor="a-busca">Buscar</label>
          <input id="a-busca" className={entradaCls} placeholder="Buscar por ação, código do registro ou motivo e tecle Enter" value={busca} onChange={(e) => setBusca(e.target.value)} />
        </form>
      </div>
      {q.isLoading ? <Carregando /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !linhas.length ? (
        <Vazio titulo="Nenhum evento com esses filtros" icone={<FileSearch className="h-6 w-6" />} />
      ) : (
        <>
          <ol className="flex flex-col gap-2">
            {linhas.map((a) => (
              <li key={a.id}>
                <Painel className="px-4 py-3 text-sm">
                  <details>
                    <summary className="flex cursor-pointer flex-wrap items-baseline justify-between gap-2">
                      <span><span className="font-bold">{a.acao.replace(/_/g, " ")}</span> <span className="text-suave">em {ENTIDADES[a.entidade] ?? a.entidade}{a.entidade_id ? ` (${a.entidade_id.slice(0, 13)})` : ""}</span></span>
                      <span className="text-suave">{dataHora(a.em)}{a.ator ? `, ${a.ator}` : ""}</span>
                    </summary>
                    <div className="mt-3 grid grid-cols-1 gap-4 md:grid-cols-2">
                      <div><p className="mb-1 text-xs text-suave">Antes</p><div className="rounded-medio bg-elevada px-3 py-2"><Dados valor={a.antes} /></div></div>
                      <div><p className="mb-1 text-xs text-suave">Depois</p><div className="rounded-medio bg-elevada px-3 py-2"><Dados valor={a.depois} /></div></div>
                    </div>
                    {a.motivo && <p className="mt-2"><span className="text-suave">Motivo:</span> {a.motivo}</p>}
                    <p className="mt-2 text-xs text-suave">Evento nº {a.id}, código {a.hash}</p>
                  </details>
                </Painel>
              </li>
            ))}
          </ol>
          {q.hasNextPage && <div className="mt-4"><Botao onClick={() => q.fetchNextPage()} carregando={q.isFetchingNextPage}>Carregar eventos mais antigos</Botao></div>}
        </>
      )}
    </>
  );
}
