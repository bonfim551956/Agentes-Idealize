import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import * as Dialog from "@radix-ui/react-dialog";
import { ExternalLink, Pencil, Plus, X } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc } from "../lib/api";
import { data, relativo, rotuloUnidade } from "../lib/format";
import { traduzir } from "../lib/erros";
import { Botao, Cabecalho, Campo, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Vazio, cx, entradaCls } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

type Anuncio = { id: string; titulo: string | null; page_nome: string | null; inicio: string | null; dias: number | null; link: string | null; novo: boolean };
type Concorrente = { id: number; nome: string; praca: string | null; unidade_id: string | null; instagram: string | null; termo_busca: string | null;
  page_ids: string[]; observacao: string | null; ativo: boolean; anuncios_ativos: number; anuncios_novos_7d: number; anuncios: Anuncio[] };
type Noticia = { id: number; dia: string; titulo: string; fonte: string | null; url: string; resumo: string | null; impacto: string | null; tema: string | null; relevancia: number };
type Ideia = { id: number; titulo: string; evidencia: string | null; como_aplicar: string | null; link: string | null; status: string;
  nota: string | null; criado_em: string; decidido_em: string | null; concorrente: string | null };
type Intel = { pode_editar: boolean; anuncio_longo_dias: number; ultima_varredura: Record<string, string> | null;
  concorrentes: Concorrente[]; noticias: Noticia[]; ideias: Ideia[] };

const ABAS = [["concorrentes", "Concorrentes"], ["ideias", "Ideias para aplicar"], ["noticias", "Notícias do mercado"]] as const;
const STATUS_IDEIA: Record<string, { rotulo: string; tom: "neutro" | "lente" | "ok" | "atencao" }> = {
  sugerida: { rotulo: "Para decidir", tom: "atencao" }, aprovada: { rotulo: "Aprovada", tom: "lente" },
  feita: { rotulo: "Feita", tom: "ok" }, descartada: { rotulo: "Descartada", tom: "neutro" },
};

