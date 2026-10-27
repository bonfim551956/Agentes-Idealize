import { useQuery } from "@tanstack/react-query";
import { CheckCircle2, MessageSquareText } from "lucide-react";
import { rpc, type SupervisorPainel } from "../lib/api";
import { dataHora, numero, relativo, type Tom } from "../lib/format";
import { Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, Vazio, cx, td, tdn, th } from "../ui/base";

const SEV: Record<string, { rotulo: string; tom: Tom }> = {
  critica: { rotulo: "Crítico", tom: "critico" }, alta: { rotulo: "Grave", tom: "critico" },
  media: { rotulo: "Atenção", tom: "atencao" }, baixa: { rotulo: "Baixo", tom: "neutro" }, info: { rotulo: "Informativo", tom: "neutro" },
};
const MSG: Record<string, { rotulo: string; tom: Tom }> = {
  sombra: { rotulo: "Não enviado (modo sombra)", tom: "neutro" }, pendente: { rotulo: "Enviando", tom: "lente" },
  enviada: { rotulo: "Enviado", tom: "ok" }, falhou: { rotulo: "Falhou", tom: "critico" }, bloqueada: { rotulo: "Segurado pelo conferente", tom: "atencao" },
};
const tempo = (min: number | null) => (min == null ? "—" : min >= 120 ? `${Math.round(min / 60)} h` : `${min} min`);

function Situacao({ a }: { a: SupervisorPainel["agentes"][number] }) {
  if (a.status !== "ativo" && !a.leitura_ligada) return <Etiqueta>Desligado</Etiqueta>;
  if (a.status === "ativo" !== a.leitura_ligada) return <Etiqueta tom="atencao">Ligado pela metade</Etiqueta>;
  if (a.atrasado) return <Etiqueta tom="critico">Atrasado</Etiqueta>;
  return <Etiqueta tom="ok">Em dia</Etiqueta>;
}

