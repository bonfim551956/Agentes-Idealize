import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { CheckCircle2, HandCoins } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type CobrancasPainel } from "../lib/api";
import { data, dinheiro, numero, relativo, rotuloUnidade, type Tom } from "../lib/format";
import { Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, Vazio, cx, entradaCls, td, tdn, th } from "../ui/base";

const ALERTA: Record<string, { rotulo: string; tom: Tom }> = {
  cobranca_sem_parcela: { rotulo: "Cobrança ativa sem parcela no sistema", tom: "critico" },
  pago_sem_baixa: { rotulo: "Pago no Asaas, falta baixar", tom: "atencao" },
  baixa_sem_pagamento: { rotulo: "Baixado sem pagamento no Asaas", tom: "critico" },
  parcela_vencida: { rotulo: "Parcela em atraso", tom: "atencao" },
  entrada_pendente: { rotulo: "Entrada não paga", tom: "atencao" },
  parcela_sem_cobranca: { rotulo: "Parcela sem boleto emitido", tom: "neutro" },
};
const FIN: Record<string, string> = { asaas: "Asaas", multicredito: "Multicrédito", outra: "Outra" };

function texto(a: CobrancasPainel["alertas"][number]): { titulo: string; detalhe: string } {
  const d = a.detalhe ?? {};
  const os = d.os ? `OS ${String(d.os)}${d.os_provisoria ? " (provisória)" : ""}` : "OS não informada";
  const parc = d.numero ? `parcela ${String(d.numero)}${d.total ? ` de ${String(d.total)}` : ""}` : "parcela";
  switch (a.tipo) {
    case "parcela_vencida": return { titulo: os, detalhe: `${FIN[String(d.financeira)] ?? ""}: ${numero(Number(d.parcelas))} ${Number(d.parcelas) === 1 ? "parcela" : "parcelas"}, ${dinheiro(Number(d.valor))} em atraso há ${String(d.dias)} dias.` };
    case "pago_sem_baixa": return { titulo: os, detalhe: `${parc} de ${dinheiro(Number(d.valor))} paga no Asaas em ${data(String(d.pago_em))} e ainda em aberto no sistema da loja.` };
    case "baixa_sem_pagamento": return { titulo: os, detalhe: `${parc} de ${dinheiro(Number(d.valor))} baixada no sistema, mas no Asaas continua ${d.status_asaas === "OVERDUE" ? "vencida" : "pendente"}.` };
    case "cobranca_sem_parcela": return { titulo: `Cobrança de ${dinheiro(Number(d.valor))}`, detalhe: `Vence em ${data(String(d.vencimento))} e não corresponde a nenhuma parcela em aberto. Se o carnê foi cancelado ou renegociado, o cliente pode pagar à toa.` };
    case "parcela_sem_cobranca": return { titulo: os, detalhe: `${parc} de ${dinheiro(Number(d.valor))} vence em ${data(String(d.vencimento))} e não tem cobrança emitida no Asaas.` };
    case "entrada_pendente": return { titulo: os, detalhe: `Entrada de ${dinheiro(Number(d.valor))} combinada para ${data(String(d.combinada_para))} e não paga.` };
    default: return { titulo: a.referencia, detalhe: "" };
  }
}

