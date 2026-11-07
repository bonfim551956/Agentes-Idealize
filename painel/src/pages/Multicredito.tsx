import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useSessao } from "../auth/Sessao";
import { rpc } from "../lib/api";
import { data, dinheiro, relativo, type Tom } from "../lib/format";
import { traduzir } from "../lib/erros";
import { Botao, Cabecalho, Campo, Carregando, ErroCaixa, Etiqueta, Painel, Vazio, cx, entradaCls } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

// Conferência do Multicrediário × ADM (São Vicente). O robô lê o Multicrediário às 7h; a conferência roda às 7h40.
type Aviso = { id: number; tipo: string; dia: string | null; descricao: string; aberto_em: string };
type Resolvido = { id: number; tipo: string; dia: string | null; descricao: string; resolvido_em: string; resolvido_por: string | null; nota: string | null };
type Venda = { venda: string; os: string | null; plano: string | null; garantido: number; adm: number | null; situacao: string };
type Negada = { venda: string; tipo: number; valor: number | null; resposta: string | null };
type Recebida = { venda: string; parcela: number | null; valor: number | null };
type Dados = {
  dia: string; pode_editar: boolean; ultima_leitura: string | null; ultima_conferencia: string | null; dias: string[];
  resumo: { aprovadas: number; aprovado_valor: number; negadas: number; canceladas: number; parcelas: number; parcelas_valor: number; abertos: number };
  abertos: Aviso[]; vendas: Venda[]; negadas: Negada[]; recebidas: Recebida[]; resolvidos: Resolvido[];
};
type Ajustes = { unidades: string; tolerancia: number; adm_inicio: string; pode_editar: boolean };

const TIPO: Record<string, { rotulo: string; tom: Tom }> = {
  valor_diferente: { rotulo: "Valor diferente", tom: "critico" },
  valor_com_entrada: { rotulo: "ADM somou a entrada", tom: "atencao" },
  centavos: { rotulo: "Centavos", tom: "neutro" },
  venda_sem_adm: { rotulo: "Venda sem ADM", tom: "critico" },
  adm_sem_venda: { rotulo: "ADM sem venda", tom: "critico" },
  sem_os: { rotulo: "Sem OS", tom: "atencao" },
  data_diferente: { rotulo: "Data diferente", tom: "neutro" },
  parcela_sem_baixa: { rotulo: "Parcela sem baixa", tom: "atencao" },
  parcela_sem_carne: { rotulo: "Carnê fora do ADM", tom: "critico" },
  documento_pendente: { rotulo: "Documento", tom: "critico" },
};
const SITUACAO: Record<string, { rotulo: string; tom: Tom }> = {
  ok: { rotulo: "Bate com o ADM", tom: "ok" },
  centavos: { rotulo: "Centavos", tom: "neutro" },
  valor_com_entrada: { rotulo: "ADM somou a entrada", tom: "atencao" },
  valor_diferente: { rotulo: "Valor diferente", tom: "critico" },
  venda_sem_adm: { rotulo: "Não está no ADM", tom: "critico" },
};
const ABAS = [["avisos", "Para resolver"], ["vendas", "Vendas do dia"], ["parcelas", "Parcelas recebidas"], ["resolvidos", "Resolvidos"], ["regras", "Regras"]] as const;

function Cartao({ rotulo, valor, detalhe, tom }: { rotulo: string; valor: string; detalhe?: string; tom?: "critico" | "ok" }) {
  return (
    <Painel className="p-4">
      <p className="text-xs text-suave">{rotulo}</p>
      <p className={cx("text-2xl font-bold", tom === "critico" && "text-critico", tom === "ok" && "text-ok")}>{valor}</p>
      {detalhe && <p className="text-xs text-suave">{detalhe}</p>}
    </Painel>
  );
}

