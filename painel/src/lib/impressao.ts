// "Impressão digital" da operação: o hash que a aprovação assina, em forma que o olho compara.
// Mesma operação → mesmos blocos; qualquer mudança no conteúdo muda o desenho.
export type Bloco = { matiz: number; cor: string };

export function blocos(hash: string, n = 8): Bloco[] {
  const hex = (hash || "").replace(/[^0-9a-f]/gi, "").toLowerCase();
  if (hex.length < n * 2) return [];
  return Array.from({ length: n }, (_, i) => {
    const byte = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    const matiz = Math.round((byte / 256) * 360);
    return { matiz, cor: `hsl(${matiz} 45% 42%)` };
  });
}

export function codigoCurto(hash: string): string {
  const hex = (hash || "").replace(/[^0-9a-f]/gi, "").toLowerCase();
  return hex.length >= 12 ? `${hex.slice(0, 4)} ${hex.slice(4, 8)} ${hex.slice(8, 12)}` : hex;
}
