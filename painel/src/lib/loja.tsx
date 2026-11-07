import { createContext, useContext, useState, type ReactNode } from "react";
import { useSessao } from "../auth/Sessao";

// Loja travada: escolhida no topo do painel, vale para todas as telas que filtram por loja.
// Fica guardada só neste navegador (é uma preferência de visualização, não muda nada nos sistemas).
const CHAVE = "idealize.loja_travada";
const ler = () => { try { return localStorage.getItem(CHAVE) ?? ""; } catch { return ""; } };
const gravar = (v: string) => { try { if (v) localStorage.setItem(CHAVE, v); else localStorage.removeItem(CHAVE); } catch { /* sem armazenamento */ } };

const Ctx = createContext<{ loja: string; travar: (id: string) => void }>({ loja: "", travar: () => undefined });

export function LojaTravada({ children }: { children: ReactNode }) {
  const { eu } = useSessao();
  const [salva, setSalva] = useState(ler);
  // só vale se a pessoa ainda tem acesso à loja guardada
  const loja = eu.unidades.some((u) => u.id === salva) ? salva : "";
  const travar = (id: string) => { setSalva(id); gravar(id); };
  return <Ctx.Provider value={{ loja, travar }}>{children}</Ctx.Provider>;
}

export const useLojaTravada = () => useContext(Ctx);

/** Filtro de loja de uma tela: com loja travada, fica preso nela. */
export function useFiltroLoja(): [string, (v: string) => void, boolean] {
  const { loja } = useContext(Ctx);
  const [local, setLocal] = useState("");
  return [loja || local, (v: string) => { if (!loja) setLocal(v); }, !!loja];
}
