import { useEffect, useState, type FormEvent } from "react";
import { ShieldCheck } from "lucide-react";
import { supabase } from "../lib/supabase";
import { Botao, Campo, entradaCls } from "../ui/base";
import { TelaCentral } from "./TelaCentral";

function CampoCodigo({ valor, mudar, desab }: { valor: string; mudar: (v: string) => void; desab: boolean }) {
  return (
    <Campo id="codigo" rotulo="Código de 6 dígitos" ajuda="O código muda a cada 30 segundos.">
      <input id="codigo" inputMode="numeric" autoComplete="one-time-code" maxLength={6} pattern="[0-9]{6}"
        className={entradaCls + " text-xl tracking-[0.3em]"} value={valor} disabled={desab}
        onChange={(e) => mudar(e.target.value.replace(/\D/g, "").slice(0, 6))} autoFocus />
    </Campo>
  );
}

const erroCodigo = (m: string) => (/invalid|expired/i.test(m) ? "Código incorreto ou vencido. Use o código atual do aplicativo." : m);

export function Cadastrar2fa({ aoConcluir, aoSair }: { aoConcluir: () => void; aoSair: () => void }) {
  const [fator, setFator] = useState<{ id: string; qr: string; segredo: string } | null>(null);
  const [codigo, setCodigo] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);

  useEffect(() => {
    (async () => {
      // remove cadastros anteriores não confirmados para não acumular fatores pendentes
      const { data } = await supabase.auth.mfa.listFactors();
      for (const f of data?.all ?? []) if (f.status === "unverified") await supabase.auth.mfa.unenroll({ factorId: f.id });
      const { data: d, error } = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: "Painel Idealize" });
      if (error) { setErro(error.message); return; }
      setFator({ id: d.id, qr: d.totp.qr_code, segredo: d.totp.secret });
    })();
  }, []);

  async function confirmar(e: FormEvent) {
    e.preventDefault();
    if (!fator) return;
    setEnviando(true); setErro(null);
    const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: fator.id, code: codigo });
    setEnviando(false);
    if (error) { setErro(erroCodigo(error.message)); setCodigo(""); return; }
    aoConcluir();
  }

  return (
    <TelaCentral titulo="Ative a verificação em duas etapas">
      <p>O painel aprova operações e mexe em permissões, por isso exige um segundo fator. Escaneie o QR code com o Google Authenticator, Microsoft Authenticator ou 1Password.</p>
      <form onSubmit={confirmar} className="mt-6 flex flex-col gap-4 text-tinta">
        {fator ? (
          <div className="flex flex-col items-start gap-4 rounded-grande border border-linha bg-superficie p-4 sm:flex-row">
            <img src={fator.qr} alt="QR code para o aplicativo autenticador" className="h-40 w-40 rounded-medio bg-[#FAFAFA] p-2" />
            <div className="min-w-0 text-sm">
              <p className="font-bold">Sem câmera?</p>
              <p className="mt-1 text-suave">Digite esta chave no aplicativo:</p>
              <p className="mt-2 break-all font-bold">{fator.segredo}</p>
            </div>
          </div>
        ) : !erro && <div className="h-48 animate-pulse rounded-grande bg-elevada" role="status" aria-label="Gerando QR code" />}
        <CampoCodigo valor={codigo} mudar={setCodigo} desab={enviando || !fator} />
        {erro && <p role="alert" className="rounded-medio bg-critico-fundo px-3 py-2 text-sm font-bold text-critico">{erro}</p>}
        <Botao type="submit" variante="primario" carregando={enviando} disabled={codigo.length !== 6 || !fator}
          icone={<ShieldCheck className="h-4 w-4" aria-hidden />}>Ativar e entrar</Botao>
        <Botao type="button" variante="fantasma" onClick={aoSair}>Sair</Botao>
      </form>
    </TelaCentral>
  );
}

export function Confirmar2fa({ fator, aoConcluir, aoSair }: { fator: string; aoConcluir: () => void; aoSair: () => void }) {
  const [codigo, setCodigo] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);

  async function confirmar(e: FormEvent) {
    e.preventDefault();
    setEnviando(true); setErro(null);
    const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: fator, code: codigo });
    setEnviando(false);
    if (error) { setErro(erroCodigo(error.message)); setCodigo(""); return; }
    aoConcluir();
  }

  return (
    <TelaCentral titulo="Confirme que é você">
      <p>Abra o aplicativo autenticador e digite o código do Painel Idealize.</p>
      <form onSubmit={confirmar} className="mt-6 flex flex-col gap-4 text-tinta">
        <CampoCodigo valor={codigo} mudar={setCodigo} desab={enviando} />
        {erro && <p role="alert" className="rounded-medio bg-critico-fundo px-3 py-2 text-sm font-bold text-critico">{erro}</p>}
        <Botao type="submit" variante="primario" carregando={enviando} disabled={codigo.length !== 6}>Confirmar</Botao>
        <Botao type="button" variante="fantasma" onClick={aoSair}>Entrar com outra conta</Botao>
      </form>
    </TelaCentral>
  );
}
