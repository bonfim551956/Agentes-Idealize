import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CheckCircle2 } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type Pendencia } from "../lib/api";
import { data, dinheiro, relativo, rotuloUnidade, TIPO_PENDENCIA } from "../lib/format";
import { Botao, Cabecalho, Carregando, Dados, ErroCaixa, Etiqueta, Painel, Vazio, entradaCls } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";
import { traduzir } from "../lib/erros";
import { useFiltroLoja } from "../lib/loja";

type Categoria = { id: string; nome: string; grupo: string };

// Sem categoria: a escolha já corrige o lançamento; "usar sempre" vira regra para o fornecedor (pedido 07/11)
function EscolherCategoria({ p, categorias, aoConcluir }: { p: Pendencia; categorias: Categoria[]; aoConcluir: () => void }) {
  const [cat, setCat] = useState("");
  const [lembrar, setLembrar] = useState(true);
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const fornecedor = p.lancamento?.fornecedor ?? p.lancamento?.descricao ?? "";
  const grupos = [...new Set(categorias.map((c) => c.grupo))];
  async function salvar() {
    setEnviando(true); setErro(null);
    try {
      await rpc("painel_pendencia_decidir", { p_pendencia: p.id, p_decisao: "categoria", p_categoria: cat, p_lembrar: lembrar });
      aoConcluir();
    } catch (e) { setErro(traduzir(e).message); } finally { setEnviando(false); }
  }
  return (
    <div className="mt-3 flex flex-col gap-2">
      <p className="text-sm font-bold">Em que categoria entra?</p>
      <div className="flex flex-col gap-2 md:flex-row md:items-center">
        <label className="sr-only" htmlFor={`cat-${p.id}`}>Categoria</label>
        <select id={`cat-${p.id}`} className={entradaCls + " md:max-w-xs"} value={cat} onChange={(e) => setCat(e.target.value)}>
          <option value="">Escolha a categoria…</option>
          {grupos.map((g) => (
            <optgroup key={g} label={g}>{categorias.filter((c) => c.grupo === g).map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}</optgroup>
          ))}
        </select>
        {fornecedor && (
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" className="h-4 w-4" checked={lembrar} onChange={(e) => setLembrar(e.target.checked)} />
            Usar sempre para “{fornecedor}”
          </label>
        )}
        <Botao variante="primario" tamanho="sm" disabled={!cat} carregando={enviando} onClick={salvar}>Salvar categoria</Botao>
      </div>
      {erro && <p role="alert" className="text-sm font-bold text-critico">{erro}</p>}
    </div>
  );
}

// Possível cobrança em dobro: mostra os parecidos lado a lado e a decisão corrige na hora
function DecidirDuplicidade({ p, aoConcluir }: { p: Pendencia; aoConcluir: () => void }) {
  const lista = p.parecidos ?? [];
  const numero = p.lancamento?.numero;
  return (
    <div className="mt-3 flex flex-col gap-2">
      <div className="overflow-x-auto">
        <table className="min-w-full text-sm">
          <thead><tr className="text-left text-suave"><th className="py-1 pr-4">Nº</th><th className="py-1 pr-4">Data</th><th className="py-1 pr-4">Fornecedor</th><th className="py-1 pr-4">Valor</th><th className="py-1">Categoria</th></tr></thead>
          <tbody>{lista.map((x) => (
            <tr key={x.numero} className={x.este ? "font-bold" : ""}>
              <td className="border-t border-linha py-1 pr-4">{x.numero}{x.este && " (esta)"}</td>
              <td className="border-t border-linha py-1 pr-4">{data(x.data)}</td>
              <td className="border-t border-linha py-1 pr-4">{x.fornecedor}</td>
              <td className="border-t border-linha py-1 pr-4">{dinheiro(x.valor)}</td>
              <td className="border-t border-linha py-1">{x.categoria ?? "—"}</td>
            </tr>
          ))}</tbody>
        </table>
      </div>
      <p className="text-sm font-bold">Essas cobranças são diferentes ou repetidas?</p>
      <div className="flex flex-wrap gap-2">
        <Confirmar gatilho={<Botao variante="primario" tamanho="sm">São cobranças diferentes (manter {lista.length > 1 ? `as ${lista.length}` : "todas"})</Botao>}
          titulo="Manter todas as cobranças?" rotuloConfirmar="Manter todas"
          descricao="Os lançamentos continuam como estão e as pendências desse grupo são encerradas, com o seu nome no histórico."
          aoConfirmar={() => rpc("painel_pendencia_decidir", { p_pendencia: p.id, p_decisao: "diferentes" })} aoConcluir={aoConcluir} />
        <Confirmar gatilho={<Botao tamanho="sm">É repetida: cancelar a nº {numero}</Botao>} variante="perigo"
          titulo={`Cancelar o lançamento nº ${numero}?`} rotuloConfirmar="Cancelar o lançamento"
          descricao={`O lançamento nº ${numero} (${dinheiro(p.lancamento?.valor ?? 0)}) é cancelado e sai da fatura e da DRE. Fica registrado com o seu nome.`}
          aoConfirmar={() => rpc("painel_pendencia_decidir", { p_pendencia: p.id, p_decisao: "repetida" })} aoConcluir={aoConcluir} />
      </div>
    </div>
  );
}

