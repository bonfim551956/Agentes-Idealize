import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { CheckCircle2, CircleDashed, Landmark } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type CaixaPainel } from "../lib/api";
import { data, dinheiro, numero, relativo, rotuloUnidade, type Tom } from "../lib/format";
import { Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, Vazio, cx, entradaCls, td, tdn, th } from "../ui/base";
import { useFiltroLoja } from "../lib/loja";
import { BarraFiltros, FiltroBusca, FiltroOpcoes, FiltroPeriodo, casaBusca, noPeriodo, periodo, usePeriodo } from "../ui/Filtros";
import { ConversaAviso } from "../ui/ConversaAviso";

const ALERTA: Record<string, { rotulo: string; tom: Tom }> = {
  nao_encontrado: { rotulo: "Não achado no extrato", tom: "critico" },
  caixa_nao_fechado: { rotulo: "Caixa não fechado", tom: "critico" },
  dinheiro_sem_deposito: { rotulo: "Dinheiro sem depósito", tom: "atencao" },
  caixa_inconsistente: { rotulo: "Total do caixa não bate", tom: "atencao" },
  extrato_atrasado: { rotulo: "Extrato atrasado", tom: "atencao" },
  sem_registro_no_caixa: { rotulo: "Entrou e não está no caixa", tom: "critico" },
  multi_divergente: { rotulo: "Multicrediário × caixa", tom: "critico" },
  multi_sem_caixa: { rotulo: "Venda do Multicrediário fora do caixa", tom: "critico" },
  multi_valor_diferente: { rotulo: "Multicrediário: valor diferente", tom: "critico" },
  caixa_multi_sem_venda: { rotulo: "Multicrediário no caixa sem venda", tom: "atencao" },
  multi_outro_dia: { rotulo: "Lançada em outro dia", tom: "neutro" },
  deposito_nao_encontrado: { rotulo: "Dinheiro não depositado", tom: "critico" },
  deposito_sem_caixa: { rotulo: "Depósito sem caixa", tom: "atencao" },
};
const SEMANA = ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"];
const diaSemana = (iso: string) => SEMANA[new Date(iso + "T12:00:00").getDay()];
const FONTE: Record<string, string> = { banco: "extrato do banco", asaas: "Asaas", stone: "Stone" };
const valores = (v: unknown) => (Array.isArray(v) ? v.slice(0, 6).map((x) => dinheiro(Number(x))).join(", ") + (v.length > 6 ? "…" : "") : "");

