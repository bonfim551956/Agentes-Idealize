import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CheckCircle2, Megaphone, Store } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type MarketingPainel } from "../lib/api";
import { data, dinheiro, numero, relativo, rotuloUnidade, type Tom } from "../lib/format";
import { Botao, Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, Vazio, cx, entradaCls, td, tdn, th } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

const ALERTA: Record<string, { rotulo: string; tom: Tom }> = {
  conta_com_problema: { rotulo: "Conta com problema na Meta", tom: "critico" },
  gasto_sem_resultado: { rotulo: "Gastando sem resultado", tom: "critico" },
  entrega_parada: { rotulo: "Anúncios pararam de rodar", tom: "atencao" },
  anuncio_reprovado: { rotulo: "Anúncio reprovado", tom: "atencao" },
  custo_alto: { rotulo: "Custo por resultado subiu", tom: "atencao" },
  conta_sem_loja: { rotulo: "Conta sem loja definida", tom: "neutro" },
};
const STATUS_CONTA: Record<number, string> = {
  1: "Ativa", 2: "Desativada", 3: "Pagamento pendente", 7: "Em análise de risco", 8: "Acerto pendente",
  9: "Período de carência", 100: "Encerramento pendente", 101: "Encerrada",
};
const MARCA: Record<string, string> = { idealize: "Óticas Idealize", visao_ideal: "Visão Ideal", outra: "Outra", sem_marca: "Sem marca definida" };
const custo = (g: number, r: number) => (r > 0 ? dinheiro(g / r) : "sem resultado");

function textoAlerta(a: MarketingPainel["alertas"][number]): { titulo: string; detalhe: string } {
  const d = a.detalhe ?? {};
  const s = (k: string) => String(d[k] ?? "");
  switch (a.tipo) {
    case "gasto_sem_resultado": return { titulo: s("campanha"), detalhe: `${dinheiro(Number(d.gasto))} gastos desde ontem sem nenhuma conversa ou lead. Conta ${s("conta")}.` };
    case "custo_alto": return { titulo: s("campanha"), detalhe: `Custo por resultado nos últimos 3 dias: ${dinheiro(Number(d.custo_recente))}, contra ${dinheiro(Number(d.custo_base))} no resto do mês (${s("acima_pct")}% acima).` };
    case "conta_com_problema": return { titulo: s("conta"), detalhe: `Situação na Meta: ${STATUS_CONTA[Number(d.status_meta)] ?? `código ${s("status_meta")}`}. Os anúncios dessa conta podem estar parados.` };
    case "anuncio_reprovado": return { titulo: s("anuncio"), detalhe: `${d.status === "DISAPPROVED" ? "Reprovado" : "Com problema"} na campanha ${s("campanha") || "?"}, conta ${s("conta")}.` };
    case "entrega_parada": return { titulo: s("conta"), detalhe: `Gastou ${dinheiro(Number(d.gasto_7d))} na semana e nada ontem, mesmo com campanha ativa. Vale olhar pagamento e entrega.` };
    case "conta_sem_loja": return { titulo: s("conta"), detalhe: "Defina a loja e a marca desta conta para os números entrarem no lugar certo." };
    default: return { titulo: a.referencia, detalhe: "" };
  }
}

