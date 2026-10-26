import { useState, type ReactNode } from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { motion } from "framer-motion";
import { X } from "lucide-react";
import { Botao, Campo, entradaCls } from "./base";
import { traduzir } from "../lib/erros";

type Props = {
  gatilho: ReactNode;
  titulo: string;
  descricao: ReactNode;
  detalhes?: ReactNode;
  rotuloConfirmar: string;
  variante?: "primario" | "perigo";
  motivo?: { rotulo: string; minimo: number; ajuda?: string; obrigatorio?: boolean };
  aoConfirmar: (motivo: string) => Promise<unknown>;
  aoConcluir?: () => void;
};

// Toda ação com efeito passa por aqui: confirmação explícita, motivo quando exigido, erro do banco visível.
export function Confirmar({ gatilho, titulo, descricao, detalhes, rotuloConfirmar, variante = "primario", motivo, aoConfirmar, aoConcluir }: Props) {
  const [aberto, setAberto] = useState(false);
  const [texto, setTexto] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const exige = motivo && (motivo.obrigatorio ?? true);
  const curto = Boolean(exige && texto.trim().length < (motivo?.minimo ?? 0));

  async function confirmar() {
    if (curto) { setErro(`Escreva pelo menos ${motivo!.minimo} caracteres.`); return; }
    setEnviando(true); setErro(null);
    try {
      await aoConfirmar(texto.trim());
      setAberto(false); setTexto(""); aoConcluir?.();
    } catch (e) {
      setErro(traduzir(e).message);
    } finally {
      setEnviando(false);
    }
  }

  return (
    <Dialog.Root open={aberto} onOpenChange={(v) => { if (!enviando) { setAberto(v); setErro(null); } }}>
      <Dialog.Trigger asChild>{gatilho}</Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-tinta/40" />
        <Dialog.Content asChild>
          <motion.div
            initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.16 }}
            className="fixed left-1/2 top-1/2 z-50 flex max-h-[90vh] w-[calc(100vw-32px)] max-w-lg -translate-x-1/2 -translate-y-1/2 flex-col gap-4 overflow-y-auto rounded-grande border border-linha bg-superficie p-6 shadow-lg"
          >
            <div className="flex items-start justify-between gap-4">
              <Dialog.Title className="text-lg font-bold">{titulo}</Dialog.Title>
              <Dialog.Close asChild>
                <button className="rounded-medio p-1 text-suave hover:bg-elevada" aria-label="Fechar" disabled={enviando}><X className="h-5 w-5" /></button>
              </Dialog.Close>
            </div>
            <Dialog.Description asChild><div className="text-sm text-suave">{descricao}</div></Dialog.Description>
            {detalhes}
            {motivo && (
              <Campo id="confirmar-motivo" rotulo={motivo.rotulo} ajuda={motivo.ajuda} erro={erro && curto ? erro : null}>
                <textarea id="confirmar-motivo" rows={3} className={entradaCls} value={texto} disabled={enviando}
                  aria-invalid={Boolean(erro && curto)} onChange={(e) => setTexto(e.target.value)} />
              </Campo>
            )}
            {erro && !curto && <p role="alert" className="rounded-medio bg-critico-fundo px-3 py-2 text-sm font-bold text-critico">{erro}</p>}
            <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
              <Dialog.Close asChild><Botao disabled={enviando}>Voltar</Botao></Dialog.Close>
              <Botao variante={variante} carregando={enviando} onClick={confirmar}>{rotuloConfirmar}</Botao>
            </div>
          </motion.div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
