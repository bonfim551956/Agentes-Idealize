// Tira endereço com usuário/senha, "password=", "token=" e "Bearer ..." de qualquer mensagem antes de gravar ou registrar
// no log (achado 28/10: o erro de um endereço mal formado trazia a senha). O banco aplica o mesmo filtro (core._sem_segredo).
export function semSegredo(v: unknown): string {
  const s = String(v instanceof Error ? v.message : v);
  return s
    .replace(/postgres(ql)?:\/\/[^@]{0,250}@[^\s'"]*/gi, "[endereço]")
    .replace(/[a-z][a-z0-9+.-]*:\/\/[^\s'"]*@[^\s'"]*/gi, "[endereço]")
    .replace(/postgres(ql)?:\/\/\S*/gi, "[endereço]")
    .replace(/(password|passwd|senha|secret|token|access_token|apikey|api_key)(["']?\s*[=:]\s*)[^\s,;&"']+/gi, "$1$2[oculto]")
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [oculto]")
    .replace(/\/(instances|token)\/[^/\s'"]+/gi, "/$1/[oculto]");   // Z-API: instância e chave vão no caminho do endereço
}
