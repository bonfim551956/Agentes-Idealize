import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Info, TrendingUp } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type AtribuicaoPainel } from "../lib/api";
import { data, dinheiro, numero, relativo, rotuloUnidade } from "../lib/format";
import { Cabecalho, Carregando, ErroCaixa, Secao, Tabela, Vazio, cx, entradaCls, td, tdn, th } from "../ui/base";

const div = (a: number, b: number) => (b > 0 ? a / b : null);
const pct = (v: number | null) => (v == null ? "sem dados" : `${numero(Math.round(v * 1000) / 10)}%`);
const vezes = (v: number | null) => (v == null ? "sem dados" : `${numero(Math.round(v * 10) / 10)}×`);

export function Atribuicao() {
  const { eu } = useSessao();
  const [unidade, setUnidade] = useState("");
  const [dias, setDias] = useState(30);
  const q = useQuery({ queryKey: ["atribuicao", unidade, dias],
    queryFn: () => rpc<AtribuicaoPainel>("painel_atribuicao", { p_unidade: unidade || null, p_dias: dias }), refetchInterval: 600_000 });

  return (
    <>
      <Cabecalho titulo="Retorno das campanhas"
        descricao="Quanto cada loja e campanha faturou: lead da Kommo que comprou na loja (mesmo telefone, até 60 dias depois do primeiro contato). É uma estimativa conservadora." />
      {q.isLoading ? <Carregando linhas={5} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const a = q.data!;
        const ligado = a.sincronizacao.ativa && a.sincronizacao.agente === "ativo";
        const t = a.lojas.reduce((s, l) => ({ inv: s.inv + Number(l.investido), leads: s.leads + Number(l.leads), comp: s.comp + Number(l.compraram),
          fat: s.fat + Number(l.faturamento), novos: s.novos + Number(l.faturamento_novos) }), { inv: 0, leads: 0, comp: 0, fat: 0, novos: 0 });
        return (
          <>
            <div role="status" className={cx("mb-8 rounded-grande border px-6 py-4 text-sm",
              ligado ? "border-linha bg-superficie" : "border-atencao/40 bg-atencao-fundo text-atencao")}>
              {ligado
                ? <>Cruzando Kommo e vendas todo dia. Última leitura {relativo(a.sincronizacao.ultima?.em)}.</>
                : <span className="font-bold">Agente desligado: os números abaixo são da última leitura{a.sincronizacao.ultima ? ` (${relativo(a.sincronizacao.ultima.em)})` : ", e ainda não houve nenhuma"}.</span>}
            </div>

            <div className="mb-6 grid grid-cols-1 gap-2 sm:grid-cols-2 lg:max-w-xl">
              <label className="sr-only" htmlFor="at-un">Loja</label>
              <select id="at-un" className={entradaCls} value={unidade} onChange={(e) => setUnidade(e.target.value)}>
                <option value="">Todas as lojas</option>
                {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
              </select>
              <label className="sr-only" htmlFor="at-dias">Período</label>
              <select id="at-dias" className={entradaCls} value={dias} onChange={(e) => setDias(Number(e.target.value))}>
                <option value={30}>Leads dos últimos 30 dias</option>
                <option value={60}>Leads dos últimos 60 dias</option>
                <option value={90}>Leads dos últimos 90 dias</option>
              </select>
            </div>

            <dl className="mb-12 grid grid-cols-2 gap-6 sm:grid-cols-4">
              <div><dt className="text-xs text-suave">Investido em vendas</dt><dd className="text-2xl font-bold">{dinheiro(t.inv)}</dd></div>
              <div><dt className="text-xs text-suave">Faturado por leads</dt><dd className="text-2xl font-bold">{dinheiro(t.fat)}</dd></div>
              <div><dt className="text-xs text-suave">Retorno por real investido</dt><dd className="text-2xl font-bold">{vezes(div(t.fat, t.inv))}</dd></div>
              <div><dt className="text-xs text-suave">Custo por venda</dt><dd className="text-2xl font-bold">{t.comp ? dinheiro(t.inv / t.comp) : "sem dados"}</dd></div>
            </dl>

            <Secao titulo="Por loja" descricao={`Leads de ${data(a.desde)} a ${data(a.ate)}.`}>
              {!a.lojas.length ? <Vazio titulo="Ainda sem dados" icone={<TrendingUp className="h-6 w-6" />}>Aparece depois da primeira leitura.</Vazio> : (
                <Tabela rotulo="Retorno por loja">
                  <thead><tr><th className={th}>Loja</th><th className={th}>Investido</th><th className={th}>Leads</th><th className={th}>Compraram</th>
                    <th className={th}>Conversão</th><th className={th}>Faturado</th><th className={th}>De clientes novos</th><th className={th}>Retorno</th></tr></thead>
                  <tbody>{a.lojas.map((l) => (
                    <tr key={l.unidade_id}>
                      <td className={td}><span className="font-bold">{rotuloUnidade(l.unidade_id, eu.unidades)}</span>
                        <p className="text-xs text-suave">{numero(l.leads_com_telefone)} de {numero(l.leads)} leads com telefone</p></td>
                      <td className={tdn}>{dinheiro(l.investido)}</td>
                      <td className={tdn}>{numero(l.leads)}</td>
                      <td className={tdn}>{numero(l.compraram)}</td>
                      <td className={tdn}>{pct(div(Number(l.compraram), Number(l.leads)))}</td>
                      <td className={tdn}>{dinheiro(l.faturamento)}</td>
                      <td className={tdn}>{dinheiro(l.faturamento_novos)}</td>
                      <td className={cx(tdn, "font-bold")}>{vezes(div(Number(l.faturamento), Number(l.investido)))}</td>
                    </tr>
                  ))}</tbody>
                </Tabela>
              )}
            </Secao>

            <Secao titulo="Por atendente" descricao="Responsável pelo lead na Kommo. Quem atende mais leads tende a faturar mais: compare também a conversão.">
              {!a.atendentes.length ? <Vazio titulo="Ainda sem dados" /> : (
                <Tabela rotulo="Retorno por atendente">
                  <thead><tr><th className={th}>Atendente</th><th className={th}>Leads</th><th className={th}>Compraram</th><th className={th}>Conversão</th>
                    <th className={th}>Faturado</th><th className={th}>De clientes novos</th><th className={th}>Ticket médio</th></tr></thead>
                  <tbody>{a.atendentes.map((x) => (
                    <tr key={x.responsavel_id ?? "sem"}>
                      <td className={td}><span className={cx("font-bold", x.responsavel_id == null && "text-suave")}>{x.nome ?? "Sem responsável na Kommo"}</span>
                        {x.unidades?.length ? <p className="text-xs text-suave">{x.unidades.map((u) => rotuloUnidade(u, eu.unidades)).join(", ")}</p> : null}</td>
                      <td className={tdn}>{numero(x.leads)}</td>
                      <td className={tdn}>{numero(x.compraram)}</td>
                      <td className={cx(tdn, "font-bold")}>{pct(div(Number(x.compraram), Number(x.leads)))}</td>
                      <td className={tdn}>{dinheiro(x.faturamento)}</td>
                      <td className={tdn}>{dinheiro(x.faturamento_novos)}</td>
                      <td className={tdn}>{x.compraram ? dinheiro(Number(x.faturamento) / Number(x.compraram)) : "sem dados"}</td>
                    </tr>
                  ))}</tbody>
                </Tabela>
              )}
            </Secao>

            <Secao titulo="Por campanha" descricao="Quando o lead não diz de qual anúncio veio, ele é dividido entre as campanhas da loja que rodaram naquele dia, pelo gasto de cada uma.">
              {!a.campanhas.length ? <Vazio titulo="Sem campanhas com gasto no período" /> : (
                <Tabela rotulo="Retorno por campanha">
                  <thead><tr><th className={th}>Campanha</th><th className={th}>Investido</th><th className={th}>Leads (estim.)</th><th className={th}>Compraram (estim.)</th>
                    <th className={th}>Faturado (estim.)</th><th className={th}>Retorno</th></tr></thead>
                  <tbody>{a.campanhas.map((c) => (
                    <tr key={c.campanha_id}>
                      <td className={td}><span className="break-words font-bold">{c.nome ?? c.campanha_id}</span>
                        <p className="text-xs text-suave">{rotuloUnidade(c.unidade_id, eu.unidades)}{c.exatos > 0 ? ` · ${numero(c.exatos)} leads com origem confirmada` : ""}</p></td>
                      <td className={tdn}>{dinheiro(c.investido)}</td>
                      <td className={tdn}>{numero(c.leads)}</td>
                      <td className={tdn}>{numero(c.compraram)}</td>
                      <td className={tdn}>{dinheiro(c.faturamento)}</td>
                      <td className={cx(tdn, "font-bold")}>{vezes(div(Number(c.faturamento), Number(c.investido)))}</td>
                    </tr>
                  ))}</tbody>
                </Tabela>
              )}
            </Secao>
            <ul className="flex flex-col gap-1 text-xs text-suave">
              <li className="flex gap-2"><Info className="h-4 w-4 shrink-0" aria-hidden />Leads a partir de {data(a.janela_aberta_desde)} ainda podem comprar: o faturamento desse período tende a subir.</li>
              <li className="flex gap-2"><Info className="h-4 w-4 shrink-0" aria-hidden />Cliente que trocou de telefone ou comprou sem informar o número não entra: o número real é maior.</li>
              <li className="flex gap-2"><Info className="h-4 w-4 shrink-0" aria-hidden />O telefone não é guardado: vira um código que só serve para comparar lead e venda.</li>
            </ul>
          </>
        );
      })()}
    </>
  );
}
