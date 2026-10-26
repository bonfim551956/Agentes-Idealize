import { Link, useParams } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, Ban, CheckCheck, RotateCcw } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type TarefaDetalhe as TD } from "../lib/api";
import { dataHora, dinheiro, nomeOperacao, PAPEL, rotuloUnidade, SEVERIDADE, STATUS_TAREFA } from "../lib/format";
import { Botao, Carregando, Dados, ErroCaixa, Etiqueta, Painel, Secao, cx } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";
import { Impressao } from "../ui/Impressao";
import { BotoesDecisao } from "../ui/Decisao";

function Info({ rotulo, children }: { rotulo: string; children: React.ReactNode }) {
  return (
    <div>
      <dt className="text-xs text-suave">{rotulo}</dt>
      <dd className="mt-1 break-words">{children}</dd>
    </div>
  );
}

const ACAO: Record<string, string> = {
  tarefa_criada: "Tarefa criada", tarefa_status: "Mudança de estado", aprovacao_aprovar: "Aprovada",
  aprovacao_rejeitar: "Rejeitada", reconciliacao: "Conferência humana", tarefa_cancelada: "Cancelada pelo painel",
};

export function TarefaDetalhe() {
  const { id = "" } = useParams();
  const { eu } = useSessao();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ["tarefa", id], queryFn: () => rpc<TD>("painel_tarefa", { p_id: id }) });
  const concluir = () => { void qc.invalidateQueries(); };

  const voltar = <Link to="/tarefas" className="mb-6 inline-flex items-center gap-2 text-sm font-bold text-lente hover:underline"><ArrowLeft className="h-4 w-4" aria-hidden />Todas as tarefas</Link>;
  if (q.isLoading) return <>{voltar}<Carregando linhas={6} /></>;
  if (q.error) return <>{voltar}<ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /></>;
  const d = q.data!;
  const t = d.tarefa;
  const st = STATUS_TAREFA[t.status];

  return (
    <>
      {voltar}
      <header className="mb-8 flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
        <div>
          <h1 className="text-2xl">{nomeOperacao(t.recurso, t.operacao)}</h1>
          <p className="mt-2 text-suave">{t.recurso}.{t.operacao}, agente {t.agente_id}, {rotuloUnidade(t.unidade_id, eu.unidades)}</p>
          <div className="mt-4 flex flex-wrap gap-2">
            <Etiqueta tom={st?.tom}>{st?.rotulo ?? t.status}</Etiqueta>
            {t.atrasada && <Etiqueta tom="atencao">Atrasada</Etiqueta>}
          </div>
          {t.motivo && <p className="mt-4 max-w-leitura text-sm">{t.motivo}</p>}
        </div>
        {t.valor != null && <p className="whitespace-nowrap text-2xl font-bold">{dinheiro(t.valor)}</p>}
      </header>

      {(d.pode.aprovar || d.pode.reconciliar || d.pode.cancelar) && (
        <Painel className="mb-12 flex flex-col gap-4 p-6">
          <h2 className="text-lg">O que você pode fazer</h2>
          {d.pode.aprovar && (
            <BotoesDecisao tarefa={t.id} hash={t.hash_operacao} aoConcluir={concluir}
              resumo={`${nomeOperacao(t.recurso, t.operacao)} em ${rotuloUnidade(t.unidade_id, eu.unidades)}${t.valor != null ? `, ${dinheiro(t.valor)}` : ""}.`} />
          )}
          {d.pode.reconciliar && (
            <div className="flex flex-col gap-2">
              <p className="text-sm text-suave">A execução foi interrompida depois de uma possível escrita fora daqui. Confira no sistema de destino antes de decidir.</p>
              <div className="flex flex-wrap gap-2">
                <Confirmar gatilho={<Botao variante="primario" icone={<CheckCheck className="h-4 w-4" aria-hidden />}>Aconteceu: mandar para validação</Botao>}
                  titulo="Confirmar que a operação aconteceu?" rotuloConfirmar="Confirmar que aconteceu"
                  descricao="A tarefa vai para o validador independente com a sua evidência. Ela não será executada de novo."
                  motivo={{ rotulo: "O que você conferiu", minimo: 5, ajuda: "Ex.: lançamento nº 123 existe no sistema, com o mesmo valor." }}
                  aoConfirmar={(ev) => rpc("painel_reconciliar", { p_tarefa: t.id, p_efetivada: true, p_evidencia: ev, p_motivo: "Conferido pelo painel: operação efetivada" })}
                  aoConcluir={concluir} />
                <Confirmar gatilho={<Botao icone={<RotateCcw className="h-4 w-4" aria-hidden />}>Não aconteceu: devolver à fila</Botao>}
                  titulo="Confirmar que a operação NÃO aconteceu?" rotuloConfirmar="Devolver à fila"
                  descricao="O agente vai executar de novo. Se a operação tiver acontecido, isso pode duplicar o efeito."
                  motivo={{ rotulo: "O que você conferiu", minimo: 5 }}
                  aoConfirmar={(ev) => rpc("painel_reconciliar", { p_tarefa: t.id, p_efetivada: false, p_evidencia: ev, p_motivo: "Conferido pelo painel: operação não efetivada" })}
                  aoConcluir={concluir} />
              </div>
            </div>
          )}
          {d.pode.cancelar && (
            <div>
              <Confirmar gatilho={<Botao variante="fantasma" icone={<Ban className="h-4 w-4" aria-hidden />}>Cancelar a tarefa</Botao>}
                titulo="Cancelar esta tarefa?" rotuloConfirmar="Cancelar tarefa" variante="perigo"
                descricao="O agente não executa mais. Não dá para desfazer; se precisar, o agente terá de pedir de novo."
                motivo={{ rotulo: "Motivo", minimo: 5 }}
                aoConfirmar={(m) => rpc("painel_cancelar_tarefa", { p_tarefa: t.id, p_motivo: m })} aoConcluir={concluir} />
            </div>
          )}
        </Painel>
      )}

      <Secao titulo="Dados da operação">
        <Painel className="p-6">
          <dl className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Info rotulo="Pedido por">{t.solicitante ?? "—"}</Info>
            <Info rotulo="Criada">{dataHora(t.criado_em)}</Info>
            <Info rotulo="Prazo">{dataHora(t.prazo)}</Info>
            <Info rotulo="Tentativas">{t.tentativas} de {t.max_tentativas}</Info>
            <Info rotulo="Prioridade">{t.prioridade === 1 ? "1 (crítica)" : t.prioridade}</Info>
            <Info rotulo="Risco">{t.risco}</Info>
            <Info rotulo="Autorização">{t.categoria === "automatica" ? "Automática pela matriz" : t.categoria === "aprovacao" ? "Exige aprovação" : "Proibida"}</Info>
            <Info rotulo="Código da operação"><Impressao hash={t.hash_operacao} /></Info>
          </dl>
          {d.politica && (
            <p className="mb-6 text-sm text-suave">
              Política nº {d.politica.id} (versão {d.politica.versao}){d.politica.papel_aprovador
                ? `: aprovação de ${PAPEL[d.politica.papel_aprovador] ?? d.politica.papel_aprovador}, mínimo ${d.politica.aprovadores_minimos}` : ""}
              {d.politica.limite_valor != null && `, automática até ${dinheiro(d.politica.limite_valor)}`}.
            </p>
          )}
          <h3 className="mb-2 font-bold">Conteúdo</h3>
          <div className="rounded-medio bg-elevada px-4 py-3 text-sm"><Dados valor={t.payload} /></div>
          {t.resultado != null && (<>
            <h3 className="mb-2 mt-6 font-bold">Resultado</h3>
            <div className="rounded-medio bg-elevada px-4 py-3 text-sm"><Dados valor={t.resultado} /></div>
          </>)}
        </Painel>
      </Secao>

      <div className="grid grid-cols-1 gap-x-8 lg:grid-cols-2">
        <Secao titulo="Execuções" descricao="Cada tentativa do agente.">
          {d.execucoes.length ? (
            <ol className="flex flex-col gap-2">
              {d.execucoes.map((e) => (
                <li key={e.tentativa} className="rounded-medio border border-linha bg-superficie px-4 py-3 text-sm">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-bold">Tentativa {e.tentativa}, {e.executor}</span>
                    <Etiqueta tom={e.status === "sucesso" ? "ok" : e.status === "em_andamento" ? "lente" : "critico"}>{e.status.replace("_", " ")}</Etiqueta>
                  </div>
                  <p className="mt-1 text-suave">{dataHora(e.inicio_em)}{e.fim_em && ` até ${dataHora(e.fim_em)}`}</p>
                  {e.erro && <p className="mt-1 text-critico">{e.erro}</p>}
                  {e.efeito_externo_id && <p className="mt-1">Comprovante externo: {e.efeito_externo_id}</p>}
                </li>
              ))}
            </ol>
          ) : <p className="text-sm text-suave">Ainda não executada.</p>}
        </Secao>

        <Secao titulo="Validação e aprovações" descricao="O validador é independente de quem executou.">
          <div className="flex flex-col gap-2 text-sm">
            {d.validacoes.map((v, i) => (
              <div key={i} className="rounded-medio border border-linha bg-superficie px-4 py-3">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-bold">Validador {v.validador}</span>
                  <Etiqueta tom={v.resultado === "aprovada" ? "ok" : "critico"}>{v.resultado === "aprovada" ? "Aprovou" : "Reprovou"}</Etiqueta>
                </div>
                <p className="mt-1 text-suave">{dataHora(v.em)}</p>
                {v.motivo && <p className="mt-1">{v.motivo}</p>}
              </div>
            ))}
            {d.aprovacoes.map((a, i) => (
              <div key={`a${i}`} className="rounded-medio border border-linha bg-superficie px-4 py-3">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-bold">{a.aprovador}, pelo {a.canal}</span>
                  <Etiqueta tom={a.decisao === "aprovar" ? (a.vale ? "ok" : "neutro") : "critico"}>
                    {a.decisao === "aprovar" ? (a.vale ? "Aprovou" : "Aprovação expirada") : "Rejeitou"}
                  </Etiqueta>
                </div>
                <p className="mt-1 text-suave">{dataHora(a.em)}</p>
                {a.comentario && <p className="mt-1">{a.comentario}</p>}
              </div>
            ))}
            {!d.validacoes.length && !d.aprovacoes.length && <p className="text-suave">Sem validações ou aprovações ainda.</p>}
            {d.incidentes.map((i) => (
              <Link key={i.id} to="/incidentes" className="rounded-medio border border-critico/40 bg-critico-fundo px-4 py-3 text-critico">
                Incidente {SEVERIDADE[i.severidade]?.rotulo.toLowerCase()}: {i.titulo} ({i.ocorrencias}×)
              </Link>
            ))}
          </div>
        </Secao>
      </div>

      <Secao titulo="Histórico" descricao="Registro auditado e encadeado: não pode ser alterado nem apagado.">
        <ol className="relative flex flex-col gap-4 border-l-2 border-linha pl-6">
          {d.historico.map((h) => (
            <li key={h.id} className="relative text-sm">
              <span aria-hidden className={cx("absolute -left-[33px] top-1 h-4 w-4 rounded-full border-2 border-superficie",
                h.acao.includes("rejeit") || h.acao.includes("cancel") ? "bg-critico" : h.acao.includes("aprov") ? "bg-ok" : "bg-lente")} />
              <p className="font-bold">{ACAO[h.acao] ?? h.acao}
                {h.acao === "tarefa_status" && (h.depois as { status?: string })?.status && `: ${STATUS_TAREFA[(h.depois as { status: string }).status]?.rotulo ?? ""}`}
              </p>
              <p className="text-suave">{dataHora(h.em)}{h.ator ? `, ${h.ator}` : ""}</p>
              {h.motivo && <p className="mt-1">{h.motivo}</p>}
            </li>
          ))}
        </ol>
      </Secao>
    </>
  );
}
