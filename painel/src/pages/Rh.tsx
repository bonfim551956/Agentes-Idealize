import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { CheckCircle2, Printer, UsersRound } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type RhPainel } from "../lib/api";
import { data, numero, relativo, rotuloUnidade, type Tom } from "../lib/format";
import { Botao, Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, Vazio, cx, entradaCls, td, tdn, th } from "../ui/base";

const ALERTA: Record<string, { rotulo: string; tom: Tom }> = {
  ferias_vencidas: { rotulo: "Férias fora do prazo", tom: "critico" },
  experiencia_vencida: { rotulo: "Experiência passou do prazo", tom: "critico" },
  desligamento_prazo: { rotulo: "Prazo do acerto", tom: "critico" },
  nova_admissao: { rotulo: "Nova admissão", tom: "lente" },
  fim_experiencia: { rotulo: "Fim de período de experiência", tom: "atencao" },
  exame_vencendo: { rotulo: "Exame ocupacional vencendo", tom: "atencao" },
  ferias_limite: { rotulo: "Férias perto do limite", tom: "atencao" },
  tarefa_atrasada: { rotulo: "Tarefa do RH atrasada", tom: "atencao" },
  jornada_irregular: { rotulo: "Jornada ou escala a corrigir", tom: "neutro" },
  uniforme_baixo: { rotulo: "Uniforme abaixo do mínimo", tom: "neutro" },
  aniversario: { rotulo: "Aniversário", tom: "ok" },
};
const s = (v: unknown) => String(v ?? "");

function texto(a: RhPainel["alertas"][number]): { titulo: string; detalhe: string } {
  const d = a.detalhe ?? {};
  switch (a.tipo) {
    case "fim_experiencia": return { titulo: s(d.nome), detalhe: d.periodo === 1
      ? `Primeiro período (${s(d.marco_dias)} dias) termina em ${data(s(d.termina))}. Decida se prorroga ou encerra.`
      : `Prorrogação termina em ${data(s(d.termina))} (${s(d.marco_dias)} dias de experiência). Decida se efetiva ou encerra.` };
    case "experiencia_vencida": return { titulo: s(d.nome), detalhe: `A experiência${d.total_dias ? ` de ${s(d.total_dias)} dias` : ""} terminou em ${data(s(d.terminou))} e o cadastro ainda está como experiência. Atualize o contrato no RH 360.` };
    case "ferias_vencidas": return d.dias_fora_do_prazo
      ? { titulo: s(d.nome), detalhe: `${s(d.dias_fora_do_prazo)} dias de férias do período ${data(s(d.aquisitivo_inicio))} a ${data(s(d.aquisitivo_fim))} foram tirados depois do limite (${data(s(d.limite))}). Confira com a contabilidade se houve pagamento em dobro.` }
      : { titulo: s(d.nome), detalhe: `Período ${data(s(d.aquisitivo_inicio))} a ${data(s(d.aquisitivo_fim))}: faltam ${s(d.dias_faltando)} dias e o limite era ${data(s(d.limite))}. Risco de pagamento em dobro.` };
    case "ferias_limite": return { titulo: s(d.nome), detalhe: `Período ${data(s(d.aquisitivo_inicio))} a ${data(s(d.aquisitivo_fim))}: faltam ${s(d.dias_faltando)} dias de férias; o limite para conceder é ${data(s(d.limite))}.` };
    case "exame_vencendo": return { titulo: s(d.nome), detalhe: `Exame ocupacional ${d.vencido ? "venceu" : "vence"} em ${data(s(d.vencimento))}.` };
    case "desligamento_prazo": return { titulo: s(d.nome), detalhe: `Desligamento em ${data(s(d.desligamento))}; o acerto precisa estar pago até ${data(s(d.prazo_acerto))}.` };
    case "tarefa_atrasada": return { titulo: s(d.titulo), detalhe: `Prazo era ${data(s(d.prazo))}.` };
    case "jornada_irregular": return { titulo: s(d.nome), detalhe: d.motivo === "acima" ? `Jornada cadastrada de ${s(d.jornada)} horas semanais, acima de 44.` : d.motivo === "sem_jornada" ? "Sem jornada semanal cadastrada." : "Sem escala de horário cadastrada." };
    case "nova_admissao": return { titulo: s(d.nome), detalhe: d.pre_admissao
      ? `Em pré-admissão${d.admissao ? `, começa em ${data(s(d.admissao))}` : ""}. Confira documentos, exame admissional e o envio à contabilidade.`
      : `${s(d.cargo) || "Admissão"} em ${data(s(d.admissao))}. Confira documentos, exame admissional e o envio à contabilidade.` };
    case "aniversario": return { titulo: s(d.nome), detalhe: d.hoje ? `Faz aniversário hoje (${s(d.dia)}).` : `Faz aniversário em ${s(d.dia)}.` };
    case "uniforme_baixo": return { titulo: `${s(d.peca)} ${s(d.tamanho)}`, detalhe: `${s(d.saldo)} em estoque; mínimo de ${s(d.minimo)}.` };
    default: return { titulo: a.referencia, detalhe: "" };
  }
}

