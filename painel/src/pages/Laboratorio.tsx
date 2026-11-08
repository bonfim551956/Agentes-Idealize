import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { CheckCircle2, FlaskConical } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type LabPainel } from "../lib/api";
import { data, relativo, rotuloUnidade, type Tom } from "../lib/format";
import { Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, Vazio, cx, entradaCls, td, th } from "../ui/base";
import { useFiltroLoja } from "../lib/loja";
import { BarraFiltros, FiltroBusca, FiltroOpcoes, FiltroPeriodo, casaBusca, noPeriodo, periodo, usePeriodo } from "../ui/Filtros";
import { Resolvidos } from "../ui/Resolvidos";

const ALERTA: Record<string, { rotulo: string; tom: Tom }> = {
  prazo_vencido: { rotulo: "Prazo vencido", tom: "critico" },
  parado_na_etapa: { rotulo: "Parado na etapa", tom: "atencao" },
  sem_pedido_lab: { rotulo: "Sem número do pedido no laboratório", tom: "atencao" },
  aguardando_retirada: { rotulo: "Avisado e não retirado", tom: "lente" },
  refeito: { rotulo: "Refeito", tom: "neutro" },
  etapa_desconhecida: { rotulo: "Coluna do kanban sem nome", tom: "neutro" },
  unidade_desconhecida: { rotulo: "Loja não reconhecida", tom: "neutro" },
};

function detalheAlerta(a: LabPainel["alertas"][number]): string {
  const d = a.detalhe ?? {};
  const dias = typeof d.dias === "number" ? d.dias : null;
  switch (a.tipo) {
    case "prazo_vencido": return `Prazo era ${data(a.prazo)}${dias != null ? `, ${dias} ${dias === 1 ? "dia" : "dias"} atrás` : ""}.`;
    case "parado_na_etapa": return `Em "${a.etapa}" há ${dias ?? "?"} dias (limite ${String(d.limite_dias ?? "?")}).`;
    case "aguardando_retirada": return `Cliente avisado há ${dias ?? "?"} dias${d.saldo_aberto ? ", com saldo a receber" : ""}.`;
    case "sem_pedido_lab": return `Está em "${a.etapa}" sem o número do pedido no laboratório.`;
    default: return a.etapa;
  }
}