export function Cobrancas() {
  const { eu } = useSessao();
  const [unidade, setUnidade] = useState("");
  const [tipo, setTipo] = useState("");
  const q = useQuery({ queryKey: ["cobrancas", unidade],
    queryFn: () => rpc<CobrancasPainel>("painel_cobrancas", { p_unidade: unidade || null }), refetchInterval: 300_000 });

  return (
    <>
      <Cabecalho titulo="Cobranças"
        descricao="Crediário das lojas: quanto há para receber, quem está em atraso e o que não bate entre o sistema da loja e o Asaas. O agente só acompanha; não envia cobrança nem mexe nas parcelas." />
      {q.isLoading ? <Carregando linhas={5} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const c = q.data!;
        const ligado = c.sincronizacao.ativa && c.sincronizacao.agente === "ativo";
        const alertas = c.alertas.filter((a) => !tipo || a.tipo === tipo);
        const tot = (k: keyof CobrancasPainel["carteira"][number]) => c.carteira.reduce((s, x) => s + Number(x[k]), 0);
        const vencido = tot("vencido_1_30") + tot("vencido_31_60") + tot("vencido_61_90") + tot("vencido_90_mais");
        return (
          <>
            <div role="status" className={cx("mb-8 rounded-grande border px-6 py-4 text-sm",
              ligado ? "border-linha bg-superficie" : "border-atencao/40 bg-atencao-fundo text-atencao")}>
              {ligado
                ? <>Conferindo duas vezes por dia. Última leitura {relativo(c.sincronizacao.ultima?.em)}.</>
                : <span className="font-bold">Agente desligado: os números abaixo são da última leitura{c.sincronizacao.ultima ? ` (${relativo(c.sincronizacao.ultima.em)})` : ", e ainda não houve nenhuma"}.</span>}
              {!c.sincronizacao.asaas_lojas.length && <p className="mt-1">Sem chave do Asaas ainda: o cruzamento com o Asaas aparece quando as chaves das lojas forem cadastradas.</p>}
            </div>

            <div className="mb-6 grid grid-cols-1 gap-2 sm:grid-cols-2 lg:max-w-xl">
              <label className="sr-only" htmlFor="cb-un">Loja</label>
              <select id="cb-un" className={entradaCls} value={unidade} onChange={(e) => setUnidade(e.target.value)}>
                <option value="">Todas as lojas</option>
                {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
              </select>
              <label className="sr-only" htmlFor="cb-tipo">Tipo de alerta</label>
              <select id="cb-tipo" className={entradaCls} value={tipo} onChange={(e) => setTipo(e.target.value)}>
                <option value="">Todos os alertas</option>
                {Object.entries(ALERTA).map(([k, v]) => <option key={k} value={k}>{v.rotulo}</option>)}
              </select>
            </div>

            <dl className="mb-12 grid grid-cols-2 gap-6 sm:grid-cols-4">
              <div><dt className="text-xs text-suave">A receber (total)</dt><dd className="text-2xl font-bold">{dinheiro(tot("a_vencer_total") + vencido)}</dd></div>
              <div><dt className="text-xs text-suave">Vence nos próximos 30 dias</dt><dd className="text-2xl font-bold">{dinheiro(tot("a_vencer_30"))}</dd></div>
              <div><dt className="text-xs text-suave">Em atraso</dt><dd className={cx("text-2xl font-bold", vencido > 0 && "text-critico")}>{dinheiro(vencido)}</dd></div>
              <div><dt className="text-xs text-suave">Clientes em atraso</dt><dd className="text-2xl font-bold">{numero(tot("clientes_em_atraso"))}</dd></div>
            </dl>

            <Secao titulo="O que precisa de atenção" descricao="Os avisos somem sozinhos quando a parcela é paga, baixada ou corrigida.">
              {!alertas.length ? (
                <Vazio titulo="Nada fora do lugar" icone={<CheckCircle2 className="h-6 w-6" />}>
                  {c.sincronizacao.ultima ? "Nenhum atraso nem divergência na última leitura." : "Os avisos aparecem depois da primeira leitura."}
                </Vazio>
              ) : (
                <ul className="flex flex-col gap-2">
                  {alertas.map((a) => {
                    const t = texto(a);
                    return (
                      <li key={a.id}>
                        <Painel className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-start sm:justify-between">
                          <div className="min-w-0">
                            <Etiqueta tom={ALERTA[a.tipo]?.tom}>{ALERTA[a.tipo]?.rotulo ?? a.tipo}</Etiqueta>
                            <p className="mt-1 font-bold">{t.titulo}</p>
                            <p className="text-sm text-suave">{t.detalhe}</p>
                          </div>
                          <p className="shrink-0 text-sm text-suave sm:text-right">{rotuloUnidade(a.unidade_id, eu.unidades)}</p>
                        </Painel>
                      </li>
                    );
                  })}
                </ul>
              )}
            </Secao>

            <Secao titulo="Carteira por loja" descricao="Parcelas em aberto, pelo tempo de atraso.">
              {!c.carteira.length ? <Vazio titulo="Nenhuma parcela em aberto no seu acesso" icone={<HandCoins className="h-6 w-6" />} /> : (
                <Tabela rotulo="Carteira de crediário por loja">
                  <thead><tr><th className={th}>Loja</th><th className={th}>Financeira</th><th className={th}>A vencer</th><th className={th}>Atraso até 30 dias</th>
                    <th className={th}>31 a 60</th><th className={th}>61 a 90</th><th className={th}>Mais de 90</th><th className={th}>Recebido em 30 dias</th></tr></thead>
                  <tbody>{c.carteira.map((x) => {
                    const rec = c.recebido_30d.find((r) => r.unidade_id === x.unidade_id && r.financeira === x.financeira);
                    return (
                      <tr key={`${x.unidade_id}-${x.financeira}`}>
                        <td className={td}><span className="font-bold">{rotuloUnidade(x.unidade_id, eu.unidades)}</span></td>
                        <td className={td}>{FIN[x.financeira] ?? x.financeira}</td>
                        <td className={tdn}>{dinheiro(x.a_vencer_total)}</td>
                        <td className={cx(tdn, x.vencido_1_30 > 0 && "text-atencao")}>{dinheiro(x.vencido_1_30)}</td>
                        <td className={cx(tdn, x.vencido_31_60 > 0 && "font-bold text-atencao")}>{dinheiro(x.vencido_31_60)}</td>
                        <td className={cx(tdn, x.vencido_61_90 > 0 && "font-bold text-critico")}>{dinheiro(x.vencido_61_90)}</td>
                        <td className={cx(tdn, x.vencido_90_mais > 0 && "font-bold text-critico")}>{dinheiro(x.vencido_90_mais)}</td>
                        <td className={tdn}>{dinheiro(rec?.valor ?? 0)}</td>
                      </tr>
                    );
                  })}</tbody>
                </Tabela>
              )}
            </Secao>
            <p className="flex items-center gap-2 text-xs text-suave"><HandCoins className="h-4 w-4" aria-hidden />O painel mostra só o número da OS: nome, CPF e telefone do cliente ficam no sistema da loja.</p>
          </>
        );
      })()}
    </>
  );
}
