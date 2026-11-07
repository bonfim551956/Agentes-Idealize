import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const chave = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;
export const configurado = Boolean(url && chave);

// Sessão guardada no aparelho (localStorage): fechar o navegador ou trocar de app não pede login de novo.
// O limite é a regra do painel (painel_sessao_regras): sem uso por X horas ou X dias desde o código, pede de novo.
export const supabase = createClient(url ?? "https://nao-configurado.invalid", chave ?? "nao-configurado", {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
    storageKey: "idealize-painel",
    storage: typeof window !== "undefined" ? window.localStorage : undefined,
  },
});
