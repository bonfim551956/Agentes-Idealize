import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ChevronDown, ChevronUp } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc } from "../lib/api";
import { data, numero, relativo } from "../lib/format";
import { traduzir } from "../lib/erros";
import { Botao, Cabecalho, Campo, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, Vazio, cx, entradaCls, td, tdn, th } from "../ui/base";

// Auditoria do atendimento: o robô lê na Kommo uma amostra das conversas de cada operadora, o Auditor dá nota pelo
// checklist do padrão e a tela cruza a nota com o resultado (agendou / comprou no ADM).
type Criterio = { id: string; titulo: string; descricao: string; peso: number; ordem: number; ativo: boolean };
type Operadora = { id: number; nome: string; conversas: number; nota_media: number; agendou: number; comprou: number; criterios: Record<string, number | null> };
type Faixa = { faixa: string; conversas: number; agendou: number; comprou: number };
type Item = { ok: boolean | null; trecho: string | null };
type Conversa = { lead_id: number; operadora: string | null; dia: string; funil: string | null; nota: number; resumo: string; itens: Record<string, Item>;
  agendou: boolean; comprou: boolean; primeira_cliente: string | null };
type Dados = { desde: string; pode_editar: boolean; ultima_leitura: string | null; ultima_avaliacao: string | null; lidas: number; avaliadas: number;
  criterios: Criterio[]; operadoras: Operadora[]; faixas: Faixa[]; conversas: Conversa[] };

const corNota = (n: number | null | undefined) => n == null ? "text-suave" : n >= 80 ? "text-ok" : n >= 50 ? "text-atencao" : "text-critico";

function ConversaCard({ c, criterios }: { c: Conversa; criterios: Criterio[] }) {
  const [aberto, setAberto] = useState(false);
  return (
    <Painel className="p-4">
      <button className="flex w-full items-start justify-between gap-4 text-left" onClick={() => setAberto(!aberto)} aria-expanded={aberto}>
        <div className="min-w-0">
          <div className="mb-1 flex flex-wrap items-center gap-2">
            <span className={cx("text-lg font-bold", corNota(c.nota))}>{c.nota}</span>
            <span className="font-bold">{c.operadora ?? "sem operadora"}</span>
            <span className="text-xs text-suave">{data(c.dia)} · {c.funil ?? "—"} · lead {c.lead_id}</span>
            {c.agendou && <Etiqueta tom="lente">agendou</Etiqueta>}
            {c.comprou && <Etiqueta tom="ok">comprou</Etiqueta>}
          </div>
          <p className="text-sm">{c.resumo}</p>
        </div>
        {aberto ? <ChevronUp className="h-5 w-5 shrink-0" /> : <ChevronDown className="h-5 w-5 shrink-0" />}
      </button>
      {aberto && (
        <ul className="mt-3 flex flex-col gap-1 border-t border-linha pt-3 text-sm">
          {c.primeira_cliente && <li className="text-suave">1ª mensagem do cliente: “{c.primeira_cliente}”</li>}
          {criterios.filter((k) => k.ativo).map((k) => {
            const it = c.itens[k.id];
            return (
              <li key={k.id} className="flex gap-2">
                <span className={cx("w-24 shrink-0 font-bold", it?.ok === true ? "text-ok" : it?.ok === false ? "text-critico" : "text-suave")}>
                  {it?.ok === true ? "fez" : it?.ok === false ? "não fez" : "não se aplica"}</span>
                <span><b>{k.titulo}</b>{it?.trecho ? <span className="text-suave"> — “{it.trecho}”</span> : null}</span>
              </li>
            );
          })}
        </ul>
      )}
    </Painel>
  );
}

