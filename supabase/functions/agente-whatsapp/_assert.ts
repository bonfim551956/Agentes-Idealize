// asserções mínimas (sem dependência externa)
export function assert(c: unknown, msg = "falhou"): asserts c { if (!c) throw new Error(msg); }
export function assertEquals(a: unknown, b: unknown) {
  const sa = JSON.stringify(a), sb = JSON.stringify(b);
  if (sa !== sb) throw new Error(`esperado ${sb}, veio ${sa}`);
}
export function assertStringIncludes(a: string, b: string) { if (!String(a).includes(b)) throw new Error(`"${String(a).slice(0, 200)}" não contém "${b}"`); }