export function Laboratorio() {
  const { eu } = useSessao();
  const [unidade, setUnidade, travada] = useFiltroLoja();
  const [tipos, setTipos] = useState<string[]>([]);
  const [busca, setBusca] = useState("");
  const [per, setPer] = usePeriodo("30");
  const [soUrgentes, setSoUrgentes] = useState(false);
  const ativos = (per.atalho !== "30" ? 1 : 0) + tipos.length + (busca ? 1 : 0) + (soUrgentes ? 1 : 0);
  const q = useQuery({ queryKey: ["lab", unidade], queryFn: () => rpc<LabPainel>("painel_lab", { p_unidade: unidade || null }), refetchInterval: 60_000 });

  return (
    <>
      <Cabecalho titulo="Laboratório"
        descricao="Ordens de serviço do kanban das lojas: o que está atrasado, parado ou esperando o cliente. O agente só acompanha; não faz nem altera pedidos." />
      {q.isLoading ? <Carregando linhas={5} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const l = q.data!;
        const ativas = l.etapas.filter((e) => e.situacao !== "encerrada");
        const base = l.alertas.filter((a) => (per.atalho === "30" || noPeriodo(a.aberto_em, per)) && (!soUrgentes || a.urgente)
          && casaBusca(busca, a.os, a.pedido, a.laboratorio, a.etapa, a.tipo_os));
        const alertas = base.filter((a) => !tipos.length || tipos.includes(a.tipo));
        const naoConfirmadas = l.etapas.filter((e) => !e.confirmada).map((e) => e.nome);
        return (
          <>
            <div role="status" className={cx("mb-8 rounded-grande border px-6 py-4 text-sm",
              l.sincronizacao.ativa && l.sincronizacao.agente === "ativo" ? "border-linha bg-superficie" : "border-atencao/40 bg-atencao-fundo text-atencao")}>
              {l.sincronizacao.ativa && l.sincronizacao.agente === "ativo"
                ? <>Sincronizando com o kanban. Última leitura {relativo(l.sincronizacao.ultima?.em)}.</>
                : <span className="font-bold">Agente desligado: os números abaixo são da última leitura{l.sincronizacao.ultima ? ` (${relativo(l.sincronizacao.ultima.em)})` : ", e ainda não houve nenhuma"}.</span>}
              {naoConfirmadas.length > 0 && <p className="mt-1">Ainda sem nome conferido: {naoConfirmadas.join(", ")}.</p>}
            </div>

            <BarraFiltros ativos={ativos} aoLimpar={() => { setPer(periodo("30")); setTipos([]); setBusca(""); setSoUrgentes(false); }}>
              <div className="grid grid-cols-1 gap-2 lg:grid-cols-[auto_1fr_1fr]">
                <FiltroPeriodo id="l-per" valor={per} aoMudar={setPer} />
                <FiltroBusca id="l-busca" valor={busca} aoMudar={setBusca} dica="Buscar OS, pedido, laboratório ou etapa" />
                <div>
                  <label className="sr-only" htmlFor="l-un">Loja</label>
                  <select id="l-un" className={entradaCls} value={unidade} disabled={travada} title={travada ? "Loja travada no topo da página" : undefined} onChange={(e) => setUnidade(e.target.value)}>
                    <option value="">Todas as lojas</option>
                    {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
                  </select>
                </div>
              </div>
              <FiltroOpcoes rotulo="Tipo" valor={tipos} aoMudar={setTipos}
                opcoes={Object.entries(ALERTA).map(([k, v]) => ({ id: k, rotulo: v.rotulo, n: base.filter((x) => x.tipo === k).length })).filter((o) => o.n > 0 || tipos.includes(o.id))} />
              <label className="flex items-center gap-2 text-sm"><input type="checkbox" className="h-4 w-4" checked={soUrgentes} onChange={(e) => setSoUrgentes(e.target.checked)} />Só ordens urgentes</label>
            </BarraFiltros>

            <Secao titulo="Em andamento por etapa">
              {!l.unidades.length ? <Vazio titulo="Nenhuma loja no seu acesso" /> : (
                <Tabela rotulo="Ordens em andamento por etapa">
                  <thead><tr><th className={th}>Loja</th>{ativas.map((e) => <th key={e.col} className={th}>{e.nome}</th>)}<th className={th}>Alertas</th></tr></thead>
                  <tbody>{l.unidades.map((u) => {
                    const nAl = Object.values(u.alertas).reduce((a, b) => a + b, 0);
                    return (
                      <tr key={u.id}>
                        <td className={td}><span className="font-bold">{u.nome}</span></td>
                        {ativas.map((e) => <td key={e.col} className={td}>{u.por_etapa[String(e.col)] ?? 0}</td>)}
                        <td className={cx(td, nAl > 0 && "font-bold text-atencao")}>{nAl}</td>
                      </tr>
                    );
                  })}</tbody>
                </Tabela>
              )}
            </Secao>

            <Secao titulo={`Alertas abertos (${alertas.length})`} descricao={`Só o que falta resolver. Quando a ordem anda no kanban, o aviso sai daqui e vai para "Já resolvidos".${per.atalho !== "30" ? " Mostrando os abertos no período escolhido." : ""}`}>
              {!alertas.length ? (
                <Vazio titulo="Nenhum alerta aberto" icone={<CheckCircle2 className="h-6 w-6" />}>
                  {l.sincronizacao.ultima ? "Tudo dentro do prazo na última leitura." : "Os alertas aparecem depois da primeira leitura do kanban."}
                </Vazio>
              ) : (
                <ul className="flex flex-col gap-2">
                  {alertas.map((a) => (
                    <li key={a.id}>
                      <Painel className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-start sm:justify-between">
                        <div className="min-w-0">
                          <div className="flex flex-wrap items-center gap-2">
                            <Etiqueta tom={ALERTA[a.tipo]?.tom}>{ALERTA[a.tipo]?.rotulo ?? a.tipo}</Etiqueta>
                            {a.urgente && <Etiqueta tom="critico">Urgente</Etiqueta>}
                          </div>
                          <p className="mt-1 font-bold">OS {a.os ?? "sem número"}{a.pedido ? `, pedido ${a.pedido}` : ""}</p>
                          <p className="text-sm text-suave">{detalheAlerta(a)}</p>
                        </div>
                        <div className="shrink-0 text-sm text-suave sm:text-right">
                          <p>{rotuloUnidade(a.unidade_id, eu.unidades)}</p>
                          <p>{a.laboratorio ?? "Laboratório não informado"}</p>
                          <p>{a.tipo_os}</p>
                        </div>
                      </Painel>
                    </li>
                  ))}
                </ul>
              )}
            </Secao>
            <Resolvidos area="laboratorio" unidade={unidade} periodo={per} busca={busca} tipos={tipos} rotulos={ALERTA}
              descrever={(a) => ({ titulo: `OS ${a.titulo ?? "sem número"}`, detalhe: a.tipo === "prazo_vencido" ? "Estava com o prazo vencido; a ordem andou." : a.tipo === "parado_na_etapa" ? "Estava parada na etapa; a ordem andou." : "" })} />
            <p className="flex items-center gap-2 text-xs text-suave"><FlaskConical className="h-4 w-4" aria-hidden />O painel mostra só OS, pedido e etapa: nome, telefone e receita do cliente ficam no kanban.</p>
          </>
        );
      })()}
    </>
  );
}