function Regras() {
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ["multi-ajustes"], queryFn: () => rpc<Ajustes>("painel_multi_ajustes") });
  const [form, setForm] = useState<{ tolerancia: string; adm_inicio: string; unidades: string } | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [salvo, setSalvo] = useState(false);
  const [enviando, setEnviando] = useState(false);
  if (q.isLoading) return <Carregando linhas={3} />;
  if (q.error || !q.data) return <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} />;
  const a = q.data;
  const f = form ?? { tolerancia: String(a.tolerancia).replace(".", ","), adm_inicio: a.adm_inicio, unidades: a.unidades };
  async function salvar() {
    setEnviando(true); setErro(null); setSalvo(false);
    try {
      const tol = Number(f.tolerancia.replace(",", "."));
      if (Number.isNaN(tol)) throw new Error("Tolerância inválida.");
      await rpc("painel_multi_ajustes_salvar", { p_tolerancia: tol, p_adm_inicio: f.adm_inicio, p_unidades: f.unidades, p_motivo: null });
      setForm(null); setSalvo(true);
      void qc.invalidateQueries({ queryKey: ["multi-ajustes"] }); void qc.invalidateQueries({ queryKey: ["multi"] });
    } catch (e) { setErro(traduzir(e).message); } finally { setEnviando(false); }
  }
  return (
    <Painel className="flex max-w-leitura flex-col gap-4 p-4 md:p-6">
      <p className="text-sm text-suave">Regras que o agente usa para conferir. Ao salvar, a conferência roda de novo na hora.</p>
      <Campo id="m-tol" rotulo="Diferença tolerada (R$)" ajuda="Até este valor, a venda conta como igual. Acima disso e até R$ 1,00 vira aviso de centavos.">
        <input id="m-tol" inputMode="decimal" className={entradaCls} disabled={!a.pode_editar} value={f.tolerancia} onChange={(e) => setForm({ ...f, tolerancia: e.target.value })} />
      </Campo>
      <Campo id="m-ini" rotulo="Crediário lançado no ADM desde" ajuda="Parcela de venda anterior a esta data não gera aviso de carnê fora do ADM.">
        <input id="m-ini" type="date" className={entradaCls} disabled={!a.pode_editar} value={f.adm_inicio} onChange={(e) => setForm({ ...f, adm_inicio: e.target.value })} />
      </Campo>
      <Campo id="m-un" rotulo="Unidades do ADM conferidas" ajuda="Separadas por vírgula, como estão no ADM (ex.: saovicente).">
        <input id="m-un" className={entradaCls} disabled={!a.pode_editar} value={f.unidades} onChange={(e) => setForm({ ...f, unidades: e.target.value })} />
      </Campo>
      {erro && <p role="alert" className="text-sm font-bold text-critico">{erro}</p>}
      {salvo && <p role="status" className="text-sm font-bold text-ok">Regras salvas e conferência refeita.</p>}
      {a.pode_editar ? (
        <div><Botao variante="primario" carregando={enviando} onClick={salvar}>Salvar regras</Botao></div>
      ) : <p className="text-sm text-suave">Só a diretoria altera estas regras.</p>}
    </Painel>
  );
}

