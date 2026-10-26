import { Link } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CheckCircle2, ChevronRight, Pause, Play, ShieldAlert, ShieldCheck } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type Agente } from "../lib/api";
import { dataHora, numero, relativo, STATUS_AGENTE, SEVERIDADE, DEPARTAMENTO, dolar } from "../lib/format";
import { useResumo } from "../ui/Shell";
import { Botao, Carregando, ErroCaixa, Etiqueta, Secao, Tabela, cx, th, td } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

function LinhaDecisao({ para, titulo, detalhe, n, tom }: { para: string; titulo: string; detalhe: string; n: number; tom: "atencao" | "critico" | "lente" }) {
  return (
    <li>
      <Link to={para} className="group flex items-center gap-4 rounded-medio px-4 py-4 hover:bg-elevada">
        <span className={cx("flex h-12 w-12 shrink-0 items-center justify-center rounded-medio text-xl font-bold",
          tom === "critico" ? "bg-critico-fundo text-critico" : tom === "atencao" ? "bg-atencao-fundo text-atencao" : "bg-lente-clara text-lente")}>
          {n}
        </span>
        <span className="min-w-0 flex-1">
          <span className="block font-bold">{titulo}</span>
          <span className="block text-sm text-suave">{detalhe}</span>
        </span>
        <ChevronRight className="h-5 w-5 text-suave group-hover:text-tinta" aria-hidden />
      </Link>
    </li>
  );
}

