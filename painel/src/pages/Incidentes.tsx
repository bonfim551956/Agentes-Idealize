import { useState } from "react";
import { Link } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ShieldCheck } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type Incidente } from "../lib/api";
import { dataHora, relativo, rotuloUnidade, SEVERIDADE } from "../lib/format";
import { Botao, Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Vazio, cx } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

export function Incidentes() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [abertos, setAbertos] = useState(true);
  const q = useQuery({ queryKey: ["incidentes", abertos], queryFn: () => rpc<Incidente[]>("painel_incidentes", { p_abertos: abertos }), refetchInterval: 30_000 });
  const concluir = () => { void qc.invalidateQueries(); };

  return (
    <>
      <Cabecalho titulo="Incidentes"
        descricao="Falhas repetidas são agrupadas num só incidente; o contador e a gravidade sobem a cada nova ocorrência."
        acoes={
          <div role="group" aria-label="Quais incidentes" className="flex rounded-medio border border-linha bg-superficie p-1">
            {[true, false].map((v) => (
              <button key={String(v)} onClick={() => setAbertos(v)} aria-pressed={abertos === v}
                className={cx("rounded-pequeno px-3 py-1 text-sm", abertos === v ? "bg-lente-clara font-bold text-lente" : "hover:bg-elevada")}>
                {v ? "Abertos" : "Todos"}
              </button>
            ))}
          </div>
        } />
      {q.isLoading ? <Carregando /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !q.data!.length ? (
        <Vazio titulo={abertos ? "Nenhum incidente aberto" : "Nenhum incidente registrado"} icone={<ShieldCheck className="h-6 w-6" />}>
          Incidentes nascem de tarefas incertas, falhas repetidas, integrações fora do ar e custos perto do limite.
        </Vazio>
      ) : (
        <ul className="flex flex-col gap-2">
          {q.data!.map((i) => {
            const s = SEVERIDADE[i.severidade];
            return (
              <li key={i.id}>
                <Painel className={cx("flex flex-col gap-4 p-4 md:flex-row md:items-start md:justify-between",
                  i.status !== "resolvido" && (s?.tom === "critico") && "border-l-4 border-l-critico")}>
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <Etiqueta tom={s?.tom}>{s?.rotulo ?? i.severidade}</Etiqueta>
                      {i.escalonado && <Etiqueta tom="critico">Gravidade aumentou</Etiqueta>}
                      <Etiqueta tom={i.status === "resolvido" ? "ok" : i.status === "em_tratamento" ? "lente" : "neutro"}>
                        {i.status === "resolvido" ? "Resolvido" : i.status === "em_tratamento" ? "Em tratamento" : "Aberto"}
                      </Etiqueta>
                    </div>
                    <h2 className="mt-2 text-base font-bold">{i.titulo}</h2>
                    <p className="mt-1 text-sm text-suave">
                      {i.ocorrencias} {i.ocorrencias === 1 ? "ocorrência" : "ocorrências"}, a primeira {relativo(i.primeira_em)} e a última {relativo(i.ultima_em)}
                      {i.agente_id && `, agente ${i.agente_id}`}{i.unidade_id && `, ${rotuloUnidade(i.unidade_id, eu.unidades)}`}.
                    </p>
                    {i.resolvido_em && <p className="mt-1 text-sm text-suave">Resolvido em {dataHora(i.resolvido_em)}.</p>}
                    {i.tarefa_id && <Link to={`/tarefas/${i.tarefa_id}`} className="mt-2 inline-block text-sm font-bold text-lente hover:underline">Abrir a tarefa ligada</Link>}
                  </div>
                  {i.pode_tratar && (
                    <div className="flex shrink-0 flex-wrap gap-2">
                      {i.status === "aberto" && (
                        <Confirmar gatilho={<Botao tamanho="sm">Assumir</Botao>} titulo="Assumir o incidente?" rotuloConfirmar="Assumir"
                          descricao="Marca o incidente como em tratamento, para os outros saberem que alguém está cuidando."
                          motivo={{ rotulo: "O que você vai fazer", minimo: 3 }}
                          aoConfirmar={(m) => rpc("painel_incidente_tratar", { p_incidente: i.id, p_status: "em_tratamento", p_nota: m })} aoConcluir={concluir} />
                      )}
                      <Confirmar gatilho={<Botao tamanho="sm" variante="primario">Resolver</Botao>} titulo="Marcar como resolvido?" rotuloConfirmar="Marcar como resolvido"
                        descricao="Se o problema voltar a acontecer, um novo incidente é aberto."
                        motivo={{ rotulo: "Como foi resolvido", minimo: 10 }}
                        aoConfirmar={(m) => rpc("painel_incidente_tratar", { p_incidente: i.id, p_status: "resolvido", p_nota: m })} aoConcluir={concluir} />
                    </div>
                  )}
                </Painel>
              </li>
            );
          })}
        </ul>
      )}
    </>
  );
}