export function Supervisor() {
  const q = useQuery({ queryKey: ["supervisor"], queryFn: () => rpc<SupervisorPainel>("painel_supervisor"), refetchInterval: 120_000 });
  return (
    <>
      <Cabecalho titulo="Supervisor"
        descricao="Vigia todos os agentes: leituras no prazo, falhas, conferências reprovadas, incidentes, aprovações, custo, auditoria e conferência por amostragem direto na fonte. Não mexe em nenhum dado; só pode ligar o modo seguro." />
      {q.isLoading ? <Carregando linhas={5} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const r = q.data!;
        const ligado = r.config.ativo && r.config.agente === "ativo";
        return (
          <>
            <div role="status" className={cx("mb-8 rounded-grande border px-6 py-4 text-sm",
              ligado ? "border-linha bg-superficie" : "border-atencao/40 bg-atencao-fundo text-atencao")}>
              {ligado
                ? <>Verificando a cada hora. Última verificação {relativo(r.ultima?.em)}.</>
                : <span className="font-bold">Supervisor desligado{r.ultima ? `: última verificação ${relativo(r.ultima.em)}` : ": ainda não houve nenhuma verificação"}.</span>}
              <p className="mt-1">
                {r.config.enviar
                  ? `Avisos pelo WhatsApp para ${numero(r.config.destinos)} pessoa(s): urgente na hora e resumo às ${r.config.horarios.split(",").map((h) => `${h.trim()}h`).join(", ")}.`
                  : "Envio pelo WhatsApp desligado: os avisos ficam registrados aqui, sem sair."}
                {" "}Auditoria {r.ultima ? (r.ultima.auditoria_ok ? "íntegra" : "ADULTERADA") : "ainda não conferida"}.
                {r.config.modo_seguro && <span className="font-bold"> Modo seguro ligado.</span>}
              </p>
            </div>

            <Secao titulo="Problemas abertos" descricao="Somem sozinhos quando o problema se resolve.">
              {!r.achados.length ? (
                <Vazio titulo="Nada fora do lugar" icone={<CheckCircle2 className="h-6 w-6" />}>
                  {r.ultima ? "Tudo certo na última verificação." : "Os problemas aparecem depois da primeira verificação."}
                </Vazio>
              ) : (
                <ul className="flex flex-col gap-2">
                  {r.achados.map((a) => (
                    <li key={a.id}>
                      <Painel className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-start sm:justify-between">
                        <div className="min-w-0">
                          <Etiqueta tom={SEV[a.severidade]?.tom}>{SEV[a.severidade]?.rotulo ?? a.severidade}</Etiqueta>
                          <p className="mt-1 font-bold">{a.titulo}</p>
                        </div>
                        <div className="shrink-0 text-sm text-suave sm:text-right">
                          <p>Desde {relativo(a.aberto_em)}</p>
                          {a.notificado_em && <p>Avisado {relativo(a.notificado_em)}</p>}
                        </div>
                      </Painel>
                    </li>
                  ))}
                </ul>
              )}
            </Secao>

            <Secao titulo="Saúde dos agentes" descricao="Conferência na fonte: registros sorteados do espelho comparados com o sistema de origem; o que mudou depois da leitura não conta como erro.">
              <Tabela rotulo="Saúde dos agentes">
                <thead><tr><th className={th}>Agente</th><th className={th}>Situação</th><th className={th}>Última leitura</th><th className={th}>Prazo</th>
                  <th className={th}>Alertas</th><th className={th}>Falhas 24 h</th><th className={th}>Conferência na fonte</th></tr></thead>
                <tbody>{r.agentes.map((a) => (
                  <tr key={a.agente_id}>
                    <td className={td}><span className="font-bold">{a.nome}</span></td>
                    <td className={td}><Situacao a={a} /></td>
                    <td className={tdn}>{a.ultima_leitura ? relativo(a.ultima_leitura) : "nunca"}</td>
                    <td className={tdn}>{a.limite_min ? tempo(a.limite_min) : "—"}</td>
                    <td className={tdn}>{numero(a.alertas_abertos)}</td>
                    <td className={tdn}>{numero(a.problemas_24h)}</td>
                    <td className={td}>{!a.amostra ? "—" : a.amostra.conferidos === 0 ? "não foi possível ler" :
                      `${numero(a.amostra.iguais + a.amostra.mudaram_depois)} de ${numero(a.amostra.conferidos)} batem` +
                      (a.amostra.divergentes + a.amostra.nao_encontrados ? ` · ${numero(a.amostra.divergentes + a.amostra.nao_encontrados)} diferente(s)` : "")}</td>
                  </tr>
                ))}</tbody>
              </Tabela>
            </Secao>

            <Secao titulo="Avisos" descricao="O que foi (ou seria) mandado pelo WhatsApp. Só contagens e nomes de agentes e lojas; nunca dados de cliente.">
              <Painel className="mb-4 px-4 py-3">
                <p className="mb-2 text-xs text-suave">Prévia do próximo resumo</p>
                <pre className="whitespace-pre-wrap break-words font-sans text-sm">{r.previa}</pre>
              </Painel>
              {!r.mensagens.length ? <Vazio titulo="Nenhum aviso ainda" icone={<MessageSquareText className="h-6 w-6" />} /> : (
                <ul className="flex flex-col gap-2">
                  {r.mensagens.map((m) => (
                    <li key={m.id}>
                      <Painel className="px-4 py-3">
                        <div className="mb-1 flex flex-wrap items-center gap-2 text-sm">
                          <Etiqueta tom={m.tipo === "urgente" ? "critico" : "neutro"}>{m.tipo === "urgente" ? "Urgente" : "Resumo"}</Etiqueta>
                          <Etiqueta tom={MSG[m.status]?.tom}>{MSG[m.status]?.rotulo ?? m.status}</Etiqueta>
                          <span className="text-suave">{dataHora(m.criada_em)}</span>
                        </div>
                        <pre className="whitespace-pre-wrap break-words font-sans text-sm">{m.texto}</pre>
                        {m.erro && <p className="mt-1 text-sm text-critico">{m.erro}</p>}
                      </Painel>
                    </li>
                  ))}
                </ul>
              )}
            </Secao>

            {r.resolvidos.length > 0 && (
              <Secao titulo="Resolvidos recentemente">
                <Tabela rotulo="Problemas resolvidos recentemente">
                  <thead><tr><th className={th}>Problema</th><th className={th}>Gravidade</th><th className={th}>Aberto</th><th className={th}>Resolvido</th></tr></thead>
                  <tbody>{r.resolvidos.map((a) => (
                    <tr key={a.id}><td className={td}>{a.titulo}</td><td className={td}><Etiqueta tom={SEV[a.severidade]?.tom}>{SEV[a.severidade]?.rotulo ?? a.severidade}</Etiqueta></td>
                      <td className={tdn}>{dataHora(a.aberto_em)}</td><td className={tdn}>{dataHora(a.resolvido_em)}</td></tr>
                  ))}</tbody>
                </Tabela>
              </Secao>
            )}
          </>
        );
      })()}
    </>
  );
}
