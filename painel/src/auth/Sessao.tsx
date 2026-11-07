import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { useQueryClient } from "@tanstack/react-query";
import { configurado, supabase } from "../lib/supabase";
import { rpc, type Eu } from "../lib/api";
import { traduzir } from "../lib/erros";
import { Login } from "./Login";
import { Cadastrar2fa, Confirmar2fa } from "./DoisFatores";
import { TelaCentral } from "./TelaCentral";
import { CHAVE_RECUPERACAO, NovaSenha, lerRetornoDoEmail } from "./Recuperacao";
import { Botao, ErroCaixa } from "../ui/base";

// Regras de sessão vêm do banco (tela Operação e integrações): padrão 12 h sem uso e senha + código a cada 7 dias.
type Regras = { inatividade_horas: number; dias: number; pode_alterar: boolean };
const CHAVE_ULTIMO_USO = "idealize-painel-ultimo-uso";
const lerUltimoUso = () => { try { return Number(window.localStorage.getItem(CHAVE_ULTIMO_USO)) || null; } catch { return null; } };
const gravarUltimoUso = (t: number | null) => {
  try { if (t === null) window.localStorage.removeItem(CHAVE_ULTIMO_USO); else window.localStorage.setItem(CHAVE_ULTIMO_USO, String(t)); } catch { /* sem storage */ }
};

type Ctx = { eu: Eu; sair: () => Promise<void>; email: string | null };
const SessaoCtx = createContext<Ctx | null>(null);
export const useSessao = () => {
  const c = useContext(SessaoCtx);
  if (!c) throw new Error("fora da sessão");
  return c;
};

type Etapa =
  | { e: "carregando" }
  | { e: "entrar" }
  | { e: "cadastrar_2fa" }
  | { e: "confirmar_2fa"; fator: string }
  | { e: "nova_senha" }
  | { e: "sem_acesso"; msg: string }
  | { e: "erro"; msg: string }
  | { e: "pronto"; eu: Eu };