function textoAlerta(a: CaixaPainel["alertas"][number]): string {
  const d = a.detalhe ?? {};
  switch (a.tipo) {
    case "nao_encontrado": return `${String(d.rotulo)}: ${numero(Number(d.quantidade))} ${Number(d.quantidade) === 1 ? "valor" : "valores"} (${valores(d.valores)}) registrados no caixa e não achados no ${FONTE[String(d.fonte)] ?? "extrato"}.`;
    case "sem_registro_no_caixa": return `${String(d.rotulo)}: ${valores(d.valores)} entrou e não está em nenhum fechamento.${d.loja_fechada ? " A loja não abre nesse dia da semana: confira em qual caixa o cliente foi atendido." : " Pode ser parcela, sinal ou pagamento que o cliente fez sem avisar."}`;
    case "deposito_nao_encontrado": return `${dinheiro(Number(d.dinheiro))} em dinheiro registrado no caixa e não achado como depósito no extrato depois de ${String(d.prazo_dias)} dias.`;
    case "deposito_sem_caixa": return `Depósito em dinheiro de ${valores(d.valores)} no banco que não corresponde a nenhum dia do caixa.`;
    case "multi_divergente": return `Vendas aprovadas no Multicrediário somam ${dinheiro(Number(d.multi_vendas))} e o caixa lançou ${dinheiro(Number(d.caixa_vendas))} como Multicrediário${Number(d.parcelas_no_caixa) > 0 ? ` (fora ${dinheiro(Number(d.parcelas_no_caixa))} de parcelas recebidas na loja)` : ""}.`;
    case "multi_sem_caixa": return `Venda ${String(d.venda)} de ${dinheiro(Number(d.valor_multi))} aprovada no Multicrediário e não lançada no caixa (procurada de ${String(d.dias_antes)} dias antes a ${String(d.dias_depois)} dias depois).`;
    case "multi_valor_diferente": return `Venda ${String(d.venda)}: ${dinheiro(Number(d.valor_multi))} no Multicrediário e ${dinheiro(Number(d.valor_caixa))} no caixa de ${data(String(d.caixa_dia))} (${String(d.caixa_dia_semana)})${Number(d.lancamentos) > 1 ? `, em ${String(d.lancamentos)} lançamentos` : ""}. Diferença de ${dinheiro(Math.abs(Number(d.diferenca)))}.`;
    case "multi_outro_dia": return `Venda ${String(d.venda)} de ${dinheiro(Number(d.valor_multi))} aprovada no Multicrediário neste dia e lançada no caixa de ${data(String(d.caixa_dia))} (${String(d.caixa_dia_semana)}). Valor confere.`;
    case "caixa_multi_sem_venda": return `${dinheiro(Number(d.valor))} lançado como Multicrediário no caixa e não achado como venda nem como parcela recebida no Multicrediário.`;
    case "caixa_nao_fechado": return "Não há fechamento de caixa registrado no sistema para este dia.";
    case "caixa_inconsistente": return `Total do caixa ${dinheiro(Number(d.caixa))}, soma das formas de pagamento ${dinheiro(Number(d.soma_formas))}.`;
    case "dinheiro_sem_deposito": return `${dinheiro(Number(d.dinheiro))} em dinheiro sem depósito registrado depois de ${String(d.prazo_dias)} dias.`;
    case "extrato_atrasado": return `Último dia lido do ${FONTE[String(d.fonte)] ?? String(d.fonte)}: ${d.ultimo_dia ? data(String(d.ultimo_dia)) : "nenhum"}.`;
    default: return "";
  }
}

function formaDoAlerta(a: { tipo: string; detalhe: Record<string, unknown> | null }): string | null {
  if (a.detalhe?.forma) return String(a.detalhe.forma);
  if (a.tipo.startsWith("deposito_") || a.tipo === "dinheiro_sem_deposito") return "dinheiro";
  if (a.tipo.startsWith("multi_") || a.tipo === "caixa_multi_sem_venda") return "crediario";
  return null;
}

type Celula = CaixaPainel["conferencia"][number];
const conferivelForma = (forma: string, fonte: string) => ["banco", "asaas", "stone", "deposito"].includes(fonte) || forma === "crediario";

function Forma({ c, fonte, rotulo, coberto }: { c: Celula; fonte: string; rotulo: string; coberto: boolean }) {
  const conferivel = conferivelForma(c.forma, fonte);
  const ok = conferivel && c.faltando === 0;
  return (
    <li className="flex items-baseline justify-between gap-3 text-sm">
      <span className="text-suave">{rotulo}</span>
      <span className="flex items-center gap-1 whitespace-nowrap">
        {dinheiro(c.sistema)}
        {!conferivel ? <span className="text-xs text-suave">(sem conferência)</span>
          : ok ? <CheckCircle2 className="h-4 w-4 text-ok" aria-label={c.forma === "dinheiro" ? "depósito achado no extrato" : c.forma === "crediario" ? "achado no Multicrediário" : "achado no extrato"} />
          : !coberto ? <CircleDashed className="h-4 w-4 text-suave" aria-label="aguardando extrato" />
          : <span className="text-xs font-bold text-critico">falta {dinheiro(c.faltando)}</span>}
      </span>
    </li>
  );
}

