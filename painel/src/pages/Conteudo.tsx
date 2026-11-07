import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import * as Dialog from "@radix-ui/react-dialog";
import { Check, ChevronDown, ChevronUp, Copy, ExternalLink, X } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc } from "../lib/api";
import { data, relativo, type Tom } from "../lib/format";
import { traduzir } from "../lib/erros";
import { Botao, Cabecalho, Campo, Carregando, ErroCaixa, Etiqueta, Painel, Vazio, cx, entradaCls } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

type Criterios = { gancho: number; prova: number; oferta: number; gravacao: number; marca: number };
type Cena = { tempo?: string; tipo?: string; aparece?: string; fala?: string; tela?: string };
type Roteiro = {
  id: number; ideia_id: number | null; dia: string; titulo: string; formato: string; unidade_id: string | null; loja: string | null;
  duracao_s: number | null; gancho: string; cenas: Cena[]; capa: string | null; trilha: string | null; legenda: string | null; cta: string | null;
  observacoes: string | null; status: string; pedido_ajuste: string | null; versao: number; nota_diego: string | null; link: string | null;
  anuncio_nome: string | null; decidido_em: string | null; atualizado_em: string;
  nota: number | null; criterios: Criterios | null; parecer: string | null; evidencia: string | null;
};
type Ideia = { id: number; titulo: string; formato: string; loja: string | null; gancho: string | null; conceito: string | null; evidencia: string | null;
  fonte: string | null; status: string; nota: number | null; criterios: Criterios | null; parecer: string | null; roteiro_id: number | null };
type Agente = { id: string; nome: string; status: string; ultima: string | null; resumo: Record<string, number> | null; falhou_hoje: boolean };
type Regras = { ideias_por_dia: number; nota_minima: number; roteiros_por_dia: number; formatos: string[]; foco: string; ofertas: string;
  tom: string; rosto: string; proibido: string; ativos: { ideias: boolean; avaliador: boolean; roteirista: boolean } };
type Dados = { dia: string; pode_editar: boolean; dias: string[]; agentes: Agente[]; roteiros: Roteiro[]; ideias: Ideia[]; producao: Roteiro[]; regras: Regras };

const ABAS = [["roteiros", "Roteiros"], ["ideias", "Ideias avaliadas"], ["producao", "Gravados e publicados"], ["regras", "Regras dos agentes"]] as const;
const STATUS: Record<string, { rotulo: string; tom: Tom }> = {
  pronto: { rotulo: "Para aprovar", tom: "atencao" }, ajuste: { rotulo: "Em ajuste", tom: "atencao" }, aprovado: { rotulo: "Aprovado para gravar", tom: "lente" },
  gravado: { rotulo: "Gravado", tom: "lente" }, publicado: { rotulo: "Publicado", tom: "ok" }, descartado: { rotulo: "Descartado", tom: "neutro" },
};
const FORMATO: Record<string, string> = { reel: "Reel", carrossel: "Carrossel", stories: "Stories", imagem: "Imagem" };
const CRITERIOS: [keyof Criterios, string][] = [["gancho", "gancho"], ["prova", "prova"], ["oferta", "oferta clara"], ["gravacao", "fácil de gravar"], ["marca", "cara da Idealize"]];
const HORARIO: Record<string, string> = { conteudo_ideias: "6h25", conteudo_avaliador: "logo depois", conteudo_roteirista: "logo depois" };

function resumoAgente(a: Agente) {
  const r = a.resumo ?? {};
  if (a.id === "conteudo_ideias") return `${r.ideias ?? 0} ideias`;
  if (a.id === "conteudo_avaliador") return `${r.aprovadas ?? 0} aprovadas, ${r.descartadas ?? 0} descartadas`;
  return `${r.roteiros ?? 0} roteiros${r.ajustes ? `, ${r.ajustes} ajustes` : ""}`;
}

