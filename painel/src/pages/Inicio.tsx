import { Link } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { AlertTriangle, ArrowRight, CheckCircle2, Clock, Loader2 } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc } from "../lib/api";
import { numero, relativo, rotuloUnidade, STATUS_TAREFA } from "../lib/format";
import { Carregando, ErroCaixa, Etiqueta, Painel, cx } from "../ui/base";
import { VisaoGeral } from "./VisaoGeral";

// Página inicial: cada agente com o que está fazendo agora, as últimas tarefas e o que está pendente.
type Tarefa = { id: string; tipo: string; operacao: string; status: string; unidade_id: string | null; em: string; motivo: string | null };
type AgenteInicio = {
  id: string; nome: string; status: string; descricao: string | null;
  operando: { tipo: string; operacao: string; status: string; desde: string; unidade_id: string | null }[] | null;
  fila: number; esperando: number; ultima: string | null; ultima_status: string | null; rodadas: number; falhas: number;
  novos: number; abertos: number; rotulo_novos: string; rotulo_abertos: string; tarefas: Tarefa[];
};
type ItemCentral = { area: string; gravidade: number; titulo: string; texto: string; link: string; unidade_id: string | null };

const TELA: Record<string, string> = {
  comercial: "/comercial", laboratorio: "/laboratorio", financeiro: "/pendencias", caixa: "/caixa", cobrancas: "/cobrancas",
  supervisor: "/supervisor", rh: "/rh", marketing: "/marketing", radar: "/mercado", concorrentes: "/mercado",
  conteudo_ideias: "/conteudo", conteudo_avaliador: "/conteudo", conteudo_roteirista: "/conteudo", conversoes: "/retorno",
  atribuicao: "/retorno", multicrediario: "/multicrediario", auditor_atendimento: "/atendimento",
};
const AREA: Record<string, string> = { Caixa: "caixa", "Cobranças": "cobrancas", "Multicrediário": "multicrediario", Arquivos: "financeiro", Financeiro: "financeiro", Plataforma: "supervisor" };
const AGENDA: Record<string, string> = {
  comercial: "a cada 15 min", laboratorio: "a cada 15 min", financeiro: "a cada 5 min e quando você envia arquivo", caixa: "de hora em hora, 8h às 20h",
  cobrancas: "de hora em hora, 8h às 20h", multicrediario: "de hora em hora, 8h às 20h", atribuicao: "de hora em hora, 8h às 20h",
  supervisor: "de hora em hora", marketing: "de hora em hora", rh: "1 vez por dia", radar: "1 vez por dia", concorrentes: "1 vez por dia",
  conteudo_ideias: "1 vez por dia", conteudo_avaliador: "1 vez por dia", conteudo_roteirista: "1 vez por dia", conversoes: "de hora em hora, 9h às 19h",
  auditor_atendimento: "1 vez por dia, 7h",
};
const nomeTipo = (t: string) => /sincronizacao$/.test(t) ? "rodada de conferência" : t === "fin_envio" ? "arquivo enviado"
  : /varredura$/.test(t) ? "varredura" : /diario$/.test(t) ? "rodada do dia" : t === "sup_verificacao" ? "verificação geral" : t.replace(/_/g, " ");
const FAZENDO: Record<string, string> = { sincronizar: "Conferindo", ler: "Lendo arquivo", pesquisar: "Pesquisando", criar: "Escrevendo" };

