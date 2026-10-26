import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const chave = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;
export const configurado = Boolean(url && chave);

// Sessão em sessionStorage: fechar o navegador encerra o acesso ao painel.
export const supabase = createClient(url ?? "https://nao-configurado.invalid", chave ?? "nao-configurado", {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
    storageKey: "idealize-painel",
    storage: typeof window !== "undefined" ? window.sessionStorage : undefined,
  },
});
