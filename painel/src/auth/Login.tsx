import { useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase";
import { Botao, Campo, entradaCls } from "../ui/base";
import { Marca } from "../ui/Marca";

export function Login() {
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);

  async function entrar(e: FormEvent) {
    e.preventDefault();
    setEnviando(true); setErro(null);
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: senha });
    setEnviando(false);
    if (error) {
      setErro(/invalid login/i.test(error.message) ? "E-mail ou senha incorretos."
        : /rate limit|too many/i.test(error.message) ? "Muitas tentativas. Aguarde alguns minutos."
        : /fetch/i.test(error.message) ? "Sem conexão com o servidor." : error.message);
    }
  }

  return (
    <main className="flex min-h-full items-center justify-center px-4 py-12">
      <form onSubmit={entrar} className="w-full max-w-sm" noValidate>
        <Marca className="mb-12" />
        <h1 className="text-xl">Entrar no painel</h1>
        <p className="mt-2 text-sm text-suave">Acesso restrito. Depois da senha, o painel pede o código do seu aplicativo autenticador.</p>
        <div className="mt-8 flex flex-col gap-4">
          <Campo id="email" rotulo="E-mail">
            <input id="email" type="email" autoComplete="username" required className={entradaCls}
              value={email} onChange={(e) => setEmail(e.target.value)} disabled={enviando} />
          </Campo>
          <Campo id="senha" rotulo="Senha">
            <input id="senha" type="password" autoComplete="current-password" required className={entradaCls}
              value={senha} onChange={(e) => setSenha(e.target.value)} disabled={enviando} />
          </Campo>
          {erro && <p role="alert" className="rounded-medio bg-critico-fundo px-3 py-2 text-sm font-bold text-critico">{erro}</p>}
          <Botao type="submit" variante="primario" carregando={enviando} disabled={!email || !senha}>Entrar</Botao>
          <p className="text-xs text-suave">Esqueceu a senha? Peça ao administrador da plataforma para redefinir.</p>
        </div>
      </form>
    </main>
  );
}