export function Rh() {
  const { eu } = useSessao();
  const [unidade, setUnidade] = useState("");
  const [tipo, setTipo] = useState("");
  const [mes, setMes] = useState(() => new Date().toISOString().slice(0, 7));
  const q = useQuery({ queryKey: ["rh", unidade, mes],
    queryFn: () => rpc<RhPainel>("painel_rh", { p_unidade: unidade || null, p_mes: `${mes}-01` }), refetchInterval: 600_000 });

  return (
    <>
      <Cabecalho titulo="RH"
        descricao="Prazos das pessoas das lojas, quadro por loja e a lista do mês para a contabilidade. O agente só avisa: decisões sobre pessoas, folha e rescisão ficam com você e a contabilidade." />
      {q.isLoading ? <Carregando linhas={5} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const r = q.data!;
        const ligado = r.sincronizacao.ativa && r.sincronizacao.agente === "ativo";
        const alertas = r.alertas.filter((a) => !tipo || a.tipo === tipo);
        const c = r.contabilidade;
        const vazio = !c.admissoes.length && !c.desligamentos.length && !c.ferias.length && !c.mudancas.length;
        return (
          <>
            <div role="status" className={cx("mb-8 rounded-grande border px-6 py-4 text-sm",
              ligado ? "border-linha bg-superficie" : "border-atencao/40 bg-atencao-fundo text-atencao")}>
              {ligado
                ? <>Lendo o RH 360 todo dia de manhã. Última leitura {relativo(r.sincronizacao.ultima?.em)}.</>
                : <span className="font-bold">Agente desligado: os números abaixo são da última leitura{r.sincronizacao.ultima ? ` (${relativo(r.sincronizacao.ultima.em)})` : ", e ainda não houve nenhuma"}.</span>}
              <p className="mt-1">Prazos pela regra geral da CLT; convenção coletiva e casos especiais, confirme com a contabilidade.</p>
            </div>

            <div className="mb-6 grid grid-cols-1 gap-2 sm:grid-cols-3 lg:max-w-3xl">
              <label className="sr-only" htmlFor="rh-un">Loja</label>
              <select id="rh-un" className={entradaCls} value={unidade} onChange={(e) => setUnidade(e.target.value)}>
                <option value="">Todas as lojas</option>
                {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
              </select>
              <label className="sr-only" htmlFor="rh-tipo">Tipo de aviso</label>
              <select id="rh-tipo" className={entradaCls} value={tipo} onChange={(e) => setTipo(e.target.value)}>
                <option value="">Todos os avisos</option>
                {Object.entries(ALERTA).map(([k, v]) => <option key={k} value={k}>{v.rotulo}</option>)}
              </select>
              <label className="sr-only" htmlFor="rh-mes">Mês da lista para a contabilidade</label>
              <input id="rh-mes" type="month" className={entradaCls} value={mes} onChange={(e) => e.target.value && setMes(e.target.value)} />
            </div>

            <Secao titulo="Prazos e avisos" descricao="Somem sozinhos quando o RH 360 é atualizado.">
              {!alertas.length ? (
                <Vazio titulo="Nenhum prazo apertado" icone={<CheckCircle2 className="h-6 w-6" />}>
                  {r.sincronizacao.ultima ? "Tudo em dia na última leitura." : "Os avisos aparecem depois da primeira leitura do RH 360."}
                </Vazio>
              ) : (
                <ul className="flex flex-col gap-2">
                  {alertas.map((a) => {
                    const t = texto(a);
                    return (
                      <li key={a.id}>
                        <Painel className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-start sm:justify-between">
                          <div className="min-w-0">
                            <Etiqueta tom={ALERTA[a.tipo]?.tom}>{ALERTA[a.tipo]?.rotulo ?? a.tipo}</Etiqueta>
                            <p className="mt-1 font-bold">{t.titulo}</p>
                            <p className="text-sm text-suave">{t.detalhe}</p>
                          </div>
                          <div className="shrink-0 text-sm text-suave sm:text-right">
                            <p>{a.unidade_id ? rotuloUnidade(a.unidade_id, eu.unidades) : "Estoque central"}</p>
                            {a.prazo && <p>{data(a.prazo)}</p>}
                          </div>
                        </Painel>
                      </li>
                    );
                  })}
                </ul>
              )}
            </Secao>

            <Secao titulo="Quadro por loja">
              {!r.quadro.length ? <Vazio titulo="Ninguém no seu acesso" icone={<UsersRound className="h-6 w-6" />} /> : (
                <Tabela rotulo="Quadro de pessoas por loja">
                  <thead><tr><th className={th}>Loja</th><th className={th}>Ativos</th><th className={th}>Em experiência</th><th className={th}>De férias</th>
                    <th className={th}>Afastados</th><th className={th}>Em admissão</th><th className={th}>Admitidos no mês</th><th className={th}>Desligados no mês</th></tr></thead>
                  <tbody>{r.quadro.map((x) => (
                    <tr key={x.unidade_id ?? "sem"}>
                      <td className={td}><span className="font-bold">{rotuloUnidade(x.unidade_id, eu.unidades)}</span></td>
                      <td className={tdn}>{numero(x.ativos)}</td><td className={tdn}>{numero(x.em_experiencia)}</td><td className={tdn}>{numero(x.em_ferias)}</td>
                      <td className={tdn}>{numero(x.afastados)}</td><td className={tdn}>{numero(x.em_admissao)}</td>
                      <td className={tdn}>{numero(x.admitidos_mes)}</td><td className={tdn}>{numero(x.desligados_mes)}</td>
                    </tr>
                  ))}</tbody>
                </Tabela>
              )}
            </Secao>

            <Secao titulo="Lista do mês para a contabilidade" descricao="Confira antes de mandar ao escritório. Sem valores: salário e rescisão ficam com a contabilidade."
              acoes={<Botao tamanho="sm" icone={<Printer className="h-4 w-4" aria-hidden />} onClick={() => window.print()}>Imprimir</Botao>}>
              {vazio ? <Vazio titulo="Nada registrado neste mês" /> : (
                <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
                  {[
                    { titulo: "Admissões", itens: c.admissoes.map((x) => ({ k: `${x.nome}-${x.data}`, nome: x.nome, u: x.unidade_id, info: `${data(x.data)}${x.cargo ? ` · ${x.cargo}` : ""}` })) },
                    { titulo: "Desligamentos", itens: c.desligamentos.map((x) => ({ k: `${x.nome}-${x.data}`, nome: x.nome, u: x.unidade_id, info: `${data(x.data)}${x.modalidade ? ` · ${x.modalidade.replaceAll("_", " ")}` : ""}` })) },
                    { titulo: "Férias", itens: c.ferias.map((x) => ({ k: `${x.nome}-${x.inicio}`, nome: x.nome, u: x.unidade_id, info: `${data(x.inicio)} a ${data(x.fim)}${x.programada ? " · programada" : ""}` })) },
                    { titulo: "Mudanças de cargo ou salário", itens: c.mudancas.map((x) => ({ k: `${x.nome}-${x.tipo}-${x.data}`, nome: x.nome, u: x.unidade_id, info: `${x.tipo === "cargo" ? "Cargo" : "Salário"} a partir de ${data(x.data)}` })) },
                  ].map((g) => (
                    <Painel key={g.titulo} className="px-4 py-3">
                      <h3 className="mb-2 text-sm font-bold">{g.titulo} <span className="font-normal text-suave">({g.itens.length})</span></h3>
                      {!g.itens.length ? <p className="text-sm text-suave">Nenhuma.</p> : (
                        <ul className="flex flex-col gap-1 text-sm">
                          {g.itens.map((i) => <li key={i.k}><span className="font-bold">{i.nome}</span> <span className="text-suave">· {rotuloUnidade(i.u, eu.unidades)} · {i.info}</span></li>)}
                        </ul>
                      )}
                    </Painel>
                  ))}
                </div>
              )}
            </Secao>
            <p className="flex items-center gap-2 text-xs text-suave"><UsersRound className="h-4 w-4" aria-hidden />O painel mostra só nome, loja, cargo e datas: CPF, endereço, salário e documentos ficam no RH 360.</p>
          </>
        );
      })()}
    </>
  );
}
