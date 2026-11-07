import { useState } from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { Bot, MessageSquare, User, X } from "lucide-react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { rpc } from "../lib/api";
import { traduzir } from "../lib/erros";
import { relativo } from "../lib/format";
import { Botao, Carregando, ErroCaixa, cx, entradaCls } from "./base";

// Conversa com o agente sobre um aviso: a pessoa explica ou pede para investigar; o agente responde aqui.
type Msg = { id: number; papel: "pessoa" | "agente"; autor: string; texto: string; acao: string; em: string; respondida: boolean };
type Conversa = { status: string; pode_explicar: boolean; mensagens: Msg[] };

export function ConversaAviso({ area = "caixa", tipo, referencia, titulo, mensagens = 0 }:
  { area?: string; tipo: string; referencia: string; titulo: string; mensagens?: number }) {
  const [aberto, setAberto] = useState(false);
  const [texto, setTexto] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const qc = useQueryClient();
  const chave = ["aviso-conversa", area, tipo, referencia];
  const q = useQuery({ queryKey: chave, enabled: aberto, refetchInterval: aberto ? 30_000 : false,
    queryFn: () => rpc<Conversa>("painel_aviso_conversa", { p_area: area, p_tipo: tipo, p_ref: referencia }) });

  async function enviar(acao: "comentar" | "explicar" | "reabrir") {
    if (texto.trim().length < 2) { setErro("Escreva a mensagem."); return; }
    setEnviando(true); setErro(null);
    try {
      await rpc("painel_aviso_escrever", { p_area: area, p_tipo: tipo, p_ref: referencia, p_texto: texto.trim(), p_acao: acao });
      setTexto("");
      void qc.invalidateQueries({ queryKey: chave });
      if (acao !== "comentar") { void qc.invalidateQueries({ queryKey: ["caixa"] }); void qc.invalidateQueries({ queryKey: ["central"] }); }
    } catch (e) { setErro(traduzir(e).message); } finally { setEnviando(false); }
  }

  const c = q.data;
  const pendente = c?.mensagens.some((m) => m.papel === "pessoa" && !m.respondida && m.acao === "comentar");
  return (
    <Dialog.Root open={aberto} onOpenChange={(v) => { if (!enviando) { setAberto(v); setErro(null); } }}>
      <Dialog.Trigger asChild>
        <button type="button" className="flex shrink-0 items-center gap-1 rounded-medio border border-linha px-3 py-2 text-sm font-bold hover:bg-elevada">
          <MessageSquare className="h-4 w-4" aria-hidden /> Falar com o agente{mensagens > 0 ? ` (${mensagens})` : ""}
        </button>
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-tinta/40" />
        <Dialog.Content asChild>
          <div
            className="fixed left-1/2 top-1/2 z-50 flex max-h-[90vh] w-[calc(100vw-32px)] max-w-lg -translate-x-1/2 -translate-y-1/2 flex-col gap-4 overflow-y-auto rounded-grande border border-linha bg-superficie p-6 shadow-lg">
            <div className="flex items-start justify-between gap-4">
              <Dialog.Title className="text-lg font-bold">Falar com o agente</Dialog.Title>
              <Dialog.Close asChild><button className="rounded-medio p-1 text-suave hover:bg-elevada" aria-label="Fechar" disabled={enviando}><X className="h-5 w-5" /></button></Dialog.Close>
            </div>
            <Dialog.Description className="text-sm text-suave">{titulo}</Dialog.Description>
            {q.isLoading ? <Carregando linhas={2} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : c && (
              <>
                {c.status === "explicado" && <p className="rounded-medio bg-ok-fundo px-3 py-2 text-sm font-bold text-ok">Aviso marcado como explicado: o agente não cobra mais.</p>}
                <ul className="flex flex-col gap-3" aria-label="Mensagens">
                  {!c.mensagens.length && <li className="text-sm text-suave">Ainda sem mensagens. Conte o que você sabe (ex.: "o valor da cliente entrou duplicado") ou peça para o agente investigar.</li>}
                  {c.mensagens.map((m) => (
                    <li key={m.id} className={cx("flex gap-2", m.papel === "agente" ? "" : "flex-row-reverse text-right")}>
                      <span className={cx("mt-1 flex h-7 w-7 shrink-0 items-center justify-center rounded-full", m.papel === "agente" ? "bg-lente-clara text-lente" : "bg-elevada")}>
                        {m.papel === "agente" ? <Bot className="h-4 w-4" aria-hidden /> : <User className="h-4 w-4" aria-hidden />}
                      </span>
                      <div className={cx("max-w-[85%] rounded-grande px-3 py-2 text-sm", m.papel === "agente" ? "bg-lente-clara" : "bg-elevada")}>
                        <p className="whitespace-pre-wrap text-left">{m.texto}</p>
                        <p className="mt-1 text-xs text-suave">{m.autor} · {relativo(m.em)}{m.acao === "explicar" ? " · marcou como explicado" : m.acao === "reabrir" ? " · voltou a cobrar" : ""}</p>
                      </div>
                    </li>
                  ))}
                </ul>
                {pendente && <p className="text-xs text-suave">O agente responde em até uma hora (das 8h às 20h).</p>}
                <div className="flex flex-col gap-2">
                  <label htmlFor={`msg-${tipo}-${referencia}`} className="text-sm font-bold">Sua mensagem</label>
                  <textarea id={`msg-${tipo}-${referencia}`} rows={3} maxLength={2000} className={entradaCls} value={texto} onChange={(e) => setTexto(e.target.value)}
                    placeholder="Ex.: o valor da Tatiana entrou duplicado no dia 25/09, pode confirmar?" />
                  {erro && <p role="alert" className="text-sm font-bold text-critico">{erro}</p>}
                  <div className="flex flex-wrap gap-2">
                    <Botao variante="primario" carregando={enviando} onClick={() => void enviar("comentar")}>Enviar para o agente</Botao>
                    {c.pode_explicar && c.status === "aberto" && <Botao carregando={enviando} onClick={() => void enviar("explicar")}>Enviar e marcar como explicado</Botao>}
                    {c.pode_explicar && c.status === "explicado" && <Botao carregando={enviando} onClick={() => void enviar("reabrir")}>Voltar a cobrar</Botao>}
                  </div>
                  {c.pode_explicar && c.status === "aberto" && <p className="text-xs text-suave">"Marcar como explicado" faz o agente parar de cobrar este aviso. Dá para voltar atrás aqui mesmo.</p>}
                </div>
              </>
            )}
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