function CriterioForm({ k, aoSalvar, novo }: { k?: Criterio; aoSalvar: () => void; novo?: boolean }) {
  const [f, setF] = useState({ id: k?.id ?? "", titulo: k?.titulo ?? "", descricao: k?.descricao ?? "", peso: k?.peso ?? 2, ordem: k?.ordem ?? 99, ativo: k?.ativo ?? true });
  const [erro, setErro] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  const pref = novo ? "novo" : f.id;
  async function salvar() {
    setEnviando(true); setErro(null);
    try {
      await rpc("painel_aud_criterio_salvar", { p_id: f.id, p_titulo: f.titulo, p_descricao: f.descricao, p_peso: f.peso, p_ordem: f.ordem, p_ativo: f.ativo });
      if (novo) setF({ id: "", titulo: "", descricao: "", peso: 2, ordem: 99, ativo: true });
      aoSalvar();
    } catch (e) { setErro(traduzir(e).message); } finally { setEnviando(false); }
  }
  return (
    <Painel className="grid grid-cols-1 gap-3 p-4 md:grid-cols-[1fr_2fr_auto_auto_auto] md:items-end">
      {novo && <Campo id={`c-id-${pref}`} rotulo="Código"><input id={`c-id-${pref}`} className={entradaCls} placeholder="ex.: nome_cliente" value={f.id} onChange={(e) => setF({ ...f, id: e.target.value })} /></Campo>}
      <Campo id={`c-t-${pref}`} rotulo="Critério"><input id={`c-t-${pref}`} className={entradaCls} value={f.titulo} onChange={(e) => setF({ ...f, titulo: e.target.value })} /></Campo>
      <Campo id={`c-d-${pref}`} rotulo="O que o agente procura"><input id={`c-d-${pref}`} className={entradaCls} value={f.descricao} onChange={(e) => setF({ ...f, descricao: e.target.value })} /></Campo>
      <Campo id={`c-p-${pref}`} rotulo="Peso">
        <select id={`c-p-${pref}`} className={entradaCls} value={f.peso} onChange={(e) => setF({ ...f, peso: Number(e.target.value) })}>{[1, 2, 3, 4, 5].map((n) => <option key={n} value={n}>{n}</option>)}</select>
      </Campo>
      <label className="flex items-center gap-2 pb-2 text-sm"><input type="checkbox" checked={f.ativo} onChange={(e) => setF({ ...f, ativo: e.target.checked })} />Ativo</label>
      <div className="pb-1"><Botao tamanho="sm" carregando={enviando} onClick={salvar}>{novo ? "Incluir" : "Salvar"}</Botao></div>
      {erro && <p role="alert" className="text-sm font-bold text-critico md:col-span-5">{erro}</p>}
    </Painel>
  );
}

