import { useState } from "react";
import { Link } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ExternalLink, RefreshCw } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc } from "../lib/api";
import { data, dataHora, numero } from "../lib/format";
import { traduzir } from "../lib/erros";
import { Botao, Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Vazio, cx, entradaCls } from "../ui/base";

type Prioridade = { area: string; unidade: string | null; texto: string; rota: string; peso: number };
type AgenteDia = { id: string; nome: string; status: string; rodadas: number; falhas: number; novos: number; abertos: number;
  rotulo_novos: string; rotulo_abertos: string };
type Noticia = { titulo: string; fonte: string | null; url: string; impacto: string | null; tema: string | null; relevancia: number };
type AnuncioRel = { concorrente: string; praca: string | null; titulo: string | null; inicio?: string | null; dias?: number; link: string | null };
type IdeiaRel = { id: number; titulo: string; evidencia: string | null; como_aplicar: string | null; link: string | null; concorrente: string | null };
type Conteudo = {
  dia: string; gerado_em: string;
  totais: { agentes: number; rodadas: number; falhas: number; ideias: number };
  prioridades: Prioridade[]; agentes: AgenteDia[]; mercado: Noticia[];
  concorrentes: { novos: AnuncioRel[]; longos: AnuncioRel[]; ideias: IdeiaRel[] };
};
type Rel = { dia: string; existe: boolean; versao: number | null; conteudo: Conteudo | null; pode_gerar: boolean; dias: string[] };

const urgente = (area: string) => ["Plataforma", "Concorrentes", "Financeiro", "Caixa"].includes(area);

function Numero({ valor, rotulo }: { valor: number; rotulo: string }) {
  return (
    <Painel className="p-4">
      <p className="text-2xl font-bold">{numero(valor)}</p>
      <p className="text-xs text-suave">{rotulo}</p>
    </Painel>
  );
}

