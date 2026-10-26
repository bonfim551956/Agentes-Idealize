import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ChevronDown, ChevronRight } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type Financeiro as F, type LinhaDre } from "../lib/api";
import { competenciaRotulo, dataHora, dinheiro, STATUS_FECHAMENTO } from "../lib/format";
import { Botao, Cabecalho, Campo, Carregando, ErroCaixa, Etiqueta, Painel, Tabela, cx, entradaCls, td, tdn, th } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";
import { Impressao } from "../ui/Impressao";

const mesAtual = () => new Date().toISOString().slice(0, 7);

function Dre({ unidade, competencia }: { unidade: string; competencia: string }) {
  const q = useQuery({ queryKey: ["dre", unidade, competencia], queryFn: () => rpc<LinhaDre[]>("painel_dre", { p_unidade: unidade, p_competencia: competencia }) });
  if (q.isLoading) return <Carregando linhas={3} />;
  if (q.error) return <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} />;
  const linhas = q.data!;
  if (!linhas.length) return <p className="text-sm text-suave">Sem lançamentos confirmados nesta competência.</p>;
  const grupos = ["receita", "despesa"].map((n) => ({ n, itens: linhas.filter((l) => l.natureza === n) }));
  return (
    <div className="grid grid-cols-1 gap-6 md:grid-cols-2">
      {grupos.map((g) => (
        <div key={g.n}>
          <h4 className="mb-2 font-bold">{g.n === "receita" ? "Receitas" : "Despesas"}</h4>
          <ul className="flex flex-col text-sm">
            {g.itens.map((l) => (
              <li key={`${l.categoria_id}`} className="flex justify-between gap-4 border-b border-linha/70 py-1">
                <span><span className="block">{l.categoria}</span><span className="block text-xs text-suave">{l.grupo}{l.tem_rateio ? ", com rateio" : ""}</span></span>
                <span className="whitespace-nowrap">{dinheiro(l.valor)}</span>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </div>
  );
}

export function Financeiro() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [mes, setMes] = useState(mesAtual());
  const [aberta, setAberta] = useState<string | null>(null);
  const competencia = `${mes}-01`;
  const q = useQuery({ queryKey: ["financeiro", competencia], queryFn: () => rpc<F>("painel_financeiro", { p_competencia: competencia }) });
  const diretoria = eu.papeis.some((p) => p.papel === "diretoria");

  return (
    <>
      <Cabecalho titulo="Financeiro por loja"
        descricao="Resultado (DRE, pela competência) e caixa (pelo extrato) são contas diferentes: transferências entre lojas mexem no caixa, não no resultado."
        acoes={<Campo id="mes" rotulo="Competência"><input id="mes" type="month" className={entradaCls} value={mes} max={mesAtual()} onChange={(e) => e.target.value && setMes(e.target.value)} /></Campo>} />
      {q.isLoading ? <Carregando /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const f = q.data!;
        return (
          <>
            <h2 className="mb-4 text-lg">{competenciaRotulo(f.competencia)}</h2>
            <Tabela rotulo="Resultado e caixa por loja">
              <thead><tr>
                <th className={th}>Loja</th><th className={th}>Receitas</th><th className={th}>Despesas</th><th className={th}>Resultado</th>
                <th className={th}>Caixa (entradas − saídas)</th><th className={th}>Pendências</th><th className={th}>Fechamento</th>
              </tr></thead>
              <tbody>
                {f.unidades.map((u) => {
                  const st = u.fechamento ? STATUS_FECHAMENTO[u.fechamento.status] : null;
                  const exp = aberta === u.id;
                  return [
                    <tr key={u.id}>
                      <td className={td}>
                        <button onClick={() => setAberta(exp ? null : u.id)} aria-expanded={exp} className="flex items-center gap-1 font-bold text-lente hover:underline">
                          {exp ? <ChevronDown className="h-4 w-4" aria-hidden /> : <ChevronRight className="h-4 w-4" aria-hidden />}{u.nome}
                        </button>
                      </td>
                      <td className={tdn}>{dinheiro(u.receitas)}</td>
                      <td className={tdn}>{dinheiro(u.despesas)}</td>
                      <td className={cx(tdn, "font-bold", u.resultado < 0 ? "text-critico" : "text-ok")}>{dinheiro(u.resultado)}</td>
                      <td className={tdn}>{dinheiro(u.caixa_entradas - u.caixa_saidas)}</td>
                      <td className={td}>{u.pendencias_abertas}{u.pendencias_materiais > 0 && <span className="block text-xs font-bold text-atencao">{u.pendencias_materiais} bloqueiam</span>}</td>
                      <td className={td}>{st ? <Etiqueta tom={st.tom}>{st.rotulo}</Etiqueta> : <span className="text-suave">Não preparado</span>}</td>
                    </tr>,
                    exp && (
                      <tr key={`${u.id}-dre`}><td colSpan={7} className="border-b border-linha bg-elevada/50 px-4 py-4">
                        <Dre unidade={u.id} competencia={competencia} />
                        {u.fechamento && (
                          <Painel className="mt-6 flex flex-col gap-4 p-4 md:flex-row md:items-center md:justify-between">
                            <div className="text-sm">
                              <p className="font-bold">Fechamento versão {u.fechamento.versao}</p>
                              <p className="text-suave">Preparado por {u.fechamento.preparado_por} em {dataHora(u.fechamento.criado_em)}
                                {u.fechamento.validado_por && `, validado por ${u.fechamento.validado_por}`}.</p>
                              <div className="mt-2"><Impressao hash={u.fechamento.pacote_hash} /></div>
                            </div>
                            {u.fechamento.status === "validado" && diretoria && (
                              <div className="flex flex-wrap gap-2">
                                <Confirmar gatilho={<Botao variante="primario">Aprovar fechamento</Botao>}
                                  titulo={`Aprovar o fechamento de ${u.nome}?`} rotuloConfirmar="Aprovar e travar o mês"
                                  descricao="Depois de aprovado, nenhum lançamento novo entra nem muda nesta competência."
                                  detalhes={<div className="flex items-center gap-2 text-sm">Pacote: <Impressao hash={u.fechamento.pacote_hash} /></div>}
                                  aoConfirmar={() => rpc("painel_fechamento_decidir", { p_fechamento: u.fechamento!.id, p_aprovar: true, p_hash: u.fechamento!.pacote_hash })}
                                  aoConcluir={() => qc.invalidateQueries()} />
                                <Confirmar gatilho={<Botao>Rejeitar</Botao>} titulo="Rejeitar o fechamento?" rotuloConfirmar="Rejeitar" variante="perigo"
                                  descricao="O financeiro precisa corrigir e preparar de novo."
                                  motivo={{ rotulo: "O que precisa ser corrigido", minimo: 5 }}
                                  aoConfirmar={(m) => rpc("painel_fechamento_decidir", { p_fechamento: u.fechamento!.id, p_aprovar: false, p_hash: u.fechamento!.pacote_hash, p_motivo: m })}
                                  aoConcluir={() => qc.invalidateQueries()} />
                              </div>
                            )}
                          </Painel>
                        )}
                      </td></tr>
                    ),
                  ];
                })}
                {f.consolidado && (
                  <tr className="bg-elevada/60 font-bold">
                    <td className={td}>Grupo (consolidado)</td>
                    <td className={tdn}>{dinheiro(f.consolidado.receitas)}</td>
                    <td className={tdn}>{dinheiro(f.consolidado.despesas)}</td>
                    <td className={tdn}>{dinheiro(f.consolidado.receitas - f.consolidado.despesas)}</td>
                    <td className={tdn}>{dinheiro(f.consolidado.caixa_entradas - f.consolidado.caixa_saidas)}</td>
                    <td className={td} colSpan={2}><span className="text-xs font-normal text-suave">Sem transferências entre as lojas</span></td>
                  </tr>
                )}
              </tbody>
            </Tabela>
            <p className="mt-4 text-sm text-suave">Só entram na DRE lançamentos confirmados ou conciliados. Valores estimados ficam de fora até serem confirmados.</p>
          </>
        );
      })()}
    </>
  );
}