// tipos em que a decisão é tomada dentro do card
const decideAqui = (p: Pendencia) => Boolean(p.lancamento) && (p.tipo === "sem_classificacao" || (p.tipo === "duplicidade_suspeita" && (p.parecidos?.length ?? 0) > 0));

export function Pendencias() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [unidade, setUnidade, travada] = useFiltroLoja();
  const [tipo, setTipo] = useState("");
  const q = useQuery({ queryKey: ["pendencias", unidade, tipo],
    queryFn: () => rpc<Pendencia[]>("painel_pendencias", { p_unidade: unidade || null, p_tipo: tipo || null }) });
  const concluir = () => { void qc.invalidateQueries(); };
  const cats = useQuery({ queryKey: ["categorias", "despesa"], queryFn: () => rpc<Categoria[]>("painel_categorias", { p_natureza: "despesa" }),
    enabled: eu.pode.tratar_pendencia });

  return (
    <>
      <Cabecalho titulo="Pendências financeiras"
        descricao="O que o agente financeiro não conseguiu fechar sozinho e o que você precisa decidir. A decisão no card já corrige o lançamento. As que bloqueiam o fechamento precisam ser resolvidas antes de aprovar o mês." />
      <div className="mb-6 grid grid-cols-1 gap-2 sm:grid-cols-2 lg:max-w-xl">
        <label className="sr-only" htmlFor="p-unidade">Unidade</label>
        <select id="p-unidade" className={entradaCls} value={unidade} disabled={travada} title={travada ? "Loja travada no topo da página" : undefined} onChange={(e) => setUnidade(e.target.value)}>
          <option value="">Todas as unidades</option>
          {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
        </select>
        <label className="sr-only" htmlFor="p-tipo">Tipo</label>
        <select id="p-tipo" className={entradaCls} value={tipo} onChange={(e) => setTipo(e.target.value)}>
          <option value="">Todos os tipos</option>
          {Object.entries(TIPO_PENDENCIA).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
      </div>
      {q.isLoading ? <Carregando /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !q.data!.length ? (
        <Vazio titulo="Nenhuma pendência aberta com esses filtros" icone={<CheckCircle2 className="h-6 w-6" />}>
          Quando um movimento do extrato não encontrar lançamento, ou um comprovante não bater, ele aparece aqui.
        </Vazio>
      ) : (
        <ul className="flex flex-col gap-2">
          {q.data!.map((p) => (
            <li key={p.id}>
              <Painel className="flex flex-col gap-4 p-4 lg:flex-row lg:items-start lg:justify-between">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <h2 className="text-base font-bold">{TIPO_PENDENCIA[p.tipo] ?? p.tipo}</h2>
                    {p.material ? <Etiqueta tom="atencao">Bloqueia o fechamento</Etiqueta> : <Etiqueta>Não bloqueia</Etiqueta>}
                  </div>
                  <p className="mt-1 text-sm text-suave">{rotuloUnidade(p.unidade_id, eu.unidades)}, aberta {relativo(p.criado_em)}</p>
                  <div className="mt-2 flex flex-col gap-1 text-sm">
                    {p.movimento && (
                      <p><span className="text-suave">Extrato {data(p.movimento.data)}:</span> {p.movimento.sentido === "credito" ? "entrada" : "saída"} de <b>{dinheiro(p.movimento.valor)}</b>, {p.movimento.descricao}</p>
                    )}
                    {p.lancamento && (
                      <p><span className="text-suave">Lançamento nº {p.lancamento.numero}{p.lancamento.conta && ` · ${p.lancamento.conta}`} · {data(p.lancamento.data_competencia)}:</span>{" "}
                        <b>{dinheiro(p.lancamento.valor)}</b>{p.lancamento.descricao && ` · ${p.lancamento.descricao}`}</p>
                    )}
                    {p.fatura && (
                      <p className="rounded-medio bg-elevada px-3 py-2">
                        Fatura com vencimento em {data(p.fatura.vencimento)}: <b>{dinheiro(p.fatura.soma_compras)}</b> em {p.fatura.compras} compras
                        {p.fatura.pago != null && <> × <b>{dinheiro(p.fatura.pago)}</b> pagos (diferença de {dinheiro(Math.abs(p.fatura.pago - p.fatura.soma_compras))})</>}.
                        {" "}Envie a fatura em PDF em “Enviar arquivos”: as compras entram e a pendência fecha sozinha quando bater.
                      </p>
                    )}
                    {p.pode_tratar && p.tipo === "sem_classificacao" && p.lancamento && cats.data && (
                      <EscolherCategoria p={p} categorias={cats.data} aoConcluir={concluir} />
                    )}
                    {p.pode_tratar && p.tipo === "duplicidade_suspeita" && p.lancamento && (p.parecidos?.length ?? 0) > 0 && (
                      <DecidirDuplicidade p={p} aoConcluir={concluir} />
                    )}
                    {p.detalhe != null && Object.keys(p.detalhe as object).length > 0 && (
                      <details className="mt-1"><summary className="cursor-pointer text-lente">Detalhes</summary>
                        <div className="mt-2 rounded-medio bg-elevada px-3 py-2"><Dados valor={p.detalhe} /></div></details>
                    )}
                  </div>
                </div>
                <div className="flex shrink-0 flex-wrap gap-2">
                  {p.pode_tratar && (
                    <Confirmar gatilho={<Botao tamanho="sm" variante={decideAqui(p) ? "secundario" : "primario"}>{decideAqui(p) ? "Já corrigi de outro jeito" : "Marcar como resolvida"}</Botao>}
                      titulo="Marcar a pendência como resolvida?" rotuloConfirmar="Marcar como resolvida"
                      descricao="Use quando o problema já foi corrigido (lançamento ajustado, comprovante encontrado). Fica registrado com o seu nome."
                      motivo={{ rotulo: "O que foi feito", minimo: 10 }}
                      aoConfirmar={(m) => rpc("painel_pendencia_tratar", { p_pendencia: p.id, p_acao: "resolver", p_texto: m })} aoConcluir={concluir} />
                  )}
                  {p.pode_aceitar && (
                    <Confirmar gatilho={<Botao tamanho="sm">Aceitar sem corrigir</Botao>}
                      titulo="Aceitar a pendência sem corrigir?" rotuloConfirmar="Aceitar" variante={p.material ? "perigo" : "primario"}
                      descricao={p.material
                        ? "Esta pendência bloqueia o fechamento. Aceitar significa assumir a diferença no mês, com a sua justificativa no histórico."
                        : "A diferença fica registrada como aceita, com a sua justificativa."}
                      motivo={{ rotulo: "Justificativa", minimo: 10 }}
                      aoConfirmar={(m) => rpc("painel_pendencia_tratar", { p_pendencia: p.id, p_acao: "aceitar", p_texto: m })} aoConcluir={concluir} />
                  )}
                </div>
              </Painel>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
