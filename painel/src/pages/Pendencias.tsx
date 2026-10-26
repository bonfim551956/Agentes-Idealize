import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CheckCircle2 } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type Pendencia } from "../lib/api";
import { data, dinheiro, relativo, rotuloUnidade, TIPO_PENDENCIA } from "../lib/format";
import { Botao, Cabecalho, Carregando, Dados, ErroCaixa, Etiqueta, Painel, Vazio, entradaCls } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

export function Pendencias() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [unidade, setUnidade] = useState("");
  const [tipo, setTipo] = useState("");
  const q = useQuery({ queryKey: ["pendencias", unidade, tipo],
    queryFn: () => rpc<Pendencia[]>("painel_pendencias", { p_unidade: unidade || null, p_tipo: tipo || null }) });
  const concluir = () => { void qc.invalidateQueries(); };

  return (
    <>
      <Cabecalho titulo="Pendências financeiras"
        descricao="O que o agente financeiro não conseguiu fechar sozinho. As que bloqueiam o fechamento precisam ser resolvidas antes de aprovar o mês." />
      <div className="mb-6 grid grid-cols-1 gap-2 sm:grid-cols-2 lg:max-w-xl">
        <label className="sr-only" htmlFor="p-unidade">Unidade</label>
        <select id="p-unidade" className={entradaCls} value={unidade} onChange={(e) => setUnidade(e.target.value)}>
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
                      <p><span className="text-suave">Lançamento nº {p.lancamento.numero}:</span> {p.lancamento.natureza} de <b>{dinheiro(p.lancamento.valor)}</b>
                        {p.lancamento.descricao && `, ${p.lancamento.descricao}`}</p>
                    )}
                    {p.detalhe != null && Object.keys(p.detalhe as object).length > 0 && (
                      <details className="mt-1"><summary className="cursor-pointer text-lente">Detalhes</summary>
                        <div className="mt-2 rounded-medio bg-elevada px-3 py-2"><Dados valor={p.detalhe} /></div></details>
                    )}
                  </div>
                </div>
                <div className="flex shrink-0 flex-wrap gap-2">
                  {p.pode_tratar && (
                    <Confirmar gatilho={<Botao tamanho="sm" variante="primario">Marcar como resolvida</Botao>}
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