function Nota({ nota, criterios }: { nota: number | null; criterios: Criterios | null }) {
  if (nota == null) return null;
  return (
    <p className="text-sm text-suave">
      Nota do Avaliador <b className="text-lente">{nota}/100</b>
      {criterios && CRITERIOS.map(([k, r]) => <span key={k}> · {r} {criterios[k]}/20</span>)}
    </p>
  );
}

function textoParaCopiar(r: Roteiro) {
  const l = [`${r.titulo}`, `${FORMATO[r.formato] ?? r.formato}${r.duracao_s ? ` · ${r.duracao_s} s` : ""}${r.loja ? ` · ${r.loja}` : ""}`, "", `GANCHO: ${r.gancho}`, ""];
  r.cenas.forEach((c, i) => {
    l.push(`CENA ${i + 1}${c.tempo ? ` (${c.tempo})` : ""}${c.tipo ? ` — ${c.tipo.toUpperCase()}` : ""}`);
    if (c.aparece) l.push(`O que aparece: ${c.aparece}`);
    if (c.fala) l.push(`Fala: ${c.fala}`);
    if (c.tela) l.push(`Texto na tela: ${c.tela}`);
    l.push("");
  });
  if (r.capa) l.push(`CAPA: ${r.capa}`);
  if (r.trilha) l.push(`TRILHA: ${r.trilha}`);
  if (r.cta) l.push(`CTA: ${r.cta}`);
  if (r.observacoes) l.push(`GRAVAÇÃO: ${r.observacoes}`);
  if (r.legenda) l.push("", "LEGENDA:", r.legenda);
  return l.join("\n");
}

