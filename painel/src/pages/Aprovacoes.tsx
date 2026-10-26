import { Link } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ClipboardCheck } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type Aprovacao } from "../lib/api";
import { dinheiro, nomeOperacao, PAPEL, relativo, rotuloUnidade, dataHora } from "../lib/format";
import { Cabecalho, Carregando, Dados, ErroCaixa, Etiqueta, Painel, Vazio } from "../ui/base";
import { Impressao } from "../ui/Impressao";
import { BotoesDecisao } from "../ui/Decisao";

const RISCO = { baixo: "neutro", medio: "atencao", alto: "critico", critico: "critico" } as const;

export function Aprovacoes() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ["aprovacoes"], queryFn: () => rpc<Aprovacao[]>("painel_aprovacoes"), refetchInterval: 30_000 });
  const concluir = () => { void qc.invalidateQueries(); };

  return (
    <>
      <Cabecalho titulo="Aprovações"
        descricao="Operações que a matriz de permissões exige que uma pessoa autorize. Quem pediu nunca aprova a própria operação." />
      {q.isLoading ? <Carregando /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> :
        !q.data!.length ? (
          <Vazio titulo="Nenhuma operação aguardando aprovação" icone={<ClipboardCheck className="h-6 w-6" />}>
            Quando um agente pedir algo acima da alçada automática, aparece aqui com todos os dados para você decidir.
          </Vazio>
        ) : (
          <ul className="flex flex-col gap-4">
            {q.data!.map((a) => (
              <li key={a.id}>
                <Painel className="flex flex-col gap-4 p-6">
                  <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                    <div>
                      <h2 className="text-lg">{nomeOperacao(a.recurso, a.operacao)}</h2>
                      <p className="mt-1 text-sm text-suave">
                        {rotuloUnidade(a.unidade_id, eu.unidades)}, pedido {relativo(a.criado_em)} por {a.solicitante ?? a.agente_id}
                      </p>
                    </div>
                    <div className="flex flex-wrap items-center gap-2">
                      {a.valor != null && <span className="whitespace-nowrap text-xl font-bold">{dinheiro(a.valor)}</span>}
                      <Etiqueta tom={RISCO[a.risco as keyof typeof RISCO] ?? "neutro"}>Risco {a.risco}</Etiqueta>
                    </div>
                  </div>
                  {a.motivo && <p className="text-sm">{a.motivo}</p>}
                  <div className="rounded-medio bg-elevada px-4 py-3 text-sm"><Dados valor={a.payload} /></div>
                  <div className="flex flex-col gap-4 border-t border-linha pt-4 md:flex-row md:items-center md:justify-between">
                    <div className="flex flex-col gap-1 text-sm">
                      <Impressao hash={a.hash_operacao} grande />
                      <span className="text-suave">
                        {a.aprovacoes_validas} de {a.aprovadores_minimos ?? 1} aprovação(ões) necessária(s), alçada: {PAPEL[a.papel_aprovador ?? ""] ?? a.papel_aprovador}
                      </span>
                    </div>
                    <div className="flex flex-wrap items-center gap-2">
                      <Link to={`/tarefas/${a.id}`} className="px-2 text-sm font-bold text-lente hover:underline">Ver detalhes</Link>
                      {a.pode_aprovar ? (
                        <BotoesDecisao tarefa={a.id} hash={a.hash_operacao} aoConcluir={concluir}
                          resumo={`${nomeOperacao(a.recurso, a.operacao)} em ${rotuloUnidade(a.unidade_id, eu.unidades)}${a.valor != null ? `, ${dinheiro(a.valor)}` : ""}, pedido em ${dataHora(a.criado_em)}.`} />
                      ) : (
                        <span className="text-sm text-suave">Fora da sua alçada ou você já votou.</span>
                      )}
                    </div>
                  </div>
                </Painel>
              </li>
            ))}
          </ul>
        )}
    </>
  );
}