export function Caixa() {
  const { eu } = useSessao();
  const [unidade, setUnidade, travada] = useFiltroLoja();
  const [per, setPer] = usePeriodo("7");
  const [tipo, setTipo] = useState("");
  const [formas, setFormas] = useState<string[]>([]);
  const [situ, setSitu] = useState<string[]>([]);
  const [busca, setBusca] = useState("");
  const [soDif, setSoDif] = useState(false);
  const q = useQuery({ queryKey: ["caixa", unidade, per.de, per.ate],
    queryFn: () => rpc<CaixaPainel>("painel_caixa", { p_unidade: unidade || null, p_de: per.de, p_ate: per.ate }), refetchInterval: 120_000 });
  const ativos = (per.atalho !== "7" ? 1 : 0) + (tipo ? 1 : 0) + (formas.length ? 1 : 0) + (situ.length ? 1 : 0) + (busca.trim() ? 1 : 0) + (soDif ? 1 : 0);
  const limpar = () => { setPer(periodo("7")); setTipo(""); setFormas([]); setSitu([]); setBusca(""); setSoDif(false); };

  return (
    <>
      <Cabecalho titulo="Caixa"
        descricao="Cada valor do fechamento de caixa das lojas procurado no extrato: Pix no banco, Asaas pela API e cartões pela Stone. O agente só confere; não baixa nem altera nada." />
      {q.isLoading ? <Carregando linhas={5} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const c = q.data!;
        const ligado = c.sincronizacao.ativa && c.sincronizacao.agente === "ativo";
        const fonte = Object.fromEntries(c.fontes.map((f) => [f.forma, f]));
        const ate = (u: string, f: string) => c.cobertura.find((x) => x.unidade_id === u && x.fonte === f)?.ate ?? null;
        const desde = (u: string, f: string) => (c.cobertura.find((x) => x.unidade_id === u && x.fonte === f) as { desde?: string | null } | undefined)?.desde ?? null;
        const situacao = (a: { tipo: string; resolvido_em?: string | null }) => a.resolvido_em ? "resolvido" : ({ critico: "urgente", atencao: "atencao" } as Record<string, string>)[ALERTA[a.tipo]?.tom ?? ""] ?? "informativo";
        const todos = [...c.alertas, ...(situ.includes("resolvido") ? (c.resolvidos ?? []) : [])];
        const filtraData = per.atalho !== "7";
        const base = todos.filter((a) => (!filtraData || noPeriodo(a.dia, per)) && (!formas.length || formas.includes(formaDoAlerta(a) ?? "-")) && casaBusca(busca, a.detalhe, a.dia ? data(a.dia) : null));
        const contaSitu = (k: string) => base.filter((a) => situacao(a) === k).length;
        const alertas = base.filter((a) => (!tipo || a.tipo === tipo) && (situ.length ? situ.includes(situacao(a)) : situacao(a) !== "resolvido"));
        // situação do dia: tudo o que dá para conferir foi achado e não há aviso aberto → caixa conferido
        const cobertoAte = (u: string, forma: string, dia: string) => {
          const f = fonte[forma]?.fonte ?? "nenhuma";
          if (forma === "crediario") return true;
          const fo = f === "deposito" ? "banco" : f;
          const a = ate(u, fo), de = desde(u, fo);
          return Boolean(a && a >= dia && (!de || de <= dia));
        };
        const situacaoDia = (d: { unidade_id: string; dia: string; caixa: number | null; soma_formas: number }, todas: { forma: string; faltando: number }[]) => {
          const conf = todas.filter((f) => conferivelForma(f.forma, fonte[f.forma]?.fonte ?? "nenhuma"));
          const avisos = c.alertas.some((a) => a.unidade_id === d.unidade_id && a.dia === d.dia);
          // pendência de verdade = aviso aberto do agente ou total que não fecha; o resto ainda está dentro do prazo de conferência
          if (avisos || (d.caixa != null && Math.abs(Number(d.caixa) - Number(d.soma_formas)) > 1)) return "pendente";
          if (conf.some((f) => f.faltando > 0 && !cobertoAte(d.unidade_id, f.forma, d.dia))) return "aguardando";
          if (conf.some((f) => f.faltando > 0)) return "conferindo";
          return "ok";
        };
        const linhas = c.dias.map((d) => {
          const todas = c.conferencia.filter((x) => x.unidade_id === d.unidade_id && x.dia === d.dia);
          return { ...d, formas: formas.length ? todas.filter((x) => formas.includes(x.forma)) : todas, todas, situacao: situacaoDia(d, todas) };
        }).filter((l) => {
          if (formas.length && !l.formas.length) return false;
          if (soDif && !(l.formas.some((f) => f.faltando > 0 && conferivelForma(f.forma, fonte[f.forma]?.fonte ?? "")) || (l.caixa != null && Math.abs(Number(l.caixa) - Number(l.soma_formas)) > 1))) return false;
          return casaBusca(busca, l.caixa, l.todas.map((f) => [f.sistema, f.valores]), data(l.dia));
        });
        return (
          <>
            <div role="status" className={cx("mb-8 rounded-grande border px-6 py-4 text-sm",
              ligado ? "border-linha bg-superficie" : "border-atencao/40 bg-atencao-fundo text-atencao")}>
              {ligado
                ? <>Conferindo de hora em hora (8h às 20h) e sempre que um extrato ou arquivo da Stone é enviado. Última conferência {relativo(c.sincronizacao.ultima?.em)}.</>
                : <span className="font-bold">Agente desligado: os números abaixo são da última conferência{c.sincronizacao.ultima ? ` (${relativo(c.sincronizacao.ultima.em)})` : ", e ainda não houve nenhuma"}.</span>}
              <p className="mt-1">Pix e depósito do dinheiro: pelo extrato do banco. Crédito e débito: pelo arquivo da Stone. Multicrediário: venda a venda no Multicrediário (São Vicente). Brasilcard ainda sem conferência automática. Dia com tudo achado e sem aviso fica "✓ Conferido".</p>
            </div>

            <BarraFiltros ativos={ativos} aoLimpar={limpar}>
            <div className="grid grid-cols-1 gap-2 lg:grid-cols-[auto_1fr]">
              <FiltroPeriodo id="cx-per" valor={per} aoMudar={setPer} />
              <FiltroBusca id="cx-busca" valor={busca} aoMudar={setBusca} dica="Buscar valor (ex.: 165,27) ou nº da venda" />
            </div>
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:max-w-2xl">
              <label className="sr-only" htmlFor="cx-un">Loja</label>
              <select id="cx-un" className={entradaCls} value={unidade} disabled={travada} title={travada ? "Loja travada no topo da página" : undefined} onChange={(e) => setUnidade(e.target.value)}>
                <option value="">Todas as lojas</option>
                {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
              </select>
              <label className="sr-only" htmlFor="cx-tipo">Tipo de alerta</label>
              <select id="cx-tipo" className={entradaCls} value={tipo} onChange={(e) => setTipo(e.target.value)}>
                <option value="">Todos os alertas</option>
                {Object.entries(ALERTA).filter(([k]) => k !== "multi_divergente" && k !== "dinheiro_sem_deposito").map(([k, v]) => <option key={k} value={k}>{v.rotulo}</option>)}
              </select>
            </div>
            <FiltroOpcoes rotulo="Forma" valor={formas} aoMudar={setFormas}
              opcoes={c.fontes.filter((f) => f.forma !== "outro").map((f) => ({ id: f.forma, rotulo: f.rotulo }))} />
            <FiltroOpcoes rotulo="Situação" valor={situ} aoMudar={setSitu}
              opcoes={[{ id: "urgente", rotulo: "Urgente", n: contaSitu("urgente") }, { id: "atencao", rotulo: "Atenção", n: contaSitu("atencao") },
                { id: "informativo", rotulo: "Informativo", n: contaSitu("informativo") }, { id: "resolvido", rotulo: "Resolvidos" }]} />
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={soDif} onChange={(e) => setSoDif(e.target.checked)} />Na conferência por dia, só dias com diferença</label>
            </BarraFiltros>

            <Secao titulo="O que precisa de atenção" descricao={filtraData ? `Avisos de ${data(per.de)} a ${data(per.ate)}. Somem sozinhos quando o valor aparece no extrato ou o fechamento é corrigido.`
              : "Todos os avisos em aberto, de qualquer data. Somem sozinhos quando o valor aparece no extrato ou o fechamento é corrigido. Mude o período para ver só os de certas datas."}>
              {!alertas.length && ativos ? <Vazio titulo="Nenhum aviso com esses filtros" icone={<CheckCircle2 className="h-6 w-6" />} /> : !alertas.length ? (
                <Vazio titulo="Nada fora do lugar" icone={<CheckCircle2 className="h-6 w-6" />}>
                  {c.sincronizacao.ultima ? "Tudo o que já tem extrato bateu na última conferência." : "Os avisos aparecem depois da primeira conferência."}
                </Vazio>
              ) : (
                <ul className="flex flex-col gap-2">
                  {alertas.map((a) => (
                    <li key={a.id}>
                      <Painel className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-start sm:justify-between">
                        <div className="min-w-0">
                          <Etiqueta tom={ALERTA[a.tipo]?.tom}>{ALERTA[a.tipo]?.rotulo ?? a.tipo}</Etiqueta>
                          {"resolvido_em" in a && a.resolvido_em ? <Etiqueta tom="ok" className="ml-2">{(a as { status?: string }).status === "explicado" ? "explicado" : "resolvido"} {data(String(a.resolvido_em).slice(0, 10))}</Etiqueta> : null}
                          <p className="mt-1 font-bold">{rotuloUnidade(a.unidade_id, eu.unidades)}{a.dia ? `, ${data(a.dia)} (${diaSemana(a.dia)})` : ""}
                            {a.detalhe?.loja_fechada ? <Etiqueta tom="atencao" className="ml-2">loja fechada nesse dia</Etiqueta> : null}</p>
                          <p className="text-sm text-suave">{textoAlerta(a)}</p>
                        </div>
                        <ConversaAviso tipo={a.tipo} referencia={a.referencia} mensagens={Number((a as { mensagens?: number }).mensagens ?? 0)}
                          titulo={`${ALERTA[a.tipo]?.rotulo ?? a.tipo} · ${rotuloUnidade(a.unidade_id, eu.unidades)}${a.dia ? `, ${data(a.dia)}` : ""}. ${textoAlerta(a)}`} />
                      </Painel>
                    </li>
                  ))}
                </ul>
              )}
            </Secao>

            <Secao titulo="Conferência por dia" descricao={`Cada forma de pagamento do fechamento e se o dinheiro foi achado no extrato. ${data(c.desde)} a ${data(c.ate)}.`}>
              {!linhas.length ? <Vazio titulo={ativos ? "Nenhum dia com esses filtros" : "Nenhum fechamento no período"} icone={<Landmark className="h-6 w-6" />} /> : (
                <Tabela rotulo="Conferência por dia e loja">
                  <thead><tr><th className={th}>Dia</th><th className={th}>Loja</th><th className={th}>Total do caixa</th><th className={th}>Formas de pagamento</th></tr></thead>
                  <tbody>{linhas.map((l) => (
                    <tr key={`${l.unidade_id}-${l.dia}`}>
                      <td className={tdn}>{data(l.dia)}
                        <p className="mt-1">{l.situacao === "ok" ? <Etiqueta tom="ok">✓ Conferido</Etiqueta>
                          : l.situacao === "aguardando" ? <Etiqueta tom="neutro">Aguardando arquivo</Etiqueta>
                          : l.situacao === "conferindo" ? <Etiqueta tom="lente">Em conferência</Etiqueta>
                          : <Etiqueta tom="atencao">Tem pendência</Etiqueta>}</p></td>
                      <td className={td}><span className="font-bold">{rotuloUnidade(l.unidade_id, eu.unidades)}</span></td>
                      <td className={tdn}>
                        {dinheiro(l.caixa)}
                        {l.caixa != null && Math.abs(Number(l.caixa) - Number(l.soma_formas)) > 1 && <p className="text-xs text-atencao">formas somam {dinheiro(l.soma_formas)}</p>}
                      </td>
                      <td className={cx(td, "min-w-[240px]")}>
                        <ul className="flex flex-col gap-1">
                          {l.formas.sort((a, b) => b.sistema - a.sistema).map((f) => {
                            const fo = fonte[f.forma];
                            return <Forma key={f.forma} c={f} fonte={fo?.fonte ?? "nenhuma"} rotulo={fo?.rotulo ?? f.forma} coberto={cobertoAte(l.unidade_id, f.forma, l.dia)} />;
                          })}
                        </ul>
                      </td>
                    </tr>
                  ))}</tbody>
                </Tabela>
              )}
            </Secao>
            <p className="flex items-center gap-2 text-xs text-suave"><Landmark className="h-4 w-4" aria-hidden />O painel guarda só loja, dia, forma e valor: cliente, OS e vendedor ficam no sistema da loja.</p>
          </>
        );
      })()}
    </>
  );
}