function CartaoAgente({ a, pend }: { a: AgenteInicio; pend: ItemCentral[] }) {
  const { eu } = useSessao();
  const operando = (a.operando ?? []).length > 0;
  const pausado = a.status !== "ativo";
  const urg = pend.filter((p) => p.gravidade === 1).length;
  return (
    <Painel className={cx("flex flex-col gap-4 p-6", operando && "border-2 border-lente")}>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="text-xl font-bold">{a.nome}</h3>
          {a.descricao && <p className="mt-1 line-clamp-2 text-sm text-suave">{a.descricao}</p>}
        </div>
        {operando ? <Etiqueta tom="lente"><Loader2 className="mr-1 inline h-3 w-3 animate-spin" aria-hidden />Operando agora</Etiqueta>
          : pausado ? <Etiqueta tom="atencao">{a.status === "pausado" ? "Pausado" : a.status}</Etiqueta>
          : <Etiqueta tom="neutro">Em espera</Etiqueta>}
      </div>

      {operando ? (
        <div className="rounded-medio bg-lente-clara px-4 py-3 text-sm">
          {a.operando!.map((o, i) => (
            <p key={i}><b>{FAZENDO[o.operacao] ?? o.operacao}</b> · {nomeTipo(o.tipo)}{o.unidade_id ? ` · ${rotuloUnidade(o.unidade_id, eu.unidades)}` : ""} · desde {relativo(o.desde)}</p>
          ))}
        </div>
      ) : (
        <p className="flex items-center gap-2 text-sm text-suave"><Clock className="h-4 w-4" aria-hidden />
          Última rodada {a.ultima ? relativo(a.ultima) : "ainda não houve"}{AGENDA[a.id] ? ` · roda ${AGENDA[a.id]}` : ""}</p>
      )}

      <dl className="grid grid-cols-3 gap-3">
        <div><dt className="text-xs text-suave">Rodadas em 24 h</dt><dd className="text-2xl font-bold">{numero(a.rodadas)}</dd>
          {a.falhas > 0 && <dd className="text-xs font-bold text-critico">{a.falhas} com falha</dd>}</div>
        <div><dt className="text-xs text-suave">{a.rotulo_novos.replace(/^./, (c) => c.toUpperCase())}</dt>
          <dd className={cx("text-2xl font-bold", a.novos > 0 && "text-atencao")}>{numero(a.novos)}</dd></div>
        {a.rotulo_abertos ? <div><dt className="text-xs text-suave">{a.rotulo_abertos.replace(/^./, (c) => c.toUpperCase())}</dt>
          <dd className="text-2xl font-bold">{numero(a.abertos)}</dd></div> : <div />}
      </dl>

      {(pend.length > 0 || a.esperando > 0 || a.fila > 0) && (
        <div className="flex flex-col gap-2">
          <p className="text-sm font-bold">Pendências{urg > 0 && <span className="ml-1 text-critico">({urg} urgente{urg > 1 ? "s" : ""})</span>}</p>
          {a.esperando > 0 && <Link to={`/tarefas?agente=${a.id}&status=aguardando_aprovacao`} className="flex items-center gap-2 text-sm text-atencao hover:underline">
            <AlertTriangle className="h-4 w-4" aria-hidden />{a.esperando} tarefa(s) esperando você (aprovação ou conferência)</Link>}
          {a.fila > 0 && <p className="text-sm text-suave">{a.fila} tarefa(s) na fila</p>}
          <ul className="flex flex-col gap-1">
            {pend.slice(0, 3).map((p, i) => (
              <li key={i} className="text-sm">
                <Link to={p.link} className="group flex gap-2 hover:underline">
                  <span className={cx("mt-1.5 h-2 w-2 shrink-0 rounded-full", p.gravidade === 1 ? "bg-critico" : p.gravidade === 2 ? "bg-atencao" : "bg-suave")} aria-hidden />
                  <span className="min-w-0"><b>{p.titulo}</b> <span className="text-suave">{p.texto}</span></span>
                </Link>
              </li>
            ))}
          </ul>
          {pend.length > 3 && <p className="text-xs text-suave">e mais {pend.length - 3}</p>}
        </div>
      )}

      <div className="flex flex-col gap-2">
        <p className="text-sm font-bold">Últimas tarefas</p>
        {!a.tarefas.length ? <p className="text-sm text-suave">Nenhuma tarefa registrada pelo painel (este agente roda fora da fila de tarefas).</p> : (
          <ul className="flex flex-col gap-1">
            {a.tarefas.slice(0, 3).map((t) => (
              <li key={t.id} className="flex items-center justify-between gap-2 text-sm">
                <Link to={`/tarefas/${t.id}`} className="min-w-0 truncate hover:underline">{FAZENDO[t.operacao] ?? t.operacao} · {nomeTipo(t.tipo)}</Link>
                <span className="flex shrink-0 items-center gap-2"><Etiqueta tom={STATUS_TAREFA[t.status]?.tom}>{STATUS_TAREFA[t.status]?.rotulo ?? t.status}</Etiqueta>
                  <span className="text-xs text-suave">{relativo(t.em)}</span></span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="mt-auto flex flex-wrap gap-2 border-t border-linha pt-4">
        {TELA[a.id] && <Link to={TELA[a.id]} className="flex items-center gap-1 rounded-medio bg-lente-forte px-3 py-2 text-sm font-bold sobre-lente hover:bg-lente-forte/90">Abrir {a.nome.replace(/^Agente (de |do |da )?/, "")} <ArrowRight className="h-4 w-4" aria-hidden /></Link>}
        <Link to={`/tarefas?agente=${a.id}`} className="rounded-medio border border-linha px-3 py-2 text-sm font-bold hover:bg-elevada">Todas as tarefas</Link>
      </div>
    </Painel>
  );
}

export function Inicio() {
  const { eu } = useSessao();
  const q = useQuery({ queryKey: ["inicio"], queryFn: () => rpc<{ agora: string; agentes: AgenteInicio[] }>("painel_inicio"), refetchInterval: 30_000, enabled: eu.pode.consultar_global });
  const c = useQuery({ queryKey: ["central", ""], queryFn: () => rpc<{ itens: ItemCentral[]; urgentes: number; total: number }>("painel_central", { p_unidade: null }),
    refetchInterval: 120_000, enabled: eu.pode.consultar_global });
  if (!eu.pode.consultar_global) return <VisaoGeral />;
  if (q.isLoading) return <Carregando linhas={6} rotulo="Carregando os agentes" />;
  if (q.error) return <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} />;
  const ag = q.data!.agentes;
  const itens = c.data?.itens ?? [];
  const operando = ag.filter((a) => (a.operando ?? []).length > 0).length;
  const falhas = ag.reduce((s, a) => s + a.falhas, 0);
  return (
    <>
      <div className="mb-8 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
        <div>
          <h1 className="text-3xl font-bold">Seus agentes</h1>
          <p className="mt-2 text-suave">O que cada um está fazendo agora, o que fez nas últimas 24 horas e o que ficou pendente. Atualiza sozinho a cada 30 segundos.</p>
        </div>
        <Link to="/visao-geral" className="text-sm font-bold text-lente hover:underline">Estado da plataforma →</Link>
      </div>

      <div className="mb-8 grid grid-cols-2 gap-3 md:grid-cols-4">
        <Painel className="p-4"><p className="text-xs text-suave">Operando agora</p><p className="text-3xl font-bold text-lente">{operando}</p><p className="text-xs text-suave">de {ag.length} agentes</p></Painel>
        <Link to="/central"><Painel className="h-full p-4 hover:bg-elevada"><p className="text-xs text-suave">Para resolver</p><p className="text-3xl font-bold">{numero(c.data?.total ?? 0)}</p><p className="text-xs text-suave">ver tudo →</p></Painel></Link>
        <Link to="/central"><Painel className="h-full p-4 hover:bg-elevada"><p className="text-xs text-suave">Urgentes</p><p className={cx("text-3xl font-bold", (c.data?.urgentes ?? 0) > 0 && "text-critico")}>{numero(c.data?.urgentes ?? 0)}</p><p className="text-xs text-suave">em Tudo para resolver</p></Painel></Link>
        <Painel className="p-4"><p className="text-xs text-suave">Falhas em 24 h</p><p className={cx("text-3xl font-bold", falhas > 0 ? "text-critico" : "text-ok")}>{falhas}</p>
          <p className="flex items-center gap-1 text-xs text-suave">{falhas === 0 ? <><CheckCircle2 className="h-3 w-3" aria-hidden />tudo rodando</> : "veja nos cartões"}</p></Painel>
      </div>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2 2xl:grid-cols-3">
        {ag.map((a) => <CartaoAgente key={a.id} a={a} pend={itens.filter((i) => AREA[i.area] === a.id)} />)}
      </div>
    </>
  );
}