function LojaDaConta({ c, unidades }: { c: NonNullable<MarketingPainel["contas"]>[number]; unidades: { id: string; nome: string }[] }) {
  const qc = useQueryClient();
  const [loja, setLoja] = useState(c.unidade_id ?? c.sugestao.unidade_id ?? "");
  const [marca, setMarca] = useState(c.marca ?? c.sugestao.marca ?? "");
  const mudou = loja !== (c.unidade_id ?? "") || marca !== (c.marca ?? "");
  const sugerido = !c.unidade_id && (c.sugestao.unidade_id || c.sugestao.marca);
  return (
    <tr>
      <td className={td}>
        <span className="font-bold">{c.nome}</span>
        <p className="text-xs text-suave">{STATUS_CONTA[c.status_meta] ?? `código ${c.status_meta}`} · {dinheiro(c.gasto_30d)} em 30 dias</p>
        {sugerido && <p className="text-xs text-lente">Sugestão pelo nome da conta; confira antes de salvar.</p>}
      </td>
      <td className={td}>
        <label className="sr-only" htmlFor={`cl-${c.id}`}>Loja da conta {c.nome}</label>
        <select id={`cl-${c.id}`} className={entradaCls} value={loja} onChange={(e) => setLoja(e.target.value)}>
          <option value="">Sem loja definida</option>
          {unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
        </select>
      </td>
      <td className={td}>
        <label className="sr-only" htmlFor={`cm-${c.id}`}>Marca da conta {c.nome}</label>
        <select id={`cm-${c.id}`} className={entradaCls} value={marca} onChange={(e) => setMarca(e.target.value)}>
          <option value="">Sem marca</option>
          <option value="idealize">Óticas Idealize</option>
          <option value="visao_ideal">Visão Ideal</option>
          <option value="outra">Outra</option>
        </select>
      </td>
      <td className={td}>
        <Confirmar gatilho={<Botao disabled={!mudou}>Salvar</Botao>}
          titulo={`Definir loja e marca de "${c.nome}"?`} rotuloConfirmar="Salvar"
          descricao={`Os números desta conta passam a contar para ${loja ? rotuloUnidade(loja, unidades) : "nenhuma loja"}${marca ? `, marca ${MARCA[marca]}` : ""}. Nada muda na Meta.`}
          motivo={{ rotulo: "Motivo", minimo: 5 }}
          aoConfirmar={(m) => rpc("painel_marketing_conta_loja", { p_conta: c.id, p_unidade: loja || null, p_marca: marca || null, p_motivo: m })}
          aoConcluir={() => qc.invalidateQueries({ queryKey: ["marketing"] })} />
      </td>
    </tr>
  );
}

function GastoPorDia({ dias }: { dias: MarketingPainel["por_dia"] }) {
  const max = Math.max(1, ...dias.map((d) => d.gasto));
  return (
    <ol className="flex h-32 items-end gap-1" aria-label="Gasto por dia">
      {dias.map((d) => (
        <li key={d.dia} className="flex h-full min-w-0 flex-1 flex-col justify-end" title={`${data(d.dia)}: ${dinheiro(d.gasto)}, ${numero(d.resultados)} resultados`}>
          <span className="block rounded-t-pequeno bg-lente" style={{ height: `${Math.max(2, (100 * d.gasto) / max)}%` }} />
          <span className="sr-only">{data(d.dia)}: {dinheiro(d.gasto)}, {numero(d.resultados)} resultados</span>
        </li>
      ))}
    </ol>
  );
}

export function Marketing() {
  const { eu } = useSessao();
  const [unidade, setUnidade] = useState("");
  const [dias, setDias] = useState(7);
  const [tipo, setTipo] = useState("");
  const [recrut, setRecrut] = useState(false);
  const q = useQuery({ queryKey: ["marketing", unidade, dias],
    queryFn: () => rpc<MarketingPainel>("painel_marketing", { p_unidade: unidade || null, p_dias: dias }), refetchInterval: 120_000 });

  return (
    <>
      <Cabecalho titulo="Marketing"
        descricao="Campanhas da Meta por loja: quanto foi gasto, quantas conversas e leads vieram e o que precisa de atenção. O agente só lê; não cria, pausa nem altera anúncios." />
      {q.isLoading ? <Carregando linhas={5} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const m = q.data!;
        const ligado = m.sincronizacao.ativa && m.sincronizacao.agente === "ativo";
        const alertas = m.alertas.filter((a) => !tipo || a.tipo === tipo);
        const gasto = m.lojas.reduce((s, l) => s + Number(l.gasto), 0);
        const conv = m.lojas.reduce((s, l) => s + Number(l.conversas), 0);
        const leads = m.lojas.reduce((s, l) => s + Number(l.leads), 0);
        const gRec = m.lojas.reduce((s, l) => s + Number(l.gasto_recrutamento), 0);
        const camps = m.campanhas.filter((c) => c.recrutamento === recrut);
        const semLoja = (m.contas ?? []).filter((c) => !c.unidade_id).length;
        return (
          <>
            <div role="status" className={cx("mb-8 rounded-grande border px-6 py-4 text-sm",
              ligado ? "border-linha bg-superficie" : "border-atencao/40 bg-atencao-fundo text-atencao")}>
              {ligado
                ? <>Lendo a Meta de hora em hora. Última leitura {relativo(m.sincronizacao.ultima?.em)}.</>
                : <span className="font-bold">Agente desligado: os números abaixo são da última leitura{m.sincronizacao.ultima ? ` (${relativo(m.sincronizacao.ultima.em)})` : ", e ainda não houve nenhuma"}.</span>}
              {semLoja > 0 && <p className="mt-1">{semLoja === 1 ? "1 conta de anúncio ainda não tem loja definida." : `${semLoja} contas de anúncio ainda não têm loja definida.`}</p>}
            </div>

            <div className="mb-6 grid grid-cols-1 gap-2 sm:grid-cols-3 lg:max-w-3xl">
              <label className="sr-only" htmlFor="m-un">Loja</label>
              <select id="m-un" className={entradaCls} value={unidade} onChange={(e) => setUnidade(e.target.value)}>
                <option value="">Todas as lojas</option>
                {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
              </select>
              <label className="sr-only" htmlFor="m-dias">Período</label>
              <select id="m-dias" className={entradaCls} value={dias} onChange={(e) => setDias(Number(e.target.value))}>
                <option value={1}>Hoje</option>
                <option value={7}>Últimos 7 dias</option>
                <option value={30}>Últimos 30 dias</option>
              </select>
              <label className="sr-only" htmlFor="m-tipo">Tipo de alerta</label>
              <select id="m-tipo" className={entradaCls} value={tipo} onChange={(e) => setTipo(e.target.value)}>
                <option value="">Todos os alertas</option>
                {Object.entries(ALERTA).map(([k, v]) => <option key={k} value={k}>{v.rotulo}</option>)}
              </select>
            </div>

            <dl className="mb-12 grid grid-cols-2 gap-6 sm:grid-cols-4">
              <div><dt className="text-xs text-suave">Investido em vendas</dt><dd className="text-2xl font-bold">{dinheiro(gasto)}</dd></div>
              <div><dt className="text-xs text-suave">Conversas iniciadas</dt><dd className="text-2xl font-bold">{numero(conv)}</dd></div>
              <div><dt className="text-xs text-suave">Custo por conversa ou lead</dt><dd className="text-2xl font-bold">{custo(gasto, conv + leads)}</dd></div>
              <div><dt className="text-xs text-suave">Vagas de emprego (fora da conta)</dt><dd className="text-2xl font-bold text-suave">{dinheiro(gRec)}</dd></div>
            </dl>

            <Secao titulo="Alertas abertos" descricao="Somem sozinhos quando a situação muda na Meta.">
              {!alertas.length ? (
                <Vazio titulo="Nenhum alerta aberto" icone={<CheckCircle2 className="h-6 w-6" />}>
                  {m.sincronizacao.ultima ? "Nada fora do normal na última leitura." : "Os alertas aparecem depois da primeira leitura da Meta."}
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
                            <p className="mt-1 break-words font-bold">{t.titulo}</p>
                            <p className="text-sm text-suave">{t.detalhe}</p>
                          </div>
                          <p className="shrink-0 text-sm text-suave sm:text-right">{a.unidade_id ? rotuloUnidade(a.unidade_id, eu.unidades) : "Sem loja definida"}</p>
                        </Painel>
                      </li>
                    );
                  })}
                </ul>
              )}
            </Secao>

            <Secao titulo="Por loja" descricao={`De ${data(m.desde)} a ${data(m.ate)}. Vagas de emprego ficam fora do custo.`}>
              {!m.lojas.length ? <Vazio titulo="Nenhum gasto no seu acesso" icone={<Megaphone className="h-6 w-6" />} /> : (
                <Tabela rotulo="Resultados por loja">
                  <thead><tr><th className={th}>Loja</th><th className={th}>Investido</th><th className={th}>Conversas</th><th className={th}>Leads</th><th className={th}>Custo por resultado</th><th className={th}>Vagas</th></tr></thead>
                  <tbody>{m.lojas.map((l) => (
                    <tr key={l.id}>
                      <td className={td}><span className={cx("font-bold", l.id === "_sem_loja" && "text-suave")}>{l.nome}</span></td>
                      <td className={tdn}>{dinheiro(l.gasto)}</td>
                      <td className={tdn}>{numero(l.conversas)}</td>
                      <td className={tdn}>{numero(l.leads)}</td>
                      <td className={tdn}>{custo(Number(l.gasto), Number(l.conversas) + Number(l.leads))}</td>
                      <td className={cx(tdn, "text-suave")}>{dinheiro(l.gasto_recrutamento)}</td>
                    </tr>
                  ))}</tbody>
                </Tabela>
              )}
              {m.marcas.length > 1 && (
                <ul className="mt-4 flex flex-wrap gap-x-8 gap-y-2 text-sm">
                  {m.marcas.map((x) => <li key={x.marca}><span className="font-bold">{MARCA[x.marca] ?? x.marca}:</span> {dinheiro(x.gasto)} · {custo(Number(x.gasto), Number(x.conversas) + Number(x.leads))} por resultado</li>)}
                </ul>
              )}
            </Secao>

            {m.por_dia.length > 1 && (
              <Secao titulo="Investimento por dia">
                <GastoPorDia dias={m.por_dia} />
                <div className="mt-2 flex justify-between text-xs text-suave"><span>{data(m.por_dia[0].dia)}</span><span>{data(m.por_dia[m.por_dia.length - 1].dia)}</span></div>
              </Secao>
            )}

            <Secao titulo="Campanhas" descricao="As que gastaram no período, da que mais gastou para a que menos gastou."
              acoes={<div className="flex gap-1" role="group" aria-label="Tipo de campanha">
                <Botao tamanho="sm" variante={recrut ? "fantasma" : "secundario"} aria-pressed={!recrut} onClick={() => setRecrut(false)}>Vendas</Botao>
                <Botao tamanho="sm" variante={recrut ? "secundario" : "fantasma"} aria-pressed={recrut} onClick={() => setRecrut(true)}>Vagas de emprego</Botao>
              </div>}>
              {!camps.length ? <Vazio titulo="Nenhuma campanha com gasto no período" /> : (
                <Tabela rotulo="Campanhas com gasto no período">
                  <thead><tr><th className={th}>Campanha</th><th className={th}>Loja</th><th className={th}>Investido</th><th className={th}>{recrut ? "Visitas à página" : "Conversas e leads"}</th><th className={th}>{recrut ? "Custo por visita" : "Custo por resultado"}</th></tr></thead>
                  <tbody>{camps.map((c) => (
                    <tr key={c.id}>
                      <td className={td}>
                        <span className="break-words font-bold">{c.nome}</span>
                        <p className="text-xs text-suave">{c.conta}{c.status && c.status !== "ACTIVE" ? " · não está ativa" : ""}</p>
                      </td>
                      <td className={td}>{c.unidade_id ? rotuloUnidade(c.unidade_id, eu.unidades) : "Sem loja"}</td>
                      <td className={tdn}>{dinheiro(c.gasto)}</td>
                      <td className={tdn}>{numero(recrut ? c.visitas : Number(c.conversas) + Number(c.leads))}</td>
                      <td className={tdn}>{recrut ? custo(Number(c.gasto), Number(c.visitas)) : custo(Number(c.gasto), Number(c.conversas) + Number(c.leads))}</td>
                    </tr>
                  ))}</tbody>
                </Tabela>
              )}
            </Secao>

            {m.contas && eu.pode.administrar && (
              <Secao titulo="Loja e marca de cada conta de anúncio" descricao="É só uma etiqueta aqui no painel; nada muda na Meta.">
                {!m.contas.length ? <Vazio titulo="Nenhuma conta lida ainda" icone={<Store className="h-6 w-6" />} /> : (
                  <Tabela rotulo="Loja e marca de cada conta de anúncio">
                    <thead><tr><th className={th}>Conta</th><th className={th}>Loja</th><th className={th}>Marca</th><th className={th}><span className="sr-only">Ação</span></th></tr></thead>
                    <tbody>{m.contas.map((c) => <LojaDaConta key={c.id} c={c} unidades={eu.unidades} />)}</tbody>
                  </Tabela>
                )}
              </Secao>
            )}
            <p className="flex items-center gap-2 text-xs text-suave"><Megaphone className="h-4 w-4" aria-hidden />O painel guarda só números agregados por campanha e por dia; nenhum dado de pessoa que viu ou respondeu os anúncios.</p>
          </>
        );
      })()}
    </>
  );
}