export function VisaoGeral() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const resumo = useResumo();
  const agentes = useQuery({ queryKey: ["agentes", 30], queryFn: () => rpc<Agente[]>("painel_agentes", { p_dias: 30 }) });

  if (resumo.isLoading) return <Carregando linhas={6} rotulo="Carregando a visão geral" />;
  if (resumo.error) return <ErroCaixa erro={resumo.error} tentarDeNovo={() => resumo.refetch()} />;
  const r = resumo.data!;
  const incidentes = Object.entries(r.incidentes);
  const nIncid = incidentes.reduce((a, [, n]) => a + n, 0);
  const graves = (r.incidentes.critica ?? 0) + (r.incidentes.alta ?? 0);
  const incertas = r.tarefas.incerta ?? 0;
  const decisoes = [
    r.aprovacoes_pendentes > 0 && { para: "/aprovacoes", n: r.aprovacoes_pendentes, tom: "atencao" as const,
      titulo: r.aprovacoes_pendentes === 1 ? "Operação aguardando sua aprovação" : "Operações aguardando aprovação",
      detalhe: "Os agentes não executam até alguém com alçada decidir." },
    incertas > 0 && { para: "/tarefas?status=incerta", n: incertas, tom: "critico" as const,
      titulo: "Tarefas em estado incerto", detalhe: "A execução caiu no meio. Confira no sistema externo se aconteceu antes de liberar." },
    nIncid > 0 && { para: "/incidentes", n: nIncid, tom: graves > 0 ? "critico" as const : "atencao" as const,
      titulo: "Incidentes abertos",
      detalhe: incidentes.sort((a, b) => (SEVERIDADE[a[0]]?.ordem ?? 9) - (SEVERIDADE[b[0]]?.ordem ?? 9))
        .map(([s, n]) => `${n} ${SEVERIDADE[s]?.rotulo.toLowerCase() ?? s}`).join(", ") },
    r.pendencias_fin.abertas > 0 && { para: "/pendencias", n: r.pendencias_fin.abertas, tom: r.pendencias_fin.materiais > 0 ? "atencao" as const : "lente" as const,
      titulo: "Pendências financeiras",
      detalhe: r.pendencias_fin.materiais > 0 ? `${r.pendencias_fin.materiais} bloqueiam o fechamento do mês` : "Nenhuma bloqueia o fechamento" },
    r.atrasadas > 0 && { para: "/tarefas?atrasadas=1", n: r.atrasadas, tom: "atencao" as const,
      titulo: "Tarefas atrasadas", detalhe: "Passaram do prazo sem terminar." },
  ].filter(Boolean) as Parameters<typeof LinhaDecisao>[0][];

  const recarregar = () => { void qc.invalidateQueries(); };

  return (
    <>
      {/* Estado da plataforma: a primeira coisa que importa numa sala de controle */}
      <section aria-label="Estado da plataforma"
        className={cx("mb-12 flex flex-col gap-6 rounded-grande border px-6 py-6 md:flex-row md:items-center md:justify-between",
          r.plataforma_pausada ? "border-atencao/40 bg-atencao-fundo" : "border-linha bg-superficie")}>
        <div className="flex items-start gap-4">
          {r.plataforma_pausada
            ? <ShieldAlert className="mt-1 h-8 w-8 shrink-0 text-atencao" aria-hidden />
            : <ShieldCheck className="mt-1 h-8 w-8 shrink-0 text-ok" aria-hidden />}
          <div>
            <h1 className="text-2xl">{r.plataforma_pausada ? "Modo seguro ligado" : "Plataforma operando"}</h1>
            <p className="mt-2 max-w-leitura text-suave">
              {r.plataforma_pausada
                ? "Nenhum agente começa tarefa nova. Só o monitoramento continua."
                : "Os agentes ativos podem pegar tarefas autorizadas. Pausar a plataforma interrompe tudo de uma vez."}
            </p>
            <p className="mt-2 text-sm text-suave">
              Canal WhatsApp do financeiro: {r.canal_whatsapp.ativo ? "ligado" : "desligado"}
              {r.canal_whatsapp.ativo && (r.canal_whatsapp.responder ? ", respondendo no grupo" : ", em modo sombra (sem respostas)")}.
              {r.auditoria_integra != null && <> Histórico auditado: {r.auditoria_integra ? "íntegro" : "ADULTERAÇÃO DETECTADA"}.</>}
              {" "}Atualizado {relativo(r.gerado_em)}.
            </p>
          </div>
        </div>
        {r.plataforma_pausada ? (eu.pode.administrar && (
          <Confirmar
            gatilho={<Botao variante="primario" icone={<Play className="h-4 w-4" aria-hidden />}>Retomar a plataforma</Botao>}
            titulo="Retomar a plataforma?" rotuloConfirmar="Retomar"
            descricao="Os agentes ativos voltam a pegar tarefas da fila. Confira antes se o motivo da pausa foi resolvido."
            motivo={{ rotulo: "Por que retomar agora", minimo: 5 }}
            aoConfirmar={(m) => rpc("painel_plataforma_pausar", { p_pausar: false, p_motivo: m })} aoConcluir={recarregar} />
        )) : (eu.pode.pausar_plataforma && (
          <Confirmar
            gatilho={<Botao variante="perigo" icone={<Pause className="h-4 w-4" aria-hidden />}>Pausar a plataforma</Botao>}
            titulo="Ligar o modo seguro?" rotuloConfirmar="Pausar agora" variante="perigo"
            descricao="Nenhum agente começa tarefa nova até um administrador retomar. Tarefas que já estão executando terminam a tentativa atual."
            motivo={{ rotulo: "O que aconteceu", minimo: 5, ajuda: "Fica registrado no histórico auditado." }}
            aoConfirmar={(m) => rpc("painel_plataforma_pausar", { p_pausar: true, p_motivo: m })} aoConcluir={recarregar} />
        ))}
      </section>

      <Secao titulo="Precisa de você" descricao="Decisões e conferências que só uma pessoa pode fazer.">
        {decisoes.length ? (
          <ul className="flex flex-col divide-y divide-linha rounded-grande border border-linha bg-superficie">
            {decisoes.map((d) => <LinhaDecisao key={d.para} {...d} />)}
          </ul>
        ) : (
          <div className="flex items-center gap-3 rounded-grande border border-linha bg-superficie px-6 py-6">
            <CheckCircle2 className="h-6 w-6 text-ok" aria-hidden />
            <p><span className="font-bold">Nada esperando decisão agora.</span> <span className="text-suave">Aprovações, incidentes e pendências aparecem aqui assim que surgirem.</span></p>
          </div>
        )}
      </Secao>

      <Secao titulo="Agentes" descricao={`Últimos 30 dias. ${numero(r.tarefas_24h)} tarefas criadas nas últimas 24 horas.`}
        acoes={<Link to="/agentes" className="text-sm font-bold text-lente hover:underline">Ver métricas completas</Link>}>
        {agentes.isLoading ? <Carregando linhas={2} /> : agentes.error ? <ErroCaixa erro={agentes.error} tentarDeNovo={() => agentes.refetch()} /> : (
          <Tabela rotulo="Agentes">
            <thead><tr>
              <th className={th}>Agente</th><th className={th}>Estado</th><th className={th}>Última atividade</th>
              <th className={th}>Em andamento</th><th className={th}>Concluídas</th><th className={th}>Problemas</th>
              {eu.pode.consultar_global && <th className={th}>Custo no mês</th>}
            </tr></thead>
            <tbody>
              {agentes.data!.map((a) => {
                const problemas = a.tarefas.falhas + a.tarefas.incertas + a.tarefas.bloqueadas + a.incidentes_abertos;
                return (
                  <tr key={a.id}>
                    <td className={td}><span className="font-bold">{a.nome}</span><span className="block text-xs text-suave">{DEPARTAMENTO[a.departamento] ?? a.departamento}, versão {a.versao}</span></td>
                    <td className={td}><Etiqueta tom={STATUS_AGENTE[a.status]?.tom}>{STATUS_AGENTE[a.status]?.rotulo ?? a.status}</Etiqueta></td>
                    <td className={td} title={dataHora(a.ultima_atividade)}>{relativo(a.ultima_atividade)}</td>
                    <td className={td}>{numero(a.tarefas.em_andamento + a.tarefas.aguardando_aprovacao)}</td>
                    <td className={td}>{numero(a.tarefas.concluidas)}</td>
                    <td className={cx(td, problemas > 0 && "font-bold text-critico")}>{numero(problemas)}</td>
                    {eu.pode.consultar_global && <td className={td}>{a.custo_mes ? dolar(a.custo_mes.confirmado + a.custo_mes.estimado) : "—"}</td>}
                  </tr>
                );
              })}
            </tbody>
          </Tabela>
        )}
      </Secao>
    </>
  );
}
