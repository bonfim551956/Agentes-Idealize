import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CheckCircle2, MessagesSquare, Store } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type ComercialPainel } from "../lib/api";
import { dinheiro, numero, relativo, rotuloUnidade, type Tom } from "../lib/format";
import { Botao, Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, Vazio, cx, entradaCls, td, tdn, th } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

const ALERTA: Record<string, { rotulo: string; tom: Tom }> = {
  cliente_sem_resposta: { rotulo: "Cliente esperando resposta", tom: "critico" },
  lead_sem_responsavel: { rotulo: "Lead sem responsável", tom: "atencao" },
  lead_parado: { rotulo: "Lead parado", tom: "atencao" },
  funil_sem_loja: { rotulo: "Funil sem loja definida", tom: "neutro" },
};

const minutos = (m: number | null | undefined) => {
  if (m == null) return "sem dados";
  if (m < 60) return `${numero(Math.round(m))} min`;
  const h = Math.floor(m / 60), r = Math.round(m % 60);
  return r ? `${h} h ${r} min` : `${h} h`;
};

function textoAlerta(a: ComercialPainel["alertas"][number]): { titulo: string; detalhe: string } {
  const d = a.detalhe ?? {};
  const [tipo, id] = a.referencia.split(":");
  const quem = tipo === "contact" ? `Contato ${id} (sem lead)` : tipo === "funil" ? String(d.funil ?? `Funil ${id}`) : `Lead ${id}`;
  switch (a.tipo) {
    case "cliente_sem_resposta": {
      const desde = typeof d.desde === "string" ? d.desde : null;
      const m = desde ? (Date.now() - new Date(desde).getTime()) / 60000 : Number(d.minutos ?? 0);
      return { titulo: quem, detalhe: `Última mensagem do cliente há ${minutos(m)} (limite ${String(d.limite_min ?? "?")} min).` };
    }
    case "lead_parado": return { titulo: quem, detalhe: `Em "${String(d.etapa ?? "?")}" sem movimento há ${String(d.dias ?? "?")} dias (limite ${String(d.limite_dias ?? "?")}).` };
    case "lead_sem_responsavel": return { titulo: quem, detalhe: "Lead em aberto sem atendente responsável." };
    case "funil_sem_loja": return { titulo: quem, detalhe: "Defina a loja deste funil para os números entrarem na loja certa." };
    default: return { titulo: quem, detalhe: "" };
  }
}