function Publicar({ r, aoConcluir }: { r: Roteiro; aoConcluir: () => void }) {
  const [aberto, setAberto] = useState(false);
  const [link, setLink] = useState(r.link ?? "");
  const [anuncio, setAnuncio] = useState(r.anuncio_nome ?? "");
  const [erro, setErro] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  async function salvar() {
    setEnviando(true); setErro(null);
    try {
      await rpc("painel_roteiro_decidir", { p_id: r.id, p_acao: "publicado", p_texto: null, p_link: link || null, p_anuncio: anuncio || null });
      setAberto(false); aoConcluir();
    } catch (e) { setErro(traduzir(e).message); } finally { setEnviando(false); }
  }
  return (
    <Dialog.Root open={aberto} onOpenChange={setAberto}>
      <Dialog.Trigger asChild><Botao tamanho="sm" variante="primario">{r.status === "publicado" ? "Editar publicação" : "Marcar publicado"}</Botao></Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-tinta/40" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-50 w-[min(560px,calc(100vw-32px))] -translate-x-1/2 -translate-y-1/2 rounded-grande bg-superficie p-6 shadow-lg">
          <div className="mb-4 flex items-center justify-between">
            <Dialog.Title className="text-lg font-bold">Publicado</Dialog.Title>
            <Dialog.Close asChild><button className="rounded-medio p-2 hover:bg-elevada" aria-label="Fechar"><X className="h-5 w-5" /></button></Dialog.Close>
          </div>
          <Dialog.Description className="mb-4 text-sm text-suave">
            Com o nome do anúncio, o sistema passa a ligar este roteiro ao custo por conversa no Meta. Assim os agentes aprendem o que vende.
          </Dialog.Description>
          <div className="flex flex-col gap-4">
            <Campo id="p-link" rotulo="Link do post (opcional)"><input id="p-link" className={entradaCls} placeholder="https://www.instagram.com/reel/..." value={link} onChange={(e) => setLink(e.target.value)} /></Campo>
            <Campo id="p-anuncio" rotulo="Nome do anúncio no Meta (opcional)" ajuda='Use um nome que diga o criativo, ex.: "SV – Reel 2 óculos – influencer".'>
              <input id="p-anuncio" className={entradaCls} value={anuncio} onChange={(e) => setAnuncio(e.target.value)} />
            </Campo>
            {erro && <p role="alert" className="text-sm font-bold text-critico">{erro}</p>}
            <div className="flex justify-end gap-2">
              <Botao variante="fantasma" onClick={() => setAberto(false)}>Cancelar</Botao>
              <Botao variante="primario" carregando={enviando} onClick={salvar}>Salvar</Botao>
            </div>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function RoteiroCard({ r, podeEditar, aberto: abertoInicial }: { r: Roteiro; podeEditar: boolean; aberto: boolean }) {
  const qc = useQueryClient();
  const [aberto, setAberto] = useState(abertoInicial);
  const [copiado, setCopiado] = useState(false);
  const s = STATUS[r.status];
  const concluir = () => { void qc.invalidateQueries({ queryKey: ["conteudo"] }); };
  const decidir = (acao: string) => (m: string) => rpc("painel_roteiro_decidir", { p_id: r.id, p_acao: acao, p_texto: m || null });
  async function copiar() {
    try { await navigator.clipboard.writeText(textoParaCopiar(r)); setCopiado(true); setTimeout(() => setCopiado(false), 2000); } catch { /* sem área de transferência */ }
  }
  return (
    <Painel className="p-4 md:p-6">
      <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <Etiqueta tom={s?.tom}>{s?.rotulo ?? r.status}</Etiqueta>
            <Etiqueta>{FORMATO[r.formato] ?? r.formato}{r.duracao_s ? ` · ${r.duracao_s} s` : ""} · {r.loja ?? "todas as lojas"}</Etiqueta>
            {r.versao > 1 && <Etiqueta tom="lente">versão {r.versao}</Etiqueta>}
          </div>
          <h2 className="mt-2 text-lg font-bold leading-tight md:text-xl">{r.titulo}</h2>
          <Nota nota={r.nota} criterios={r.criterios} />
          {r.evidencia && <p className="text-sm text-suave"><b>Evidência:</b> {r.evidencia}</p>}
          {r.status === "ajuste" && r.pedido_ajuste && <p className="mt-1 text-sm text-atencao"><b>Você pediu:</b> {r.pedido_ajuste}. O Roteirista refaz na próxima rodada (13h ou na manhã seguinte).</p>}
          {r.nota_diego && <p className="mt-1 text-sm text-suave"><b>Sua nota:</b> {r.nota_diego}</p>}
          {(r.link || r.anuncio_nome) && (
            <p className="mt-1 text-sm text-suave">
              {r.anuncio_nome && <>Anúncio: <b>{r.anuncio_nome}</b> </>}
              {r.link && <a href={r.link} target="_blank" rel="noopener noreferrer" className="font-bold text-lente hover:underline">ver post <ExternalLink className="inline h-3 w-3" aria-hidden /></a>}
            </p>
          )}
        </div>
        <div className="flex shrink-0 flex-wrap gap-2">
          {podeEditar && r.status === "pronto" && (
            <>
              <Confirmar gatilho={<Botao tamanho="sm" variante="primario">Aprovar para gravar</Botao>} titulo="Aprovar este roteiro?" rotuloConfirmar="Aprovar"
                descricao="Ele vai para a lista de gravação. O que você aprova ensina os agentes." motivo={{ rotulo: "O que gostou (opcional)", minimo: 0, obrigatorio: false }}
                aoConfirmar={decidir("aprovar")} aoConcluir={concluir} />
              <Confirmar gatilho={<Botao tamanho="sm">Pedir ajuste</Botao>} titulo="O que precisa mudar?" rotuloConfirmar="Pedir ajuste"
                descricao="O Roteirista refaz o roteiro com o seu pedido e ele volta para você aprovar." motivo={{ rotulo: "Pedido de ajuste", minimo: 5, ajuda: "Ex.: troque o gancho, comece pela etiqueta; deixe com 20 segundos." }}
                aoConfirmar={decidir("ajuste")} aoConcluir={concluir} />
              <Confirmar gatilho={<Botao tamanho="sm" variante="fantasma">Descartar</Botao>} titulo="Descartar este roteiro?" rotuloConfirmar="Descartar"
                descricao="O motivo ajuda os agentes a não repetir." motivo={{ rotulo: "Motivo (opcional)", minimo: 0, obrigatorio: false }}
                aoConfirmar={decidir("descartar")} aoConcluir={concluir} />
            </>
          )}
          {podeEditar && r.status === "aprovado" && (
            <Confirmar gatilho={<Botao tamanho="sm">Marcar gravado</Botao>} titulo="Já foi gravado?" rotuloConfirmar="Marcar gravado" descricao="Fica registrado com a data."
              aoConfirmar={decidir("gravado")} aoConcluir={concluir} />
          )}
          {podeEditar && ["aprovado", "gravado", "publicado"].includes(r.status) && <Publicar r={r} aoConcluir={concluir} />}
          {podeEditar && ["descartado", "ajuste"].includes(r.status) && (
            <Confirmar gatilho={<Botao tamanho="sm" variante="fantasma">Voltar para aprovação</Botao>} titulo="Voltar este roteiro para aprovação?" rotuloConfirmar="Voltar"
              descricao="Ele volta para a lista do dia, do jeito que está." aoConfirmar={decidir("voltar")} aoConcluir={concluir} />
          )}
          <Botao tamanho="sm" variante="fantasma" icone={copiado ? <Check className="h-4 w-4" aria-hidden /> : <Copy className="h-4 w-4" aria-hidden />} onClick={copiar}>
            {copiado ? "Copiado" : "Copiar roteiro"}
          </Botao>
          <Botao tamanho="sm" variante="fantasma" aria-expanded={aberto} icone={aberto ? <ChevronUp className="h-4 w-4" aria-hidden /> : <ChevronDown className="h-4 w-4" aria-hidden />}
            onClick={() => setAberto(!aberto)}>{aberto ? "Esconder" : "Ver roteiro"}</Botao>
        </div>
      </div>

      {aberto && (
        <>
          <p className="mt-4 rounded-medio bg-lente-clara p-3 text-sm text-lente"><b>Gancho (3 primeiros segundos):</b> {r.gancho}</p>
          <div className="mt-4" role="table" aria-label="Cenas do roteiro">
            <div role="row" className="hidden border-b border-linha pb-2 text-xs font-bold text-suave md:grid md:grid-cols-[96px_1fr_1fr_1fr] md:gap-4">
              <span role="columnheader">Tempo</span><span role="columnheader">O que aparece</span><span role="columnheader">O que se fala</span><span role="columnheader">Texto na tela</span>
            </div>
            {r.cenas.map((c, i) => (
              <div role="row" key={i} className="grid grid-cols-1 gap-1 border-b border-linha py-3 text-sm md:grid-cols-[96px_1fr_1fr_1fr] md:gap-4">
                <span role="cell" className="font-bold">
                  <span className={cx(i === 0 && "text-lente")}>{c.tempo ?? `Cena ${i + 1}`}</span>
                  {c.tipo && <span className="block text-xs uppercase text-suave">{c.tipo}</span>}
                </span>
                <span role="cell"><span className="text-xs font-bold text-suave md:hidden">Aparece: </span>{c.aparece}</span>
                <span role="cell"><span className="text-xs font-bold text-suave md:hidden">Fala: </span>{c.fala && `"${c.fala}"`}</span>
                <span role="cell" className="font-bold"><span className="text-xs font-bold text-suave md:hidden">Na tela: </span>{c.tela}</span>
              </div>
            ))}
          </div>
          <div className="mt-4 grid grid-cols-1 gap-4 text-sm md:grid-cols-3">
            {r.capa && <div><p className="text-xs font-bold text-suave">CAPA</p><p>{r.capa}</p></div>}
            {r.trilha && <div><p className="text-xs font-bold text-suave">TRILHA</p><p>{r.trilha}</p></div>}
            {r.cta && <div><p className="text-xs font-bold text-suave">CTA</p><p>{r.cta}</p></div>}
          </div>
          {r.legenda && <div className="mt-4 text-sm"><p className="text-xs font-bold text-suave">LEGENDA</p><p className="whitespace-pre-line">{r.legenda}</p></div>}
          {r.observacoes && <div className="mt-4 text-sm"><p className="text-xs font-bold text-suave">DICAS DE GRAVAÇÃO E CUIDADOS</p><p className="whitespace-pre-line">{r.observacoes}</p></div>}
          {r.parecer && <p className="mt-4 text-sm text-suave"><b>Parecer do Avaliador:</b> {r.parecer}</p>}
        </>
      )}
    </Painel>
  );
}

function FormRegras({ regras }: { regras: Regras }) {
  const qc = useQueryClient();
  const [f, setF] = useState(regras);
  const [motivo, setMotivo] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [ok, setOk] = useState(false);
  const [enviando, setEnviando] = useState(false);
  const texto = (k: "foco" | "ofertas" | "tom" | "rosto" | "proibido") => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const num = (k: "ideias_por_dia" | "nota_minima" | "roteiros_por_dia") => (e: { target: { value: string } }) => setF({ ...f, [k]: Number(e.target.value) });
  const alternaFormato = (x: string) => setF({ ...f, formatos: f.formatos.includes(x) ? f.formatos.filter((y) => y !== x) : [...f.formatos, x] });
  async function salvar() {
    setEnviando(true); setErro(null); setOk(false);
    try {
      await rpc("painel_conteudo_regras_salvar", {
        p_regras: { ideias_por_dia: f.ideias_por_dia, nota_minima: f.nota_minima, roteiros_por_dia: f.roteiros_por_dia, formatos: f.formatos,
          foco: f.foco, ofertas: f.ofertas, tom: f.tom, rosto: f.rosto, proibido: f.proibido,
          ideias: f.ativos.ideias, avaliador: f.ativos.avaliador, roteirista: f.ativos.roteirista },
        p_motivo: motivo || null,
      });
      setOk(true); setMotivo("");
      await qc.invalidateQueries({ queryKey: ["conteudo"] });
    } catch (e) { setErro(traduzir(e).message); } finally { setEnviando(false); }
  }
  const area = entradaCls + " min-h-[88px] py-2";
  return (
    <Painel className="flex flex-col gap-6 p-4 md:p-6">
      <p className="text-sm text-suave">Os três agentes leem estas regras toda manhã. O que você muda aqui vale a partir da próxima rodada.</p>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Campo id="r-ideias" rotulo="Ideias por dia" ajuda="De 3 a 30."><input id="r-ideias" type="number" min={3} max={30} className={entradaCls} value={f.ideias_por_dia} onChange={num("ideias_por_dia")} /></Campo>
        <Campo id="r-nota" rotulo="Nota mínima para virar roteiro" ajuda="De 50 a 95."><input id="r-nota" type="number" min={50} max={95} className={entradaCls} value={f.nota_minima} onChange={num("nota_minima")} /></Campo>
        <Campo id="r-rot" rotulo="Roteiros por dia" ajuda="De 1 a 10."><input id="r-rot" type="number" min={1} max={10} className={entradaCls} value={f.roteiros_por_dia} onChange={num("roteiros_por_dia")} /></Campo>
      </div>
      <fieldset>
        <legend className="mb-2 text-sm font-bold">Formatos</legend>
        <div className="flex flex-wrap gap-4">
          {Object.entries(FORMATO).map(([k, r]) => (
            <label key={k} className="flex items-center gap-2 text-sm"><input type="checkbox" className="h-4 w-4" checked={f.formatos.includes(k)} onChange={() => alternaFormato(k)} /> {r}</label>
          ))}
        </div>
      </fieldset>
      <Campo id="r-foco" rotulo="Foco do momento" ajuda="Campanha, data ou objetivo que as ideias devem servir."><textarea id="r-foco" className={area} value={f.foco} onChange={texto("foco")} /></Campo>
      <Campo id="r-ofertas" rotulo="Ofertas e produtos que podem aparecer" ajuda="Os agentes só usam preço e condição que estiverem aqui."><textarea id="r-ofertas" className={area} value={f.ofertas} onChange={texto("ofertas")} /></Campo>
      <Campo id="r-tom" rotulo="Tom de voz"><textarea id="r-tom" className={area} value={f.tom} onChange={texto("tom")} /></Campo>
      <Campo id="r-rosto" rotulo="Quem aparece nos vídeos"><textarea id="r-rosto" className={area} value={f.rosto} onChange={texto("rosto")} /></Campo>
      <Campo id="r-proibido" rotulo="O que nunca pode aparecer"><textarea id="r-proibido" className={area} value={f.proibido} onChange={texto("proibido")} /></Campo>
      <fieldset>
        <legend className="mb-2 text-sm font-bold">Agentes ligados</legend>
        <div className="flex flex-wrap gap-4">
          {([["ideias", "Ideias"], ["avaliador", "Avaliador"], ["roteirista", "Roteirista"]] as const).map(([k, r]) => (
            <label key={k} className="flex items-center gap-2 text-sm">
              <input type="checkbox" className="h-4 w-4" checked={f.ativos[k]} onChange={() => setF({ ...f, ativos: { ...f.ativos, [k]: !f.ativos[k] } })} /> {r}
            </label>
          ))}
        </div>
      </fieldset>
      <Campo id="r-motivo" rotulo="Motivo da mudança (opcional)"><input id="r-motivo" className={entradaCls} value={motivo} onChange={(e) => setMotivo(e.target.value)} /></Campo>
      {erro && <p role="alert" className="text-sm font-bold text-critico">{erro}</p>}
      {ok && <p role="status" className="text-sm font-bold text-ok">Regras salvas.</p>}
      <div className="flex justify-end"><Botao variante="primario" carregando={enviando} disabled={f.formatos.length === 0} onClick={salvar}>Salvar regras</Botao></div>
    </Painel>
  );
}

export function Conteudo() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [aba, setAba] = useState<(typeof ABAS)[number][0]>("roteiros");
  const [dia, setDia] = useState("");
  const q = useQuery({ queryKey: ["conteudo", dia], queryFn: () => rpc<Dados>("painel_conteudo", { p_dia: dia || null }), enabled: eu.pode.consultar_global });

  if (!eu.pode.consultar_global) return <Vazio titulo="Conteúdo">Esta tela fica com a diretoria.</Vazio>;
  const d = q.data;
  const paraAprovar = d?.roteiros.filter((r) => r.status === "pronto").length ?? 0;
  const aprovadas = d?.ideias.filter((i) => i.status === "aprovada").length ?? 0;
  const contagem: Record<string, number | undefined> = { roteiros: d?.roteiros.length, ideias: d?.ideias.length, producao: d?.producao.filter((r) => r.status !== "descartado").length };
  return (
    <>
      <Cabecalho titulo="Conteúdo do dia"
        descricao={d ? `${data(d.dia)} · ${d.ideias.length} ideias → ${aprovadas} aprovadas pelo Avaliador → ${paraAprovar} roteiros esperando você` : "Ideias, avaliação e roteiros de Reels, todo dia."}
        acoes={d && d.dias.length > 0 ? (
          <>
            <label className="sr-only" htmlFor="cont-dia">Dia</label>
            <select id="cont-dia" className={entradaCls + " w-auto"} value={dia || d.dia} onChange={(e) => setDia(e.target.value === d.dias[0] ? "" : e.target.value)}>
              {d.dias.map((x) => <option key={x} value={x}>{data(x)}</option>)}
            </select>
          </>
        ) : undefined} />

      {d && (
        <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-3">
          {d.agentes.map((a) => (
            <Painel key={a.id} className="p-4">
              <p className="text-xs text-suave">{a.nome} · {HORARIO[a.id]}</p>
              <p className={cx("font-bold", a.falhou_hoje && "text-critico")}>{a.status !== "ativo" ? "pausado" : a.falhou_hoje ? "falhou hoje" : a.ultima ? resumoAgente(a) : "ainda não rodou"}</p>
              <p className="text-xs text-suave">{a.ultima ? `última rodada ${relativo(a.ultima)}` : "a primeira rodada é amanhã cedo"}</p>
            </Painel>
          ))}
        </div>
      )}

      <div role="tablist" aria-label="Seções" className="mb-6 flex flex-wrap gap-2">
        {ABAS.map(([k, r]) => (
          <button key={k} role="tab" aria-selected={aba === k} onClick={() => setAba(k)}
            className={cx("rounded-medio border px-4 py-2 text-sm", aba === k ? "border-lente bg-lente-clara font-bold text-lente" : "border-linha hover:bg-elevada")}>
            {r}{contagem[k] ? ` (${contagem[k]})` : ""}
          </button>
        ))}
      </div>

      {q.isLoading ? <Carregando linhas={8} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !d ? null : aba === "roteiros" ? (
        d.roteiros.length === 0 ? <Vazio titulo="Nenhum roteiro neste dia">Os agentes rodam todo dia a partir das 6h25 e deixam os roteiros aqui antes das 7h.</Vazio> : (
          <ul className="flex flex-col gap-4">
            {d.roteiros.map((r, i) => <li key={r.id}><RoteiroCard r={r} podeEditar={d.pode_editar} aberto={i === 0 && r.status === "pronto"} /></li>)}
          </ul>
        )
      ) : aba === "ideias" ? (
        d.ideias.length === 0 ? <Vazio titulo="Nenhuma ideia neste dia">O agente de Ideias roda todo dia às 6h25.</Vazio> : (
          <ul className="flex flex-col gap-2">
            {d.ideias.map((i) => (
              <li key={i.id}>
                <Painel className="flex flex-col gap-3 p-4 md:flex-row md:items-start md:justify-between">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <Etiqueta tom={i.status === "aprovada" ? "ok" : i.status === "nova" ? "atencao" : "neutro"}>
                        {i.status === "aprovada" ? (i.roteiro_id ? "Virou roteiro" : "Aprovada") : i.status === "nova" ? "Esperando o Avaliador" : "Descartada"}
                      </Etiqueta>
                      <Etiqueta>{FORMATO[i.formato] ?? i.formato} · {i.loja ?? "todas as lojas"}</Etiqueta>
                      <h2 className="text-base font-bold">{i.titulo}</h2>
                    </div>
                    {i.gancho && <p className="mt-1 text-sm"><b>Gancho:</b> {i.gancho}</p>}
                    {i.conceito && <p className="mt-1 text-sm">{i.conceito}</p>}
                    {i.evidencia && <p className="mt-1 text-sm text-suave"><b>Evidência:</b> {i.evidencia}</p>}
                    <div className="mt-1"><Nota nota={i.nota} criterios={i.criterios} /></div>
                    {i.parecer && <p className="mt-1 text-sm text-suave"><b>Parecer:</b> {i.parecer}</p>}
                  </div>
                  {d.pode_editar && i.status === "descartada" && (
                    <Confirmar gatilho={<Botao tamanho="sm">Mandar roteirizar</Botao>} titulo="Mandar esta ideia para o Roteirista?" rotuloConfirmar="Mandar roteirizar"
                      descricao="Você passa por cima do Avaliador. O roteiro chega na próxima rodada do Roteirista."
                      aoConfirmar={() => rpc("painel_ideia_conteudo_promover", { p_id: i.id })} aoConcluir={() => { void qc.invalidateQueries({ queryKey: ["conteudo"] }); }} />
                  )}
                </Painel>
              </li>
            ))}
          </ul>
        )
      ) : aba === "producao" ? (
        d.producao.length === 0 ? <Vazio titulo="Nada aprovado ainda">Os roteiros que você aprovar, gravar e publicar ficam aqui.</Vazio> : (
          <ul className="flex flex-col gap-2">
            {d.producao.map((r) => <li key={r.id}><RoteiroCard r={r} podeEditar={d.pode_editar} aberto={false} /></li>)}
          </ul>
        )
      ) : d.pode_editar ? <FormRegras key={JSON.stringify(d.regras)} regras={d.regras} /> : (
        <Vazio titulo="Regras dos agentes">Só a diretoria muda as regras.</Vazio>
      )}
    </>
  );
}
