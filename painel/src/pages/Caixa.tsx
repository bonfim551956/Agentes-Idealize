import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { CheckCircle2, CircleDashed, Landmark } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type CaixaPainel } from "../lib/api";
import { data, dinheiro, numero, relativo, rotuloUnidade, type Tom } from "../lib/format";
import { Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, Vazio, cx, entradaCls, td, tdn, th } from "../ui/base";

const ALERTA: Record<string, { rotulo: string; tom: Tom }> = {
  nao_encontrado: { rotulo: "Não achado no extrato", tom: "critico" },
  caixa_nao_fechado: { rotulo: "Caixa não fechado", tom: "critico" },
  dinheiro_sem_deposito: { rotulo: "Dinheiro sem depósito", tom: "atencao" },
  caixa_inconsistente: { rotulo: "Total do caixa não bate", tom: "atencao" },
  extrato_atrasado: { rotulo: "Extrato atrasado", tom: "atencao" },
  sem_registro_no_caixa: { rotulo: "Entrou no extrato e não está no caixa", tom: "neutro" },
};
const FONTE: Record<string, string> = { banco: "extrato do banco", asaas: "Asaas", stone: "Stone" };
const valores = (v: unknown) => (Array.isArray(v) ? v.slice(0, 6).map((x) => dinheiro(Number(x))).join(", ") + (v.length > 6 ? "…" : "") : "");

function textoAlerta(a: CaixaPainel["alertas"][number]): string {
  const d = a.detalhe ?? {};
  switch (a.tipo) {
    case "nao_encontrado": return `${String(d.rotulo)}: ${numero(Number(d.quantidade))} ${Number(d.quantidade) === 1 ? "valor" : "valores"} (${valores(d.valores)}) registrados no caixa e não achados no ${FONTE[String(d.fonte)] ?? "extrato"}.`;
    case "sem_registro_no_caixa": return `${String(d.rotulo)}: ${valores(d.valores)} entrou e não está em nenhum fechamento. Pode ser parcela, sinal ou lançamento esquecido.`;
    case "caixa_nao_fechado": return "Não há fechamento de caixa registrado no sistema para este dia.";
    case "caixa_inconsistente": return `Total do caixa ${dinheiro(Number(d.caixa))}, soma das formas de pagamento ${dinheiro(Number(d.soma_formas))}.`;
    case "dinheiro_sem_deposito": return `${dinheiro(Number(d.dinheiro))} em dinheiro sem depósito registrado depois de ${String(d.prazo_dias)} dias.`;
    case "extrato_atrasado": return `Último dia lido do ${FONTE[String(d.fonte)] ?? String(d.fonte)}: ${d.ultimo_dia ? data(String(d.ultimo_dia)) : "nenhum"}.`;
    default: return "";
  }
}

type Celula = CaixaPainel["conferencia"][number];
function Forma({ c, fonte, rotulo, coberto }: { c: Celula; fonte: string; rotulo: string; coberto: boolean }) {
  const conferivel = ["banco", "asaas", "stone"].includes(fonte);
  const ok = conferivel && c.faltando === 0;
  return (
    <li className="flex items-baseline justify-between gap-3 text-sm">
      <span className="text-suave">{rotulo}</span>
      <span className="flex items-center gap-1 whitespace-nowrap">
        {dinheiro(c.sistema)}
        {!conferivel ? <span className="text-xs text-suave">(sem conferência)</span>
          : ok ? <CheckCircle2 className="h-4 w-4 text-ok" aria-label="achado no extrato" />
          : !coberto ? <CircleDashed className="h-4 w-4 text-suave" aria-label="aguardando extrato" />
          : <span className="text-xs font-bold text-critico">falta {dinheiro(c.faltando)}</span>}
      </span>
    </li>
  );
}

