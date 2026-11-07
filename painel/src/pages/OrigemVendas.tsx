import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useSessao } from "../auth/Sessao";
import { rpc } from "../lib/api";
import { data, dinheiro, numero, relativo, rotuloUnidade, type Tom } from "../lib/format";
import { traduzir } from "../lib/erros";
import { Botao, Cabecalho, Carregando, ErroCaixa, Etiqueta, Secao, Tabela, Vazio, cx, entradaCls, td, tdn, th } from "../ui/base";

// Origem de cada venda do ADM: Loja ou Visão Ideal, e de qual loja veio o cliente (pelo funil do lead na Kommo).
type Linha = { unidade_id: string; origem: string; vendas: number; valor: number };
type Cruzada = { unidade_lead: string; unidade_venda: string; origem: string; vendas: number; valor: number };
type Venda = { os: string; unidade_id: string; dia: string; valor: number; origem: string; unidade_lead: string | null; funil: string | null; dia_lead: string | null; dias_ate_venda: number | null };
type Funil = { id: number; nome: string; tipo: string | null; unidade_id: string | null };
type Dados = { desde: string; ate: string; dias: number; pode_editar: boolean; janela_dias: number; ultima_leitura: string | null;
  resumo: Linha[]; cruzadas: Cruzada[]; vendas: Venda[]; funis: Funil[] };

const ORIGEM: Record<string, { rotulo: string; tom: Tom }> = {
  loja: { rotulo: "Loja", tom: "lente" },
  visao_ideal: { rotulo: "Visão Ideal", tom: "ok" },
  pos_venda: { rotulo: "Pós-venda", tom: "neutro" },
  recorrente: { rotulo: "Cliente que já comprou", tom: "neutro" },
  sem_origem: { rotulo: "Sem origem", tom: "atencao" },
  sem_classificacao: { rotulo: "Funil sem classificação", tom: "critico" },
};
const COLUNAS = ["loja", "visao_ideal", "pos_venda", "recorrente", "sem_origem", "sem_classificacao"];
const TIPOS_FUNIL: [string, string][] = [["loja", "Loja"], ["visao_ideal", "Visão Ideal"], ["pos_venda", "Pós-venda"], ["ignorar", "Não usar"]];

