// Traduz erros do Supabase/PostgREST para mensagens que dizem o que aconteceu e o que fazer.
export class ErroPainel extends Error {
  constructor(message: string, readonly tipo: "acesso" | "2fa" | "validacao" | "limite" | "rede" | "outro") {
    super(message);
  }
}

export function traduzir(e: unknown): ErroPainel {
  if (e instanceof ErroPainel) return e;
  const err = (e ?? {}) as { message?: string; code?: string };
  const msg = String(err.message ?? e ?? "Erro desconhecido");
  if (/segundo fator|2FA/i.test(msg)) return new ErroPainel("Confirme o código do autenticador para continuar.", "2fa");
  if (/sem acesso ao painel/i.test(msg)) return new ErroPainel("Seu login ainda não foi liberado para o painel. Peça ao administrador para vincular seu e-mail.", "acesso");
  if (/JWT expired|não autenticado/i.test(msg)) return new ErroPainel("Sua sessão terminou. Entre de novo.", "acesso");
  if (/muitas requisições/i.test(msg)) return new ErroPainel("Muitas ações em pouco tempo. Aguarde um minuto e tente de novo.", "limite");
  if (/Failed to fetch|NetworkError|Load failed/i.test(msg)) return new ErroPainel("Sem conexão com o servidor. Verifique a internet e tente de novo.", "rede");
  if (err.code === "42501" || /sem permissão|fora do seu alcance|alçada/i.test(msg)) return new ErroPainel(primeiraMaiuscula(msg) + ".", "acesso");
  if (err.code === "22023" || /informe |inválid|obrigat/i.test(msg)) return new ErroPainel(primeiraMaiuscula(msg) + ".", "validacao");
  return new ErroPainel(primeiraMaiuscula(msg), "outro");
}

const primeiraMaiuscula = (s: string) => (s ? s[0].toUpperCase() + s.slice(1) : s).replace(/\.+$/, "");