export function Multicredito() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [aba, setAba] = useState<(typeof ABAS)[number][0]>("avisos");
  const [dia, setDia] = useState("");
  const q = useQuery({ queryKey: ["multi", dia], queryFn: () => rpc<Dados>("painel_multi", { p_dia: dia || null }), enabled: eu.pode.consultar_global });

  if (!eu.pode.consultar_global) return <Vazio titulo="Multicrediário">Esta tela fica com a diretoria.</Vazio>;
  const d = q.data;
  const concluir = () => { void qc.invalidateQueries({ queryKey: ["multi"] }); };
  const contagem: Record<string, number | undefined> = { avisos: d?.abertos.length, vendas: d?.vendas.length, parcelas: d?.recebidas.length };
  return (
    <>
      <Cabecalho titulo="Multicrediário × ADM"
        descricao={d ? `São Vicente · ${data(d.dia)} · leitura do Multicrediário ${d.ultima_leitura ? relativo(d.ultima_leitura) : "ainda não feita"}${d.ultima_conferencia ? ` · conferido ${relativo(d.ultima_conferencia)}` : ""}`
          : "Vendas no crediário, documentos e parcelas recebidas, conferidos com o ADM todo dia às 7h40."}
        acoes={d && d.dias.length > 0 ? (
          <>
            <label className="sr-only" htmlFor="multi-dia">Dia</label>
            <select id="multi-dia" className={entradaCls + " w-auto"} value={dia || d.dia} onChange={(e) => setDia(e.target.value === d.dias[0] ? "" : e.target.value)}>
              {d.dias.map((x) => <option key={x} value={x}>{data(x)}</option>)}
            </select>
          </>
        ) : undefined} />

      {d && (
        <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
          <Cartao rotulo="Vendas aprovadas no dia" valor={String(d.resumo.aprovadas)} detalhe={`${dinheiro(d.resumo.aprovado_valor)} financiado`} />
          <Cartao rotulo="Negadas / canceladas" valor={`${d.resumo.negadas} / ${d.resumo.canceladas}`} detalhe="consultas que não viraram venda" />
          <Cartao rotulo="Parcelas recebidas no dia" valor={String(d.resumo.parcelas)} detalhe={dinheiro(d.resumo.parcelas_valor)} />
          <Cartao rotulo="Para resolver (todos os dias)" valor={String(d.resumo.abertos)} tom={d.resumo.abertos > 0 ? "critico" : "ok"} detalhe={d.resumo.abertos > 0 ? "veja abaixo" : "tudo certo"} />
        </div>
      )}

      <div role="tablist" aria-label="Seções" className="mb-6 flex flex-wrap gap-2">
        {ABAS.map(([k, r]) => (
          <button key={k} role="tab" aria-selected={aba === k} onClick={() => setAba(k)}
            className={cx("rounded-medio border px-4 py-2 text-sm", aba === k ? "border-lente bg-lente-clara font-bold text-lente" : "border-linha hover:bg-elevada")}>
            {r}{contagem[k] ? ` (${contagem[k]})` : ""}
          </button>
        ))}
      </div>

      {aba === "regras" ? <Regras /> : q.isLoading ? <Carregando linhas={8} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !d ? null : aba === "avisos" ? (
        d.abertos.length === 0 ? <Vazio titulo="Nada para resolver">Tudo o que o robô leu no Multicrediário bate com o ADM.</Vazio> : (
          <ul className="flex flex-col gap-2">
            {d.abertos.map((a) => (
              <li key={a.id}>
                <Painel className="flex flex-col gap-3 p-4 md:flex-row md:items-center md:justify-between">
                  <div className="min-w-0">
                    <div className="mb-1 flex flex-wrap items-center gap-2">
                      <Etiqueta tom={TIPO[a.tipo]?.tom}>{TIPO[a.tipo]?.rotulo ?? a.tipo}</Etiqueta>
                      {a.dia && <span className="text-xs text-suave">{data(a.dia)}</span>}
                    </div>
                    <p>{a.descricao}</p>
                  </div>
                  {d.pode_editar && (
                    <Confirmar gatilho={<Botao tamanho="sm">Resolver</Botao>} titulo="Marcar como resolvido?" rotuloConfirmar="Resolver"
                      descricao={<>{a.descricao}<br />Se corrigir no ADM, o aviso fecha sozinho na próxima conferência. Use aqui quando a diferença for explicada.</>}
                      motivo={{ rotulo: "O que foi feito ou por que está certo", minimo: 5 }}
                      aoConfirmar={(m) => rpc("painel_multi_resolver", { p_id: a.id, p_nota: m })} aoConcluir={concluir} />
                  )}
                </Painel>
              </li>
            ))}
          </ul>
        )
      ) : aba === "vendas" ? (
        <div className="flex flex-col gap-6">
          {d.vendas.length === 0 ? <Vazio titulo="Nenhuma venda aprovada neste dia" /> : (
            <Painel className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead><tr className="border-b border-linha text-left text-suave">
                  <th className="p-3">Venda</th><th className="p-3">OS no ADM</th><th className="p-3">Plano</th>
                  <th className="p-3 text-right">Financiado (Multi)</th><th className="p-3 text-right">No ADM</th><th className="p-3">Situação</th>
                </tr></thead>
                <tbody>
                  {d.vendas.map((v) => (
                    <tr key={v.venda} className="border-b border-linha last:border-0">
                      <td className="p-3 tabular-nums">{v.venda}</td><td className="p-3">{v.os ?? "—"}</td><td className="p-3">{v.plano ?? "—"}</td>
                      <td className="p-3 text-right tabular-nums">{dinheiro(v.garantido)}</td><td className="p-3 text-right tabular-nums">{dinheiro(v.adm)}</td>
                      <td className="p-3"><Etiqueta tom={SITUACAO[v.situacao]?.tom}>{SITUACAO[v.situacao]?.rotulo ?? v.situacao}</Etiqueta></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Painel>
          )}
          {d.negadas.length > 0 && (
            <div>
              <h2 className="mb-2 font-bold">Consultas negadas e canceladas</h2>
              <ul className="flex flex-col gap-1 text-sm">
                {d.negadas.map((n) => (
                  <li key={`${n.tipo}-${n.venda}`} className="flex flex-wrap gap-2">
                    <Etiqueta tom={n.tipo === 2 ? "atencao" : "neutro"}>{n.tipo === 2 ? "Negada" : "Cancelada"}</Etiqueta>
                    <span className="tabular-nums">{n.venda}</span><span>{dinheiro(n.valor)}</span>{n.resposta && <span className="text-suave">· {n.resposta}</span>}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      ) : aba === "parcelas" ? (
        d.recebidas.length === 0 ? <Vazio titulo="Nenhuma parcela recebida neste dia" /> : (
          <Painel className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead><tr className="border-b border-linha text-left text-suave"><th className="p-3">Venda</th><th className="p-3">Parcela</th><th className="p-3 text-right">Recebido</th></tr></thead>
              <tbody>
                {d.recebidas.map((r) => (
                  <tr key={`${r.venda}-${r.parcela}`} className="border-b border-linha last:border-0">
                    <td className="p-3 tabular-nums">{r.venda}</td><td className="p-3">{r.parcela ?? "—"}</td><td className="p-3 text-right tabular-nums">{dinheiro(r.valor)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Painel>
        )
      ) : (
        d.resolvidos.length === 0 ? <Vazio titulo="Nada resolvido ainda" /> : (
          <ul className="flex flex-col gap-2">
            {d.resolvidos.map((r) => (
              <li key={r.id}>
                <Painel className="p-4">
                  <div className="mb-1 flex flex-wrap items-center gap-2">
                    <Etiqueta tom="ok">{TIPO[r.tipo]?.rotulo ?? r.tipo}</Etiqueta>
                    <span className="text-xs text-suave">resolvido {relativo(r.resolvido_em)}{r.resolvido_por?.startsWith("agente") ? " · fechou sozinho (corrigido)" : ""}</span>
                  </div>
                  <p className="text-suave">{r.descricao}</p>
                  {r.nota && <p className="mt-1 text-sm"><b>Nota:</b> {r.nota}</p>}
                </Painel>
              </li>
            ))}
          </ul>
        )
      )}
    </>
  );
}