export function Relatorio() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [dia, setDia] = useState<string>("");
  const [gerando, setGerando] = useState(false);
  const [erroGerar, setErroGerar] = useState<string | null>(null);
  const q = useQuery({ queryKey: ["relatorio", dia], queryFn: () => rpc<Rel>("painel_relatorio", { p_dia: dia || null }),
    enabled: eu.pode.consultar_global, refetchInterval: 120_000 });

  if (!eu.pode.consultar_global)
    return <Vazio titulo="Relatório da rede">O relatório do dia mostra todas as lojas e fica com a diretoria.</Vazio>;

  async function gerar() {
    setGerando(true); setErroGerar(null);
    try { await rpc("painel_relatorio_gerar"); setDia(""); await qc.invalidateQueries({ queryKey: ["relatorio"] }); }
    catch (e) { setErroGerar(traduzir(e).message); } finally { setGerando(false); }
  }

  const r = q.data;
  const c = r?.conteudo ?? null;
  return (
    <>
      <Cabecalho titulo="Relatório do dia"
        descricao={c ? `${data(c.dia)} · gerado às ${dataHora(c.gerado_em).slice(-5)} com a varredura das últimas 24 horas` : "Prioridades, o que cada agente fez, mercado e concorrentes."}
        acoes={
          <div className="flex flex-wrap items-center gap-2">
            {r && r.dias.length > 0 && (
              <>
                <label className="sr-only" htmlFor="rel-dia">Dia do relatório</label>
                <select id="rel-dia" className={entradaCls + " w-auto"} value={dia || r.dia} onChange={(e) => setDia(e.target.value === r.dias[0] ? "" : e.target.value)}>
                  {r.dias.map((d) => <option key={d} value={d}>{data(d)}</option>)}
                </select>
              </>
            )}
            {r?.pode_gerar && !dia && (
              <Botao tamanho="sm" icone={<RefreshCw className="h-4 w-4" aria-hidden />} carregando={gerando} onClick={gerar}>Atualizar agora</Botao>
            )}
          </div>
        } />
      {erroGerar && <p role="alert" className="mb-4 text-sm font-bold text-critico">{erroGerar}</p>}
      {q.isLoading ? <Carregando linhas={8} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !c ? (
        <Vazio titulo="Sem relatório nesse dia">O relatório é montado todo dia às 7h.</Vazio>
      ) : (
        <>
          <div className="mb-8 grid grid-cols-2 gap-4 lg:grid-cols-4">
            <Numero valor={c.totais.agentes} rotulo="agentes trabalhando" />
            <Numero valor={c.totais.rodadas} rotulo={`varreduras em 24 h, ${c.totais.falhas} ${c.totais.falhas === 1 ? "falha" : "falhas"}`} />
            <Numero valor={c.prioridades.length} rotulo="prioridades para hoje" />
            <Numero valor={c.totais.ideias} rotulo="ideias dos concorrentes para aprovar" />
          </div>

          <Secao titulo="Prioridades de hoje">
            {c.prioridades.length === 0 ? <Vazio titulo="Nada urgente hoje">Os agentes não encontraram nada que precise da sua decisão.</Vazio> : (
              <ol className="flex flex-col gap-2">
                {c.prioridades.map((p, i) => (
                  <li key={i}>
                    <Painel className="flex items-start gap-3 p-4">
                      <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-lente text-xs font-bold text-superficie">{i + 1}</span>
                      <p className="flex-1 text-sm">
                        <Etiqueta tom={urgente(p.area) ? "critico" : "lente"} className="mr-2">{p.area}{p.unidade && ` · ${p.unidade}`}</Etiqueta>
                        {p.texto}{" "}
                        <Link to={p.rota} className="whitespace-nowrap font-bold text-lente hover:underline">Ver →</Link>
                      </p>
                    </Painel>
                  </li>
                ))}
              </ol>
            )}
          </Secao>

          <Secao titulo="O que cada agente fez nas últimas 24 horas">
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
              {c.agentes.map((a) => (
                <Painel key={a.id} className={cx("p-4", (a.id === "radar" || a.id === "concorrentes") && "border-2 border-lente")}>
                  <div className="flex items-center justify-between gap-2">
                    <h3 className="font-bold">{a.nome}</h3>
                    {a.status !== "ativo" && <Etiqueta>{a.status}</Etiqueta>}
                  </div>
                  <p className="mt-1 text-xs text-suave">{a.rodadas} {a.rodadas === 1 ? "rodada" : "rodadas"}{a.falhas > 0 && `, ${a.falhas} com falha`}</p>
                  <p className={cx("text-xs font-bold", a.falhas > 0 ? "text-critico" : a.novos > 0 ? "text-atencao" : "text-ok")}>
                    {a.novos > 0 ? `${a.novos} ${a.rotulo_novos}` : "sem novidade"}
                  </p>
                  {a.rotulo_abertos && a.abertos > 0 && <p className="text-xs text-suave">{a.abertos} {a.rotulo_abertos}</p>}
                </Painel>
              ))}
            </div>
          </Secao>

          <div className="grid grid-cols-1 gap-x-8 lg:grid-cols-2">
            <Secao titulo="Mercado hoje" descricao="O que o Radar do Mercado achou nas últimas 24 horas.">
              {c.mercado.length === 0 ? <Vazio titulo="Sem notícias novas">O Radar roda todo dia às 6h.</Vazio> : (
                <Painel className="divide-y divide-linha">
                  {c.mercado.map((n) => (
                    <div key={n.url} className="p-4 text-sm">
                      <a href={n.url} target="_blank" rel="noopener noreferrer" className="font-bold hover:underline">{n.titulo} <ExternalLink className="inline h-3 w-3" aria-hidden /></a>
                      {n.fonte && <span className="text-suave"> · {n.fonte}</span>}
                      {n.impacto && <p className="mt-1 text-suave"><b>O que muda para a Idealize:</b> {n.impacto}</p>}
                    </div>
                  ))}
                </Painel>
              )}
            </Secao>
            <Secao titulo="Concorrentes: o que mudou" descricao={<Link to="/mercado" className="text-lente hover:underline">Ver todos os concorrentes →</Link>}>
              {c.concorrentes.novos.length + c.concorrentes.longos.length + c.concorrentes.ideias.length === 0 ? (
                <Vazio titulo="Sem novidade dos concorrentes">O agente varre os anúncios todo dia às 6h15.</Vazio>
              ) : (
                <Painel className="divide-y divide-linha">
                  {c.concorrentes.novos.map((a, i) => (
                    <div key={`n${i}`} className="p-4 text-sm">
                      <Etiqueta tom="critico" className="mr-2">novo</Etiqueta><b>{a.concorrente}</b>{a.titulo && ` · "${a.titulo}"`}
                      {a.inicio && <span className="text-suave"> · no ar desde {data(a.inicio)}</span>}
                      {a.link && <> · <a href={a.link} target="_blank" rel="noopener noreferrer" className="font-bold text-lente hover:underline">ver anúncio</a></>}
                    </div>
                  ))}
                  {c.concorrentes.longos.slice(0, 5).map((a, i) => (
                    <div key={`l${i}`} className="p-4 text-sm">
                      <Etiqueta tom="atencao" className="mr-2">{a.dias} dias no ar</Etiqueta><b>{a.concorrente}</b>{a.titulo && ` · "${a.titulo}"`}
                      <p className="mt-1 text-xs text-suave">Anúncio que roda há muito tempo costuma estar dando resultado.</p>
                    </div>
                  ))}
                  {c.concorrentes.ideias.map((x) => (
                    <div key={`i${x.id}`} className="p-4 text-sm">
                      <Etiqueta tom="ok" className="mr-2">ideia</Etiqueta><b>{x.titulo}</b>
                      {x.como_aplicar && <p className="mt-1 text-suave">{x.como_aplicar}</p>}
                      <Link to="/mercado" className="text-xs font-bold text-lente hover:underline">Aprovar ou descartar →</Link>
                    </div>
                  ))}
                </Painel>
              )}
            </Secao>
          </div>
        </>
      )}
    </>
  );
}