function FunilLinha({ f, unidades, podeEditar, aoSalvar }: { f: Funil; unidades: { id: string; nome: string }[]; podeEditar: boolean; aoSalvar: () => void }) {
  const [tipo, setTipo] = useState(f.tipo ?? "");
  const [un, setUn] = useState(f.unidade_id ?? "");
  const [erro, setErro] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  const mudou = tipo !== (f.tipo ?? "") || un !== (f.unidade_id ?? "");
  async function salvar() {
    setEnviando(true); setErro(null);
    try { await rpc("painel_origem_funil_salvar", { p_funil: f.id, p_tipo: tipo, p_unidade: un || null }); aoSalvar(); }
    catch (e) { setErro(traduzir(e).message); } finally { setEnviando(false); }
  }
  return (
    <tr>
      <td className={td}><span className="font-bold">{f.nome}</span>{!f.tipo && <Etiqueta tom="critico" className="ml-2">sem classificação</Etiqueta>}
        {erro && <p role="alert" className="text-sm font-bold text-critico">{erro}</p>}</td>
      <td className={td}>
        <label className="sr-only" htmlFor={`ft-${f.id}`}>Tipo do funil {f.nome}</label>
        <select id={`ft-${f.id}`} className={entradaCls} disabled={!podeEditar} value={tipo} onChange={(e) => setTipo(e.target.value)}>
          <option value="">—</option>{TIPOS_FUNIL.map(([k, r]) => <option key={k} value={k}>{r}</option>)}
        </select>
      </td>
      <td className={td}>
        <label className="sr-only" htmlFor={`fu-${f.id}`}>Loja do funil {f.nome}</label>
        <select id={`fu-${f.id}`} className={entradaCls} disabled={!podeEditar} value={un} onChange={(e) => setUn(e.target.value)}>
          <option value="">—</option>{unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
        </select>
      </td>
      {podeEditar && <td className={td}><Botao tamanho="sm" disabled={!mudou || !tipo} carregando={enviando} onClick={salvar}>Salvar</Botao></td>}
    </tr>
  );
}

export function OrigemVendas() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [unidade, setUnidade] = useState("");
  const [dias, setDias] = useState(30);
  const [origem, setOrigem] = useState("");
  const q = useQuery({ queryKey: ["origem-vendas", unidade, dias, origem],
    queryFn: () => rpc<Dados>("painel_origem_vendas", { p_unidade: unidade || null, p_dias: dias, p_origem: origem || null }) });
  const d = q.data;
  const lojas = d ? [...new Set(d.resumo.map((r) => r.unidade_id))] : [];
  const cel = (u: string, o: string) => d?.resumo.find((r) => r.unidade_id === u && r.origem === o);
  const totalLoja = (u: string) => d?.resumo.filter((r) => r.unidade_id === u).reduce((s, r) => s + Number(r.valor), 0) ?? 0;

  return (
    <>
      <Cabecalho titulo="Origem das vendas"
        descricao={d ? `Vendas do ADM de ${data(d.desde)} a ${data(d.ate)}. Cada venda é ligada pelo telefone ao último lead da Kommo até ${d.janela_dias} dias antes; o funil diz se veio da Loja ou da Visão Ideal e de qual loja.${d.ultima_leitura ? ` Leitura ${relativo(d.ultima_leitura)}.` : ""}`
          : "Cada venda do ADM: veio da Loja ou da Visão Ideal, e de qual loja."} />

      <div className="mb-6 grid grid-cols-1 gap-2 sm:grid-cols-3 lg:max-w-3xl">
        <label className="sr-only" htmlFor="ov-un">Loja</label>
        <select id="ov-un" className={entradaCls} value={unidade} onChange={(e) => setUnidade(e.target.value)}>
          <option value="">Todas as lojas</option>{eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
        </select>
        <label className="sr-only" htmlFor="ov-dias">Período</label>
        <select id="ov-dias" className={entradaCls} value={dias} onChange={(e) => setDias(Number(e.target.value))}>
          {[7, 30, 60, 90].map((n) => <option key={n} value={n}>Últimos {n} dias</option>)}
        </select>
        <label className="sr-only" htmlFor="ov-or">Origem</label>
        <select id="ov-or" className={entradaCls} value={origem} onChange={(e) => setOrigem(e.target.value)}>
          <option value="">Todas as origens</option>{COLUNAS.map((k) => <option key={k} value={k}>{ORIGEM[k].rotulo}</option>)}
        </select>
      </div>

      {q.isLoading ? <Carregando linhas={6} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !d ? null : (
        <>
          <Secao titulo="Por loja" descricao="Quantidade de vendas e faturamento de cada origem.">
            {!lojas.length ? <Vazio titulo="Nenhuma venda no período" /> : (
              <Tabela rotulo="Origem das vendas por loja">
                <thead><tr><th className={th}>Loja da venda</th>{COLUNAS.map((k) => <th key={k} className={th}>{ORIGEM[k].rotulo}</th>)}<th className={th}>Total</th></tr></thead>
                <tbody>{lojas.map((u) => (
                  <tr key={u}>
                    <td className={td}><span className="font-bold">{rotuloUnidade(u, eu.unidades)}</span></td>
                    {COLUNAS.map((k) => { const c = cel(u, k); return (
                      <td key={k} className={tdn}>{c ? <><span className="font-bold">{numero(c.vendas)}</span><br /><span className="text-xs text-suave">{dinheiro(c.valor)}</span></> : <span className="text-suave">—</span>}</td>
                    ); })}
                    <td className={cx(tdn, "font-bold")}>{dinheiro(totalLoja(u))}</td>
                  </tr>
                ))}</tbody>
              </Tabela>
            )}
          </Secao>

          {d.cruzadas.length > 0 && (
            <Secao titulo="Clientes que vieram de outra loja" descricao="O lead entrou pelo funil de uma loja e a venda foi lançada em outra.">
              <ul className="flex flex-col gap-1 text-sm">
                {d.cruzadas.map((c) => (
                  <li key={`${c.unidade_lead}-${c.unidade_venda}-${c.origem}`} className="flex flex-wrap items-center gap-2">
                    <Etiqueta tom={ORIGEM[c.origem]?.tom}>{ORIGEM[c.origem]?.rotulo ?? c.origem}</Etiqueta>
                    <span>{rotuloUnidade(c.unidade_lead, eu.unidades)} → vendeu em {rotuloUnidade(c.unidade_venda, eu.unidades)}:</span>
                    <b>{numero(c.vendas)} {c.vendas === 1 ? "venda" : "vendas"}</b><span className="text-suave">{dinheiro(c.valor)}</span>
                  </li>
                ))}
              </ul>
            </Secao>
          )}

          <Secao titulo="Venda por venda" descricao={d.vendas.length >= 500 ? "Mostrando as 500 mais recentes; use os filtros." : undefined}>
            {!d.vendas.length ? <Vazio titulo="Nenhuma venda com esse filtro" /> : (
              <Tabela rotulo="Vendas e origem">
                <thead><tr><th className={th}>Dia</th><th className={th}>OS</th><th className={th}>Loja da venda</th><th className={th}>Valor</th>
                  <th className={th}>Origem</th><th className={th}>Veio da loja</th><th className={th}>Funil na Kommo</th><th className={th}>Lead → venda</th></tr></thead>
                <tbody>{d.vendas.map((v) => (
                  <tr key={v.os}>
                    <td className={tdn}>{data(v.dia)}</td><td className={tdn}>{v.os}</td>
                    <td className={tdn}>{rotuloUnidade(v.unidade_id, eu.unidades)}</td><td className={tdn}>{dinheiro(v.valor)}</td>
                    <td className={tdn}><Etiqueta tom={ORIGEM[v.origem]?.tom}>{ORIGEM[v.origem]?.rotulo ?? v.origem}</Etiqueta></td>
                    <td className={cx(tdn, v.unidade_lead && v.unidade_lead !== v.unidade_id && "font-bold text-atencao")}>{v.unidade_lead ? rotuloUnidade(v.unidade_lead, eu.unidades) : "—"}</td>
                    <td className={td}>{v.funil ?? "—"}</td>
                    <td className={tdn}>{v.dias_ate_venda == null ? "—" : v.dias_ate_venda === 0 ? "mesmo dia" : `${v.dias_ate_venda} dias`}</td>
                  </tr>
                ))}</tbody>
              </Tabela>
            )}
          </Secao>

          <Secao titulo="Funis da Kommo" descricao="Diz de onde vem cada funil. Funil novo aparece sem classificação até você escolher.">
            <Tabela rotulo="Classificação dos funis">
              <thead><tr><th className={th}>Funil</th><th className={th}>Tipo</th><th className={th}>Loja</th>{d.pode_editar && <th className={th}><span className="sr-only">Ação</span></th>}</tr></thead>
              <tbody>{d.funis.map((f) => (
                <FunilLinha key={`${f.id}-${f.tipo}-${f.unidade_id}`} f={f} unidades={eu.unidades} podeEditar={d.pode_editar}
                  aoSalvar={() => { void qc.invalidateQueries({ queryKey: ["origem-vendas"] }); }} />
              ))}</tbody>
            </Tabela>
          </Secao>
        </>
      )}
    </>
  );
}