function Formulario({ c, aoFechar }: { c: Concorrente | null; aoFechar: () => void }) {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [f, setF] = useState({
    nome: c?.nome ?? "", praca: c?.praca ?? "", unidade: c?.unidade_id ?? "", instagram: c?.instagram ?? "",
    termo: c?.termo_busca ?? "", paginas: (c?.page_ids ?? []).join(", "), observacao: c?.observacao ?? "", ativo: c?.ativo ?? true,
  });
  const [erro, setErro] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  const muda = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  async function salvar() {
    setEnviando(true); setErro(null);
    try {
      await rpc("painel_concorrente_salvar", {
        p_id: c?.id ?? null, p_nome: f.nome, p_praca: f.praca || null, p_unidade: f.unidade || null, p_instagram: f.instagram || null,
        p_termo: f.termo || null, p_page_ids: f.paginas.split(/[\s,;]+/).filter(Boolean), p_observacao: f.observacao || null, p_ativo: f.ativo,
      });
      await qc.invalidateQueries({ queryKey: ["inteligencia"] });
      aoFechar();
    } catch (e) { setErro(traduzir(e).message); } finally { setEnviando(false); }
  }
  return (
    <div className="flex flex-col gap-4">
      <Campo id="c-nome" rotulo="Nome do concorrente"><input id="c-nome" className={entradaCls} value={f.nome} onChange={muda("nome")} /></Campo>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Campo id="c-praca" rotulo="Cidade ou região" ajuda="Onde ele disputa com vocês."><input id="c-praca" className={entradaCls} value={f.praca} onChange={muda("praca")} /></Campo>
        <Campo id="c-loja" rotulo="Loja Idealize que disputa com ele">
          <select id="c-loja" className={entradaCls} value={f.unidade} onChange={muda("unidade")}>
            <option value="">Nenhuma em especial</option>
            {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
          </select>
        </Campo>
        <Campo id="c-ig" rotulo="Instagram" ajuda="Só o @ (ex.: oticas.exemplo)."><input id="c-ig" className={entradaCls} value={f.instagram} onChange={muda("instagram")} /></Campo>
        <Campo id="c-termo" rotulo="Como buscar nos anúncios" ajuda="Em branco, usa o nome."><input id="c-termo" className={entradaCls} value={f.termo} onChange={muda("termo")} /></Campo>
      </div>
      <Campo id="c-pag" rotulo="Páginas do Facebook confirmadas" ajuda="Números das páginas, separados por vírgula. Com páginas, o agente lê só elas; sem, busca pelo termo.">
        <input id="c-pag" className={entradaCls} value={f.paginas} onChange={muda("paginas")} />
      </Campo>
      <Campo id="c-obs" rotulo="Observação"><input id="c-obs" className={entradaCls} value={f.observacao} onChange={muda("observacao")} /></Campo>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" className="h-4 w-4" checked={f.ativo} onChange={(e) => setF({ ...f, ativo: e.target.checked })} /> Acompanhar este concorrente</label>
      {erro && <p role="alert" className="text-sm font-bold text-critico">{erro}</p>}
      <div className="flex justify-end gap-2">
        <Botao variante="fantasma" onClick={aoFechar}>Cancelar</Botao>
        <Botao variante="primario" carregando={enviando} disabled={f.nome.trim().length < 2} onClick={salvar}>Salvar</Botao>
      </div>
    </div>
  );
}

function Editar({ c, gatilho }: { c: Concorrente | null; gatilho: React.ReactNode }) {
  const [aberto, setAberto] = useState(false);
  return (
    <Dialog.Root open={aberto} onOpenChange={setAberto}>
      <Dialog.Trigger asChild>{gatilho}</Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-tinta/40" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-50 max-h-[90vh] w-[min(640px,calc(100vw-32px))] -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-grande bg-superficie p-6 shadow-lg">
          <div className="mb-4 flex items-center justify-between">
            <Dialog.Title className="text-lg font-bold">{c ? `Editar ${c.nome}` : "Incluir concorrente"}</Dialog.Title>
            <Dialog.Close asChild><button className="rounded-medio p-2 hover:bg-elevada" aria-label="Fechar"><X className="h-5 w-5" /></button></Dialog.Close>
          </div>
          <Dialog.Description className="sr-only">Dados que o agente usa para acompanhar o concorrente.</Dialog.Description>
          <Formulario c={c} aoFechar={() => setAberto(false)} />
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export function Mercado() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [aba, setAba] = useState<(typeof ABAS)[number][0]>("concorrentes");
  const [aberto, setAberto] = useState<number | null>(null);
  const q = useQuery({ queryKey: ["inteligencia"], queryFn: () => rpc<Intel>("painel_inteligencia"), enabled: eu.pode.consultar_global });
  const concluir = () => { void qc.invalidateQueries(); };

  if (!eu.pode.consultar_global) return <Vazio titulo="Mercado e concorrentes">Esta tela fica com a diretoria.</Vazio>;
  const d = q.data;
  const pendentes = d?.ideias.filter((i) => i.status === "sugerida").length ?? 0;
  return (
    <>
      <Cabecalho titulo="Mercado e concorrentes"
        descricao={d ? `Radar do Mercado: ${d.ultima_varredura?.radar ? relativo(d.ultima_varredura.radar) : "ainda não rodou"} · Concorrentes: ${d.ultima_varredura?.concorrentes ? relativo(d.ultima_varredura.concorrentes) : "ainda não rodou"}` : undefined}
        acoes={d?.pode_editar && aba === "concorrentes" ? (
          <Editar c={null} gatilho={<Botao variante="primario" tamanho="sm" icone={<Plus className="h-4 w-4" aria-hidden />}>Incluir concorrente</Botao>} />
        ) : undefined} />
      <div role="tablist" aria-label="Seções" className="mb-6 flex flex-wrap gap-2">
        {ABAS.map(([k, r]) => (
          <button key={k} role="tab" aria-selected={aba === k} onClick={() => setAba(k)}
            className={cx("rounded-medio border px-4 py-2 text-sm", aba === k ? "border-lente bg-lente-clara font-bold text-lente" : "border-linha hover:bg-elevada")}>
            {r}{k === "ideias" && pendentes > 0 && ` (${pendentes})`}
          </button>
        ))}
      </div>
      {q.isLoading ? <Carregando linhas={8} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !d ? null : aba === "concorrentes" ? (
        <ul className="flex flex-col gap-2">
          {d.concorrentes.map((c) => (
            <li key={c.id}>
              <Painel className={cx("p-4", !c.ativo && "opacity-60")}>
                <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="text-base font-bold">{c.nome}</h2>
                      {!c.ativo && <Etiqueta>não acompanhado</Etiqueta>}
                      {c.anuncios_novos_7d > 0 && <Etiqueta tom="critico">{c.anuncios_novos_7d} novos em 7 dias</Etiqueta>}
                    </div>
                    <p className="mt-1 text-sm text-suave">
                      {[c.praca, c.unidade_id && `disputa com ${rotuloUnidade(c.unidade_id, eu.unidades)}`, c.instagram && `@${c.instagram}`].filter(Boolean).join(" · ") || "sem cidade definida"}
                      {" · "}{c.anuncios_ativos} {c.anuncios_ativos === 1 ? "anúncio no ar" : "anúncios no ar"}
                    </p>
                    {c.observacao && <p className="mt-1 text-sm text-atencao">{c.observacao}</p>}
                  </div>
                  <div className="flex shrink-0 gap-2">
                    {c.anuncios.length > 0 && <Botao tamanho="sm" onClick={() => setAberto(aberto === c.id ? null : c.id)}>{aberto === c.id ? "Esconder anúncios" : "Ver anúncios"}</Botao>}
                    {d.pode_editar && <Editar c={c} gatilho={<Botao tamanho="sm" icone={<Pencil className="h-4 w-4" aria-hidden />}>Editar</Botao>} />}
                  </div>
                </div>
                {aberto === c.id && (
                  <ul className="mt-4 flex flex-col divide-y divide-linha border-t border-linha">
                    {c.anuncios.map((a) => (
                      <li key={a.id} className="flex flex-wrap items-center gap-2 py-2 text-sm">
                        {a.novo && <Etiqueta tom="critico">novo</Etiqueta>}
                        {a.dias != null && a.dias >= d.anuncio_longo_dias && <Etiqueta tom="atencao">{a.dias} dias no ar</Etiqueta>}
                        <span className="font-bold">{a.titulo || "(sem título)"}</span>
                        <span className="text-suave">{a.page_nome}{a.inicio && ` · desde ${data(a.inicio)}`}</span>
                        {a.link && <a href={a.link} target="_blank" rel="noopener noreferrer" className="font-bold text-lente hover:underline">ver <ExternalLink className="inline h-3 w-3" aria-hidden /></a>}
                      </li>
                    ))}
                  </ul>
                )}
              </Painel>
            </li>
          ))}
        </ul>
      ) : aba === "ideias" ? (
        d.ideias.length === 0 ? <Vazio titulo="Nenhuma ideia ainda">O agente de Concorrentes sugere ideias depois das primeiras varreduras.</Vazio> : (
          <ul className="flex flex-col gap-2">
            {d.ideias.map((i) => {
              const s = STATUS_IDEIA[i.status];
              return (
                <li key={i.id}>
                  <Painel className="flex flex-col gap-3 p-4 md:flex-row md:items-start md:justify-between">
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2"><Etiqueta tom={s?.tom}>{s?.rotulo ?? i.status}</Etiqueta><h2 className="text-base font-bold">{i.titulo}</h2></div>
                      {i.concorrente && <p className="mt-1 text-sm text-suave">Visto em: {i.concorrente}</p>}
                      {i.evidencia && <p className="mt-1 text-sm"><b>Por que parece funcionar:</b> {i.evidencia}</p>}
                      {i.como_aplicar && <p className="mt-1 text-sm"><b>Como aplicar na Idealize:</b> {i.como_aplicar}</p>}
                      {i.nota && <p className="mt-1 text-sm text-suave">Nota: {i.nota}</p>}
                      {i.link && <a href={i.link} target="_blank" rel="noopener noreferrer" className="text-sm font-bold text-lente hover:underline">Ver exemplo <ExternalLink className="inline h-3 w-3" aria-hidden /></a>}
                    </div>
                    {d.pode_editar && (
                      <div className="flex shrink-0 flex-wrap gap-2">
                        {i.status === "sugerida" && (
                          <>
                            <Confirmar gatilho={<Botao tamanho="sm" variante="primario">Aprovar</Botao>} titulo="Aprovar esta ideia?" rotuloConfirmar="Aprovar"
                              descricao="Ela vai para a lista de ideias aprovadas, para a equipe executar." motivo={{ rotulo: "Observação (opcional)", minimo: 0, obrigatorio: false }}
                              aoConfirmar={(m) => rpc("painel_ideia_decidir", { p_id: i.id, p_status: "aprovada", p_nota: m || null })} aoConcluir={concluir} />
                            <Confirmar gatilho={<Botao tamanho="sm">Descartar</Botao>} titulo="Descartar esta ideia?" rotuloConfirmar="Descartar"
                              descricao="Ela sai da lista de pendentes." motivo={{ rotulo: "Motivo (opcional)", minimo: 0, obrigatorio: false }}
                              aoConfirmar={(m) => rpc("painel_ideia_decidir", { p_id: i.id, p_status: "descartada", p_nota: m || null })} aoConcluir={concluir} />
                          </>
                        )}
                        {i.status === "aprovada" && (
                          <Confirmar gatilho={<Botao tamanho="sm" variante="primario">Marcar como feita</Botao>} titulo="A ideia já foi colocada em prática?" rotuloConfirmar="Marcar como feita"
                            descricao="Fica registrada como feita, com a data." motivo={{ rotulo: "Como ficou (opcional)", minimo: 0, obrigatorio: false }}
                            aoConfirmar={(m) => rpc("painel_ideia_decidir", { p_id: i.id, p_status: "feita", p_nota: m || null })} aoConcluir={concluir} />
                        )}
                      </div>
                    )}
                  </Painel>
                </li>
              );
            })}
          </ul>
        )
      ) : (
        d.noticias.length === 0 ? <Vazio titulo="Nenhuma notícia ainda">O Radar do Mercado roda todo dia às 6h.</Vazio> : (
          <Secao titulo="Últimas notícias">
            <Painel className="divide-y divide-linha">
              {d.noticias.map((n) => (
                <div key={n.id} className="p-4 text-sm">
                  <p className="text-xs text-suave">{data(n.dia)}{n.tema && ` · ${n.tema}`}{n.fonte && ` · ${n.fonte}`}</p>
                  <a href={n.url} target="_blank" rel="noopener noreferrer" className="font-bold hover:underline">{n.titulo} <ExternalLink className="inline h-3 w-3" aria-hidden /></a>
                  {n.resumo && <p className="mt-1">{n.resumo}</p>}
                  {n.impacto && <p className="mt-1 text-suave"><b>O que muda para a Idealize:</b> {n.impacto}</p>}
                </div>
              ))}
            </Painel>
          </Secao>
        )
      )}
    </>
  );
}
