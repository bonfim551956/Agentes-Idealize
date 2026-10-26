import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Pause, Play } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type Agente } from "../lib/api";
import { DEPARTAMENTO, dataHora, dolar, duracao, numero, percentual, relativo, STATUS_AGENTE } from "../lib/format";
import { Botao, Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, cx } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

function Medida({ rotulo, valor, aviso, semMedicao }: { rotulo: string; valor: string; aviso?: boolean; semMedicao?: boolean }) {
  return (
    <div className="flex flex-col gap-1">
      <dt className="text-xs text-suave">{rotulo}</dt>
      <dd className={cx("text-lg font-bold", aviso && "text-critico", semMedicao && "text-base font-normal text-suave")}>{valor}</dd>
    </div>
  );
}

export function Agentes() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [dias, setDias] = useState(30);
  const q = useQuery({ queryKey: ["agentes", dias], queryFn: () => rpc<Agente[]>("painel_agentes", { p_dias: dias }) });

  return (
    <>
      <Cabecalho titulo="Agentes" descricao="Estado, volume, qualidade e consumo de cada agente."
        acoes={
          <div role="group" aria-label="Período" className="flex rounded-medio border border-linha bg-superficie p-1">
            {[7, 30, 90].map((d) => (
              <button key={d} onClick={() => setDias(d)} aria-pressed={dias === d}
                className={cx("rounded-pequeno px-3 py-1 text-sm", dias === d ? "bg-lente-clara font-bold text-lente" : "hover:bg-elevada")}>{d} dias</button>
            ))}
          </div>
        } />
      {q.isLoading ? <Carregando /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (
        <div className="flex flex-col gap-4">
          {q.data!.map((a) => {
            const st = STATUS_AGENTE[a.status];
            return (
              <Painel key={a.id} className="p-6">
                <div className="mb-6 flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
                  <div className="max-w-leitura">
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="text-lg">{a.nome}</h2>
                      <Etiqueta tom={st?.tom}>{st?.rotulo ?? a.status}</Etiqueta>
                    </div>
                    <p className="mt-1 text-sm text-suave">{DEPARTAMENTO[a.departamento] ?? a.departamento}, versão {a.versao}, última atividade {relativo(a.ultima_atividade)}</p>
                    {a.descricao && <p className="mt-2 text-sm">{a.descricao}</p>}
                  </div>
                  {eu.pode.administrar && a.status !== "desativado" && (a.status === "ativo" ? (
                    <Confirmar gatilho={<Botao icone={<Pause className="h-4 w-4" aria-hidden />}>Pausar agente</Botao>}
                      titulo={`Pausar o ${a.nome}?`} rotuloConfirmar="Pausar" variante="perigo"
                      descricao="Ele para de pegar tarefas novas. As tarefas na fila esperam até ele ser ativado."
                      motivo={{ rotulo: "Motivo", minimo: 5 }}
                      aoConfirmar={(m) => rpc("painel_agente_status", { p_agente: a.id, p_status: "pausado", p_motivo: m })} aoConcluir={() => qc.invalidateQueries()} />
                  ) : (
                    <Confirmar gatilho={<Botao variante="primario" icone={<Play className="h-4 w-4" aria-hidden />}>Ativar agente</Botao>}
                      titulo={`Ativar o ${a.nome}?`} rotuloConfirmar="Ativar"
                      descricao="Ele começa a pegar da fila as tarefas autorizadas pela matriz. Canais externos (como o WhatsApp) têm chave própria e continuam como estão."
                      motivo={{ rotulo: "Motivo", minimo: 5 }}
                      aoConfirmar={(m) => rpc("painel_agente_status", { p_agente: a.id, p_status: "ativo", p_motivo: m })} aoConcluir={() => qc.invalidateQueries()} />
                  ))}
                </div>
                <dl className="grid grid-cols-2 gap-6 sm:grid-cols-3 lg:grid-cols-6">
                  <Medida rotulo="Concluídas (total)" valor={numero(a.tarefas.concluidas)} />
                  <Medida rotulo="Pendentes agora" valor={numero(a.tarefas.em_andamento + a.tarefas.aguardando_aprovacao)} />
                  <Medida rotulo="Bloqueadas ou incertas" valor={numero(a.tarefas.bloqueadas + a.tarefas.incertas)} aviso={a.tarefas.incertas > 0} />
                  <Medida rotulo="Falhas" valor={numero(a.tarefas.falhas)} aviso={a.tarefas.falhas > 0} />
                  <Medida rotulo="Atrasadas" valor={numero(a.tarefas.atrasadas)} aviso={a.tarefas.atrasadas > 0} />
                  <Medida rotulo="Incidentes abertos" valor={numero(a.incidentes_abertos)} aviso={a.incidentes_abertos > 0} />
                  <Medida rotulo={`Execuções (${dias} dias)`} valor={numero(a.execucoes)} />
                  <Medida rotulo="Tempo médio" valor={duracao(a.tempo_medio_s)} semMedicao={a.tempo_medio_s == null} />
                  <Medida rotulo="Taxa de sucesso" valor={percentual(a.taxa_sucesso)} semMedicao={a.taxa_sucesso == null} />
                  <Medida rotulo="Retrabalho" valor={percentual(a.taxa_retrabalho)} semMedicao={a.taxa_retrabalho == null} />
                  <Medida rotulo={`Aprovações pedidas (${dias} dias)`} valor={numero(a.aprovacoes_solicitadas)} />
                  {a.custo_mes && <Medida rotulo="Custo no mês" valor={dolar(a.custo_mes.confirmado + a.custo_mes.estimado)} />}
                  {a.tokens_mes && <Medida rotulo="Consumo de IA no mês" valor={`${numero(a.tokens_mes.entrada + a.tokens_mes.saida)} tokens`} />}
                  {a.limite_custo_mensal != null && <Medida rotulo="Limite mensal" valor={dolar(a.limite_custo_mensal)} />}
                  <Medida rotulo="Disponibilidade" valor="Sem medição ainda" semMedicao />
                  <Medida rotulo="Economia" valor="Sem medição ainda" semMedicao />
                </dl>
                <p className="mt-4 text-xs text-suave">Retrabalho: tarefas que precisaram de nova tentativa ou que o validador reprovou. Economia e disponibilidade só aparecem quando houver medição real; nada é estimado aqui. Atualizado {dataHora(new Date().toISOString())}.</p>
              </Painel>
            );
          })}
        </div>
      )}
    </>
  );
}