export function Atendimento() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [dias, setDias] = useState(30);
  const [operadora, setOperadora] = useState("");
  const q = useQuery({ queryKey: ["atendimento", dias, operadora], enabled: eu.pode.consultar_global,
    queryFn: () => rpc<Dados>("painel_auditoria_atendimento", { p_dias: dias, p_operadora: operadora ? Number(operadora) : null }) });
  if (!eu.pode.consultar_global) return <Vazio titulo="Auditoria do atendimento">Esta tela fica com a diretoria.</Vazio>;
  const d = q.data;
  const ativos = d?.criterios.filter((k) => k.ativo) ?? [];
  const recarregar = () => { void qc.invalidateQueries({ queryKey: ["atendimento"] }); };
  return (
    <>
      <Cabecalho titulo="Auditoria do atendimento"
        descricao={d ? `Desde ${data(d.desde)}: ${numero(d.lidas)} conversas lidas na Kommo, ${numero(d.avaliadas)} avaliadas.${d.ultima_leitura ? ` Última leitura ${relativo(d.ultima_leitura)}.` : ""}`
          : "Quem segue o padrão de atendimento e o quanto ele funciona."}
        acoes={d ? (
          <div className="flex gap-2">
            <label className="sr-only" htmlFor="at-dias">Período</label>
            <select id="at-dias" className={entradaCls + " w-auto"} value={dias} onChange={(e) => setDias(Number(e.target.value))}>
              {[7, 30, 60, 90].map((n) => <option key={n} value={n}>Últimos {n} dias</option>)}
            </select>
          </div>
        ) : undefined} />

      {q.isLoading ? <Carregando linhas={6} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !d ? null : (
        <>
          <Secao titulo="O padrão funciona?" descricao="Resultado das conversas por faixa de nota. Se as notas altas agendam e vendem mais, o padrão está funcionando.">
            {!d.faixas.length ? <Vazio titulo="Ainda sem conversas avaliadas">O robô lê as conversas de ontem todo dia às 6h50 e o Auditor dá as notas em seguida.</Vazio> : (
              <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                {d.faixas.map((f) => (
                  <Painel key={f.faixa} className="p-4">
                    <p className="text-xs text-suave">Nota {f.faixa} · {numero(f.conversas)} conversas</p>
                    <p className="text-2xl font-bold">{f.agendou}% <span className="text-sm font-normal text-suave">agendaram</span></p>
                    <p className="font-bold">{f.comprou}% <span className="text-sm font-normal text-suave">compraram (ADM)</span></p>
                  </Painel>
                ))}
              </div>
            )}
          </Secao>

          <Secao titulo="Por operadora" descricao="% de conversas em que cada critério foi cumprido.">
            {!d.operadoras.length ? <Vazio titulo="Nenhuma operadora avaliada ainda" /> : (
              <Tabela rotulo="Nota por operadora">
                <thead><tr><th className={th}>Operadora</th><th className={th}>Conversas</th><th className={th}>Nota</th><th className={th}>Agendou</th><th className={th}>Comprou</th>
                  {ativos.map((k) => <th key={k.id} className={th}>{k.titulo}</th>)}</tr></thead>
                <tbody>{d.operadoras.map((o) => (
                  <tr key={o.id}>
                    <td className={td}><button className="font-bold text-lente underline-offset-2 hover:underline" onClick={() => setOperadora(String(o.id))}>{o.nome}</button></td>
                    <td className={tdn}>{numero(o.conversas)}</td>
                    <td className={cx(tdn, "font-bold", corNota(o.nota_media))}>{o.nota_media}</td>
                    <td className={tdn}>{o.agendou}%</td><td className={tdn}>{o.comprou}%</td>
                    {ativos.map((k) => <td key={k.id} className={cx(tdn, corNota(o.criterios?.[k.id]))}>{o.criterios?.[k.id] == null ? "—" : `${o.criterios[k.id]}%`}</td>)}
                  </tr>
                ))}</tbody>
              </Tabela>
            )}
          </Secao>

          <Secao titulo="Conversas avaliadas" acoes={operadora ? <Botao tamanho="sm" variante="fantasma" onClick={() => setOperadora("")}>Ver todas as operadoras</Botao> : undefined}
            descricao="Clique para ver critério por critério, com o trecho da conversa que prova.">
            {!d.conversas.length ? <Vazio titulo="Nenhuma conversa avaliada no período" /> : (
              <ul className="flex flex-col gap-2">{d.conversas.map((c) => <li key={c.lead_id}><ConversaCard c={c} criterios={d.criterios} /></li>)}</ul>
            )}
          </Secao>

          <Secao titulo="Checklist do padrão" descricao="O que o Auditor confere em cada conversa. Ajuste quando o script oficial estiver pronto; vale a partir da próxima avaliação.">
            <div className="flex flex-col gap-2">
              {d.criterios.map((k) => d.pode_editar ? <CriterioForm key={`${k.id}-${k.peso}-${k.ativo}-${k.titulo}`} k={k} aoSalvar={recarregar} />
                : <Painel key={k.id} className="p-4 text-sm"><b>{k.titulo}</b> (peso {k.peso}) — {k.descricao}</Painel>)}
              {d.pode_editar && <><p className="mt-2 text-sm font-bold">Novo critério</p><CriterioForm novo aoSalvar={recarregar} /></>}
            </div>
          </Secao>
        </>
      )}
    </>
  );
}
