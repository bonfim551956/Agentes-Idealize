import { useState, type FormEvent } from "react";
import { KeyRound, MailCheck } from "lucide-react";
import { supabase } from "../lib/supabase";
import { Botao, Campo, entradaCls } from "../ui/base";
import { TelaCentral } from "./TelaCentral";

export const CHAVE_RECUPERACAO = "idealize-painel-recuperar";
const MINIMO = 12;

export type Retorno = { tipo: "recuperacao"; access_token: string; refresh_token: string } | { tipo: "erro"; msg: string } | null;

// Lê o retorno do link de e-mail (#access_token=...&type=recovery) e limpa a barra de endereço na hora.
export function lerRetornoDoEmail(): Retorno {
  const h = window.location.hash.startsWith("#") ? window.location.hash.slice(1) : "";
  if (!h) return null;
  const p = new URLSearchParams(h);
  const limpar = () => window.history.replaceState(null, "", window.location.pathname + window.location.search);
  if (p.get("error") || p.get("error_code")) {
    limpar();
    return { tipo: "erro", msg: /expired/i.test(p.get("error_code") ?? "") || /expired/i.test(p.get("error_description") ?? "")
      ? "O link de redefinição venceu ou já foi usado. Peça um novo." : "Não foi possível usar o link de redefinição. Peça um novo." };
  }
  const at = p.get("access_token"), rt = p.get("refresh_token");
  if (p.get("type") === "recovery" && at && rt) { limpar(); return { tipo: "recuperacao", access_token: at, refresh_token: rt }; }
  return null;
}

export function PedirLink({ voltar }: { voltar: () => void }) {
  const [email, setEmail] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [enviado, setEnviado] = useState(false);
  const [erro, setErro] = useState<string | null>(null);

  async function enviar(e: FormEvent) {
    e.preventDefault();
    setEnviando(true); setErro(null);
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: `${window.location.origin}/` });
    setEnviando(false);
    // Resposta igual com ou sem cadastro: não revela quais e-mails existem.
    if (error && /rate limit|too many|security purposes/i.test(error.message)) { setErro("Muitos pedidos seguidos. Aguarde alguns minutos e tente de novo."); return; }
    if (error && /fetch/i.test(error.message)) { setErro("Sem conexão com o servidor."); return; }
    setEnviado(true);
  }

  if (enviado)
    return (
      <div className="mt-8 flex flex-col gap-4">
        <p role="status" className="flex gap-2 rounded-medio border border-linha bg-superficie px-3 py-3 text-sm">
          <MailCheck className="mt-0.5 h-4 w-4 shrink-0 text-lente" aria-hidden />
          Se esse e-mail tiver acesso ao painel, chega em instantes um link para criar a senha nova. Confira também o spam.
        </p>
        <Botao type="button" variante="fantasma" onClick={voltar}>Voltar para entrar</Botao>
      </div>
    );

  return (
    <form onSubmit={enviar} className="mt-8 flex flex-col gap-4" noValidate>
      <p className="text-sm text-suave">Digite seu e-mail. Vamos mandar um link; para trocar a senha o painel também pede o código do autenticador.</p>
      <Campo id="email-rec" rotulo="E-mail">
        <input id="email-rec" type="email" autoComplete="username" required className={entradaCls}
          value={email} onChange={(e) => setEmail(e.target.value)} disabled={enviando} autoFocus />
      </Campo>
      {erro && <p role="alert" className="rounded-medio bg-critico-fundo px-3 py-2 text-sm font-bold text-critico">{erro}</p>}
      <Botao type="submit" variante="primario" carregando={enviando} disabled={!/.+@.+\..+/.test(email)}>Enviar link</Botao>
      <Botao type="button" variante="fantasma" onClick={voltar}>Voltar para entrar</Botao>
    </form>
  );
}

export function NovaSenha({ aoConcluir, aoSair }: { aoConcluir: () => void; aoSair: () => void }) {
  const [senha, setSenha] = useState("");
  const [repetir, setRepetir] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const curta = senha.length > 0 && senha.length < MINIMO;
  const diferente = repetir.length > 0 && repetir !== senha;

  async function salvar(e: FormEvent) {
    e.preventDefault();
    if (senha.length < MINIMO || senha !== repetir) return;
    setEnviando(true); setErro(null);
    const { error } = await supabase.auth.updateUser({ password: senha });
    setEnviando(false);
    if (error) {
      setErro(/different from the old/i.test(error.message) ? "A senha nova precisa ser diferente da antiga."
        : /weak|pwned|leaked|characters/i.test(error.message) ? "Senha fraca ou já vazada na internet. Escolha outra."
        : /aal2|mfa/i.test(error.message) ? "Confirme o código do autenticador antes de trocar a senha."
        : error.message);
      return;
    }
    try { window.sessionStorage.removeItem(CHAVE_RECUPERACAO); } catch { /* sem storage */ }
    aoConcluir();
  }

  return (
    <TelaCentral titulo="Crie a senha nova">
      <p>Use pelo menos {MINIMO} caracteres. Uma frase curta que só você saiba funciona bem.</p>
      <form onSubmit={salvar} className="mt-6 flex flex-col gap-4 text-tinta" noValidate>
        <Campo id="nova" rotulo="Senha nova" erro={curta ? `Faltam ${MINIMO - senha.length} caracteres.` : null}>
          <input id="nova" type="password" autoComplete="new-password" className={entradaCls} value={senha}
            onChange={(e) => setSenha(e.target.value)} disabled={enviando} autoFocus />
        </Campo>
        <Campo id="repetir" rotulo="Repita a senha nova" erro={diferente ? "As duas senhas não são iguais." : null}>
          <input id="repetir" type="password" autoComplete="new-password" className={entradaCls} value={repetir}
            onChange={(e) => setRepetir(e.target.value)} disabled={enviando} />
        </Campo>
        {erro && <p role="alert" className="rounded-medio bg-critico-fundo px-3 py-2 text-sm font-bold text-critico">{erro}</p>}
        <Botao type="submit" variante="primario" carregando={enviando} disabled={senha.length < MINIMO || senha !== repetir}
          icone={<KeyRound className="h-4 w-4" aria-hidden />}>Salvar senha nova</Botao>
        <Botao type="button" variante="fantasma" onClick={aoSair}>Cancelar e sair</Botao>
      </form>
    </TelaCentral>
  );
}