function LojaDoFunil({ f, unidades }: { f: NonNullable<ComercialPainel["funis"]>[number]; unidades: { id: string; nome: string }[] }) {
  const qc = useQueryClient();
  const [loja, setLoja] = useState(f.unidade_id ?? "");
  const id = `funil-${f.id}`;
  return (
    <tr>
      <td className={td}><span className="font-bold">{f.nome}</span></td>
      <td className={td}>
        <label className="sr-only" htmlFor={id}>Loja do funil {f.nome}</label>
        <select id={id} className={entradaCls} value={loja} onChange={(e) => setLoja(e.target.value)}>
          <option value="">Sem loja definida</option>
          {unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
        </select>
      </td>
      <td className={td}>
        <Confirmar gatilho={<Botao disabled={loja === (f.unidade_id ?? "")}>Salvar</Botao>}
          titulo={`Definir a loja do funil "${f.nome}"?`} rotuloConfirmar="Salvar"
          descricao={loja ? `Os leads e alertas deste funil passam a contar para ${rotuloUnidade(loja, unidades)}.` : "O funil volta a ficar sem loja."}
          motivo={{ rotulo: "Motivo", minimo: 5 }}
          aoConfirmar={(m) => rpc("painel_comercial_funil_loja", { p_funil: f.id, p_unidade: loja || null, p_motivo: m })}
          aoConcluir={() => qc.invalidateQueries({ queryKey: ["comercial"] })} />
      </td>
    </tr>
  );
}

export function Comercial() {
  const { eu } = useSessao();
  const [unidade, setUnidade] = useState("");
  const [dias, setDias] = useState(7);
  const [tipo, setTipo] = useState("");
  const q = useQuery({ queryKey: ["comercial", unidade, dias],
    queryFn: () => rpc<ComercialPainel>("painel_comercial", { p_unidade: unidade || null, p_dias: dias }), refetchInterval: 60_000 });

  return (
    <>
      <Cabecalho titulo="Comercial"
        descricao="Atendimento na Kommo: quem está esperando resposta, tempo de resposta das atendentes e conversão por loja. O agente só lê; não envia mensagens nem mexe nos leads." />
      {q.isLoading ? <Carregando linhas={5} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const c = q.data!;
        const ligado = c.sincronizacao.ativa && c.sincronizacao.agente === "ativo";
        const alertas = c.alertas.filter((a) => !tipo || a.tipo === tipo);
        const semLoja = (c.funis ?? []).filter((f) => !f.unidade_id).length;
        return (
          <>
            <div role="status" className={cx("mb-8 rounded-grande border px-6 py-4 text-sm",
              ligado ? "border-linha bg-superficie" : "border-atencao/40 bg-atencao-fundo text-atencao")}>
              {ligado
                ? <>Lendo a Kommo a cada 15 minutos. Última leitura {relativo(c.sincronizacao.ultima?.em)}.</>
                : <span className="font-bold">Agente desligado: os números abaixo são da última leitura{c.sincronizacao.ultima ? ` (${relativo(c.sincronizacao.ultima.em)})` : ", e ainda não houve nenhuma"}.</span>}
              {semLoja > 0 && <p className="mt-1">{semLoja === 1 ? "1 funil ainda não tem loja definida." : `${semLoja} funis ainda não têm loja definida.`}</p>}
            </div>

            <div className="mb-6 grid grid-cols-1 gap-2 sm:grid-cols-3 lg:max-w-3xl">
              <label className="sr-only" htmlFor="c-un">Loja</label>
              <select id="c-un" className={entradaCls} value={unidade} onChange={(e) => setUnidade(e.target.value)}>
                <option value="">Todas as lojas</option>
                {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
              </select>
              <label className="sr-only" htmlFor="c-dias">Período</label>
              <select id="c-dias" className={entradaCls} value={dias} onChange={(e) => setDias(Number(e.target.value))}>
                <option value={1}>Hoje e ontem</option>
                <option value={7}>Últimos 7 dias</option>
                <option value={30}>Últimos 30 dias</option>
              </select>
              <label className="sr-only" htmlFor="c-tipo">Tipo de alerta</label>
              <select id="c-tipo" className={entradaCls} value={tipo} onChange={(e) => setTipo(e.target.value)}>
                <option value="">Todos os alertas</option>
                {Object.entries(ALERTA).map(([k, v]) => <option key={k} value={k}>{v.rotulo}</option>)}
              </select>
            </div>

            <Secao titulo="Alertas abertos" descricao="Somem sozinhos quando a atendente responde ou o lead anda.">
              {!alertas.length ? (
                <Vazio titulo="Nenhum alerta aberto" icone={<CheckCircle2 className="h-6 w-6" />}>
                  {c.sincronizacao.ultima ? "Ninguém esperando resposta na última leitura." : "Os alertas aparecem depois da primeira leitura da Kommo."}
                </Vazio>
              ) : (
                <ul className="flex flex-col gap-2">
                  {alertas.map((a) => {
                    const t = textoAlerta(a);
                    return (
                      <li key={a.id}>
                        <Painel className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-start sm:justify-between">
                          <div className="min-w-0">
                            <Etiqueta tom={ALERTA[a.tipo]?.tom}>{ALERTA[a.tipo]?.rotulo ?? a.tipo}</Etiqueta>
                            <p className="mt-1 font-bold">{t.titulo}</p>
                            <p className="text-sm text-suave">{t.detalhe}</p>
                          </div>
                          <div className="shrink-0 text-sm text-suave sm:text-right">
                            <p>{a.unidade_id ? rotuloUnidade(a.unidade_id, eu.unidades) : "Sem loja definida"}</p>
                            {a.responsavel && <p>{a.responsavel}</p>}
                          </div>
                        </Painel>
                      </li>
                    );
                  })}
                </ul>
              )}
            </Secao>

            <Secao titulo="Tempo de resposta" descricao={`Da mensagem do cliente até a primeira resposta da atendente. Meta: até ${c.limite_resposta_min} min. O tempo médio conta só o horário de atendimento (${c.horario_atendimento.replace("-", " às ")}), para a mensagem da madrugada não inflar a conta.`}>
              <dl className="mb-4 grid grid-cols-2 gap-6 sm:max-w-2xl sm:grid-cols-4">
                <div><dt className="text-xs text-suave">Conversas respondidas</dt><dd className="text-lg font-bold">{numero(c.resposta_geral.respondidas)}</dd></div>
                <div><dt className="text-xs text-suave">Tempo médio</dt><dd className="text-lg font-bold">{minutos(c.resposta_geral.media_min)}</dd></div>
                <div><dt className="text-xs text-suave">Tempo típico (mediana)</dt><dd className="text-lg font-bold">{minutos(c.resposta_geral.mediana_min)}</dd></div>
                <div><dt className="text-xs text-suave">Dentro da meta</dt>
                  <dd className="text-lg font-bold">{c.resposta_geral.no_limite_pct == null ? "sem dados" : `${numero(c.resposta_geral.no_limite_pct)}%`}</dd></div>
              </dl>
              {!c.atendentes.length ? <Vazio titulo="Ainda sem respostas no período" icone={<MessagesSquare className="h-6 w-6" />} /> : (
                <Tabela rotulo="Tempo de resposta por atendente">
                  <thead><tr><th className={th}>Atendente</th><th className={th}>Respondidas</th><th className={th}>Tempo médio</th><th className={th}>Tempo típico</th><th className={th}>Dentro da meta</th><th className={th}>Vendas ganhas</th></tr></thead>
                  <tbody>{c.atendentes.map((a) => (
                    <tr key={a.id}>
                      <td className={td}><span className="font-bold">{a.nome}</span></td>
                      <td className={tdn}>{numero(a.respondidas)}</td>
                      <td className={cx(tdn, (a.media_min ?? 0) > c.limite_resposta_min && "font-bold text-atencao")}>{minutos(a.media_min)}</td>
                      <td className={cx(tdn, (a.mediana_min ?? 0) > c.limite_resposta_min && "font-bold text-atencao")}>{minutos(a.mediana_min)}</td>
                      <td className={tdn}>{a.no_limite_pct == null ? "sem dados" : `${numero(a.no_limite_pct)}%`}</td>
                      <td className={tdn}>{numero(a.ganhos)}</td>
                    </tr>
                  ))}</tbody>
                </Tabela>
              )}
            </Secao>

            <Secao titulo="Conversão por loja" descricao={`Leads novos e vendas fechadas nos últimos ${c.periodo_dias} ${c.periodo_dias === 1 ? "dia" : "dias"}.`}>
              {!c.lojas.length ? <Vazio titulo="Nenhum lead no seu acesso" /> : (
                <Tabela rotulo="Conversão por loja">
                  <thead><tr><th className={th}>Loja</th><th className={th}>Leads novos</th><th className={th}>Em aberto</th><th className={th}>Ganhos</th><th className={th}>Perdidos</th><th className={th}>Taxa de ganho</th><th className={th}>Valor ganho</th></tr></thead>
                  <tbody>{c.lojas.map((l) => {
                    const fech = l.ganhos + l.perdidos;
                    return (
                      <tr key={l.id}>
                        <td className={td}><span className={cx("font-bold", l.id === "_sem_loja" && "text-suave")}>{l.nome}</span></td>
                        <td className={tdn}>{numero(l.leads_novos)}</td>
                        <td className={tdn}>{numero(l.em_aberto)}</td>
                        <td className={tdn}>{numero(l.ganhos)}</td>
                        <td className={tdn}>{numero(l.perdidos)}</td>
                        <td className={tdn}>{fech ? `${numero(Math.round((1000 * l.ganhos) / fech) / 10)}%` : "sem dados"}</td>
                        <td className={tdn}>{dinheiro(l.valor_ganho)}</td>
                      </tr>
                    );
                  })}</tbody>
                </Tabela>
              )}
            </Secao>

            {c.funis && eu.pode.administrar && (
              <Secao titulo="Loja de cada funil" descricao="Cada funil da Kommo pertence a uma loja. É só uma etiqueta aqui no painel; nada muda na Kommo.">
                {!c.funis.length ? <Vazio titulo="Nenhum funil lido ainda" icone={<Store className="h-6 w-6" />} /> : (
                  <Tabela rotulo="Loja de cada funil">
                    <thead><tr><th className={th}>Funil</th><th className={th}>Loja</th><th className={th}><span className="sr-only">Ação</span></th></tr></thead>
                    <tbody>{c.funis.map((f) => <LojaDoFunil key={f.id} f={f} unidades={eu.unidades} />)}</tbody>
                  </Tabela>
                )}
              </Secao>
            )}
            <p className="flex items-center gap-2 text-xs text-suave"><MessagesSquare className="h-4 w-4" aria-hidden />O painel guarda só números de lead, etapa e horário das mensagens: nome, telefone e o texto das conversas ficam na Kommo.</p>
          </>
        );
      })()}
    </>
  );
}