export function Caixa() {
  const { eu } = useSessao();
  const [unidade, setUnidade] = useState("");
  const [dias, setDias] = useState(7);
  const [tipo, setTipo] = useState("");
  const q = useQuery({ queryKey: ["caixa", unidade, dias],
    queryFn: () => rpc<CaixaPainel>("painel_caixa", { p_unidade: unidade || null, p_dias: dias }), refetchInterval: 120_000 });

  return (
    <>
      <Cabecalho titulo="Caixa"
        descricao="Cada valor do fechamento de caixa das lojas procurado no extrato: Pix no banco, Asaas pela API e cartões pela Stone. O agente só confere; não baixa nem altera nada." />
      {q.isLoading ? <Carregando linhas={5} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const c = q.data!;
        const ligado = c.sincronizacao.ativa && c.sincronizacao.agente === "ativo";
        const fonte = Object.fromEntries(c.fontes.map((f) => [f.forma, f]));
        const ate = (u: string, f: string) => c.cobertura.find((x) => x.unidade_id === u && x.fonte === f)?.ate ?? null;
        const alertas = c.alertas.filter((a) => !tipo || a.tipo === tipo);
        const linhas = c.dias.map((d) => ({ ...d, formas: c.conferencia.filter((x) => x.unidade_id === d.unidade_id && x.dia === d.dia) }));
        return (
          <>
            <div role="status" className={cx("mb-8 rounded-grande border px-6 py-4 text-sm",
              ligado ? "border-linha bg-superficie" : "border-atencao/40 bg-atencao-fundo text-atencao")}>
              {ligado
                ? <>Conferindo três vezes por dia. Última conferência {relativo(c.sincronizacao.ultima?.em)}.</>
                : <span className="font-bold">Agente desligado: os números abaixo são da última conferência{c.sincronizacao.ultima ? ` (${relativo(c.sincronizacao.ultima.em)})` : ", e ainda não houve nenhuma"}.</span>}
              <p className="mt-1">Crédito e débito aguardam o arquivo da Stone; Multicrediário e Brasilcard ainda não têm conferência automática.</p>
            </div>

            <div className="mb-6 grid grid-cols-1 gap-2 sm:grid-cols-3 lg:max-w-3xl">
              <label className="sr-only" htmlFor="cx-un">Loja</label>
              <select id="cx-un" className={entradaCls} value={unidade} onChange={(e) => setUnidade(e.target.value)}>
                <option value="">Todas as lojas</option>
                {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
              </select>
              <label className="sr-only" htmlFor="cx-dias">Período</label>
              <select id="cx-dias" className={entradaCls} value={dias} onChange={(e) => setDias(Number(e.target.value))}>
                <option value={3}>Últimos 3 dias</option>
                <option value={7}>Últimos 7 dias</option>
                <option value={31}>Últimos 31 dias</option>
              </select>
              <label className="sr-only" htmlFor="cx-tipo">Tipo de alerta</label>
              <select id="cx-tipo" className={entradaCls} value={tipo} onChange={(e) => setTipo(e.target.value)}>
                <option value="">Todos os alertas</option>
                {Object.entries(ALERTA).map(([k, v]) => <option key={k} value={k}>{v.rotulo}</option>)}
              </select>
            </div>

            <Secao titulo="O que precisa de atenção" descricao="Os avisos somem sozinhos quando o valor aparece no extrato ou o fechamento é corrigido.">
              {!alertas.length ? (
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
                          <p className="mt-1 font-bold">{rotuloUnidade(a.unidade_id, eu.unidades)}{a.dia ? `, ${data(a.dia)}` : ""}</p>
                          <p className="text-sm text-suave">{textoAlerta(a)}</p>
                        </div>
                      </Painel>
                    </li>
                  ))}
                </ul>
              )}
            </Secao>

            <Secao titulo="Conferência por dia" descricao="Cada forma de pagamento do fechamento e se o dinheiro foi achado no extrato.">
              {!linhas.length ? <Vazio titulo="Nenhum fechamento no período" icone={<Landmark className="h-6 w-6" />} /> : (
                <Tabela rotulo="Conferência por dia e loja">
                  <thead><tr><th className={th}>Dia</th><th className={th}>Loja</th><th className={th}>Total do caixa</th><th className={th}>Formas de pagamento</th></tr></thead>
                  <tbody>{linhas.map((l) => (
                    <tr key={`${l.unidade_id}-${l.dia}`}>
                      <td className={tdn}>{data(l.dia)}</td>
                      <td className={td}><span className="font-bold">{rotuloUnidade(l.unidade_id, eu.unidades)}</span></td>
                      <td className={tdn}>
                        {dinheiro(l.caixa)}
                        {l.caixa != null && Math.abs(Number(l.caixa) - Number(l.soma_formas)) > 1 && <p className="text-xs text-atencao">formas somam {dinheiro(l.soma_formas)}</p>}
                      </td>
                      <td className={cx(td, "min-w-[240px]")}>
                        <ul className="flex flex-col gap-1">
                          {l.formas.sort((a, b) => b.sistema - a.sistema).map((f) => {
                            const fo = fonte[f.forma];
                            const cob = fo && ["banco", "asaas", "stone"].includes(fo.fonte) ? ate(l.unidade_id, fo.fonte) : null;
                            return <Forma key={f.forma} c={f} fonte={fo?.fonte ?? "nenhuma"} rotulo={fo?.rotulo ?? f.forma} coberto={Boolean(cob && cob >= l.dia)} />;
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