export function Sessao({ children }: { children: ReactNode }) {
  const [sessao, setSessao] = useState<Session | null | undefined>(undefined);
  const [etapa, setEtapa] = useState<Etapa>({ e: "carregando" });
  const [aviso, setAviso] = useState<string | null>(null);
  const regras = useRef<Regras>({ inatividade_horas: 12, dias: 7, pode_alterar: false });
  const recuperando = () => { try { return window.sessionStorage.getItem(CHAVE_RECUPERACAO) === "1"; } catch { return false; } };

  const qc = useQueryClient();
  const sair = useCallback(async () => {
    try { window.sessionStorage.removeItem(CHAVE_RECUPERACAO); } catch { /* sem storage */ }
    gravarUltimoUso(null);
    await supabase.auth.signOut();
    qc.clear(); // nada do usuário anterior fica em memória
    setEtapa({ e: "entrar" });
  }, [qc]);

  useEffect(() => {
    if (!configurado) return;
    const { data } = supabase.auth.onAuthStateChange((_ev, s) => setSessao(s));
    (async () => {
      // Volta do link de "esqueci minha senha": abre sessão de nível 1; trocar a senha ainda exige o código do autenticador.
      const r = lerRetornoDoEmail();
      if (r?.tipo === "erro") setAviso(r.msg);
      if (r?.tipo === "recuperacao") {
        const { error } = await supabase.auth.setSession({ access_token: r.access_token, refresh_token: r.refresh_token });
        if (error) setAviso("O link de redefinição venceu ou já foi usado. Peça um novo.");
        else try { window.sessionStorage.setItem(CHAVE_RECUPERACAO, "1"); } catch { /* sem storage */ }
      }
      const { data: d } = await supabase.auth.getSession();
      setSessao(d.session);
    })();
    return () => data.subscription.unsubscribe();
  }, []);

  const avaliar = useCallback(async () => {
    if (sessao === undefined) return;
    if (!sessao) { setEtapa({ e: "entrar" }); return; }
    try {
      const { data: nivel, error } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
      if (error) throw error;
      const { data: fatores, error: e2 } = await supabase.auth.mfa.listFactors();
      if (e2) throw e2;
      const totp = fatores.totp.find((f) => f.status === "verified");
      if (!totp) { setEtapa({ e: "cadastrar_2fa" }); return; }
      if (nivel.currentLevel !== "aal2") { setEtapa({ e: "confirmar_2fa", fator: totp.id }); return; }
      if (recuperando()) { setEtapa({ e: "nova_senha" }); return; }
      regras.current = await rpc<Regras>("painel_sessao_regras");
      const agora = Date.now();
      const ultimoUso = lerUltimoUso();
      if (ultimoUso && agora - ultimoUso > regras.current.inatividade_horas * 3_600_000) {
        await sair(); setAviso(`O painel ficou mais de ${regras.current.inatividade_horas} h sem uso. Entre de novo.`); return;
      }
      const codigoEm = Math.max(0, ...(nivel.currentAuthenticationMethods ?? [])
        .flatMap((m) => (typeof m === "object" && m.method === "totp" ? [m.timestamp * 1000] : [])));
      if (codigoEm && agora - codigoEm > regras.current.dias * 86_400_000) {
        await sair(); setAviso(`Por segurança, a cada ${regras.current.dias} dias o painel pede a senha e o código de novo.`); return;
      }
      gravarUltimoUso(agora);
      const eu = await rpc<Eu>("painel_eu");
      setEtapa({ e: "pronto", eu });
    } catch (e) {
      const t = traduzir(e);
      if (/entre de novo com a senha/i.test(t.message)) { await sair(); setAviso(t.message); return; }
      setEtapa(t.tipo === "acesso" ? { e: "sem_acesso", msg: t.message } : { e: "erro", msg: t.message });
    }
  }, [sessao, sair]);

  useEffect(() => { void avaliar(); }, [avaliar]);

  // encerra por inatividade
  const ultimo = useRef(Date.now());
  useEffect(() => {
    if (etapa.e !== "pronto") return;
    const marcar = () => {
      const agora = Date.now();
      if (agora - ultimo.current > 30_000) gravarUltimoUso(agora); // grava no aparelho no máximo a cada 30 s
      ultimo.current = agora;
    };
    const evts = ["pointerdown", "keydown", "scroll"] as const;
    evts.forEach((ev) => window.addEventListener(ev, marcar, { passive: true }));
    const id = window.setInterval(() => { if (Date.now() - ultimo.current > regras.current.inatividade_horas * 3_600_000) {
      void sair().then(() => setAviso(`O painel ficou mais de ${regras.current.inatividade_horas} h sem uso. Entre de novo.`));
    } }, 30_000);
    return () => { evts.forEach((ev) => window.removeEventListener(ev, marcar)); window.clearInterval(id); };
  }, [etapa.e, sair]);

  if (!configurado)
    return <TelaCentral titulo="Painel sem configuração">Defina VITE_SUPABASE_URL e VITE_SUPABASE_PUBLISHABLE_KEY no ambiente de publicação.</TelaCentral>;

  switch (etapa.e) {
    case "carregando":
      return <TelaCentral titulo="Abrindo o painel" carregando />;
    case "entrar":
      return <Login aviso={aviso} />;
    case "nova_senha":
      return <NovaSenha aoConcluir={avaliar} aoSair={sair} />;
    case "cadastrar_2fa":
      return <Cadastrar2fa aoConcluir={avaliar} aoSair={sair} />;
    case "confirmar_2fa":
      return <Confirmar2fa fator={etapa.fator} aoConcluir={avaliar} aoSair={sair} />;
    case "sem_acesso":
      return (
        <TelaCentral titulo="Acesso ainda não liberado">
          <p>{etapa.msg}</p>
          <p className="mt-2">Login atual: {sessao?.user.email}</p>
          <Botao className="mt-6" onClick={sair}>Sair</Botao>
        </TelaCentral>
      );
    case "erro":
      return (
        <TelaCentral titulo="Não foi possível abrir o painel">
          <ErroCaixa erro={etapa.msg} tentarDeNovo={avaliar} />
          <Botao className="mt-4" variante="fantasma" onClick={sair}>Sair</Botao>
        </TelaCentral>
      );
    case "pronto":
      return <SessaoCtx.Provider value={{ eu: etapa.eu, sair, email: sessao?.user.email ?? null }}>{children}</SessaoCtx.Provider>;
  }
}
