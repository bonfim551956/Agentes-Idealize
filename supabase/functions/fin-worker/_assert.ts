// asserções mínimas (sem dependência externa)
export function assert(c: unknown, msg = "falhou"): asserts c { if (!c) throw new Error(msg); }
export function assertEquals(a: unknown, b: unknown) {
  const sa = JSON.stringify(a), sb = JSON.stringify(b);
  if (sa !== sb) throw new Error(`esperado ${sb}, veio ${sa}`);
}
export function assertThrows(f: () => unknown, tipo: new (...a: any[]) => Error) {
  try { f(); } catch (e) { if (e instanceof tipo) return; throw new Error(`erro de outro tipo: ${e}`); }
  throw new Error("não lançou");
}
export async function assertRejects(f: () => Promise<unknown>, tipo: new (...a: any[]) => Error) {
  try { await f(); } catch (e) { if (e instanceof tipo) return; throw new Error(`erro de outro tipo: ${e}`); }
  throw new Error("não lançou");
}
