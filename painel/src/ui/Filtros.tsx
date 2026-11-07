import { useState, type ReactNode } from "react";
import { Search, X } from "lucide-react";
import { cx, entradaCls } from "./base";

// Filtros padrão do painel: período (atalhos + de/até), busca por valor/venda/OS e botões de escolha (forma, situação).

const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const somar = (d: Date, n: number) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };

export const ATALHOS = [
  ["hoje", "Hoje"], ["ontem", "Ontem"], ["7", "Últimos 7 dias"], ["15", "Últimos 15 dias"], ["30", "Últimos 30 dias"],
  ["mes", "Este mês"], ["mes_passado", "Mês passado"], ["90", "Últimos 90 dias"], ["personalizado", "Escolher datas"],
] as const;
export type Atalho = (typeof ATALHOS)[number][0];
export type Periodo = { atalho: Atalho; de: string; ate: string };

export function periodo(atalho: Atalho, hoje = new Date()): Periodo {
  const h = new Date(hoje.getFullYear(), hoje.getMonth(), hoje.getDate());
  switch (atalho) {
    case "hoje": return { atalho, de: iso(h), ate: iso(h) };
    case "ontem": return { atalho, de: iso(somar(h, -1)), ate: iso(somar(h, -1)) };
    case "mes": return { atalho, de: iso(new Date(h.getFullYear(), h.getMonth(), 1)), ate: iso(h) };
    case "mes_passado": return { atalho, de: iso(new Date(h.getFullYear(), h.getMonth() - 1, 1)), ate: iso(new Date(h.getFullYear(), h.getMonth(), 0)) };
    case "personalizado": return { atalho, de: iso(somar(h, -6)), ate: iso(h) };
    default: return { atalho, de: iso(somar(h, -(Number(atalho) - 1))), ate: iso(h) };
  }
}

export const noPeriodo = (dia: string | null | undefined, p: Periodo) => !dia || (dia.slice(0, 10) >= p.de && dia.slice(0, 10) <= p.ate);

export function usePeriodo(inicial: Atalho = "7") {
  return useState<Periodo>(() => periodo(inicial));
}

export function FiltroPeriodo({ id, valor, aoMudar }: { id: string; valor: Periodo; aoMudar: (p: Periodo) => void }) {
  return (
    <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
      <label className="sr-only" htmlFor={id}>Período</label>
      <select id={id} className={entradaCls + " sm:w-48"} value={valor.atalho}
        onChange={(e) => { const a = e.target.value as Atalho; aoMudar(a === "personalizado" ? { ...valor, atalho: a } : periodo(a)); }}>
        {ATALHOS.map(([k, r]) => <option key={k} value={k}>{r}</option>)}
      </select>
      <div className="flex items-center gap-2">
        <label className="sr-only" htmlFor={id + "-de"}>De</label>
        <input id={id + "-de"} type="date" className={entradaCls + " sm:w-40"} value={valor.de} max={valor.ate}
          onChange={(e) => e.target.value && aoMudar({ atalho: "personalizado", de: e.target.value, ate: valor.ate })} />
        <span className="text-sm text-suave">até</span>
        <label className="sr-only" htmlFor={id + "-ate"}>Até</label>
        <input id={id + "-ate"} type="date" className={entradaCls + " sm:w-40"} value={valor.ate} min={valor.de}
          onChange={(e) => e.target.value && aoMudar({ atalho: "personalizado", de: valor.de, ate: e.target.value })} />
      </div>
    </div>
  );
}

export function FiltroBusca({ id, valor, aoMudar, dica }: { id: string; valor: string; aoMudar: (v: string) => void; dica: string }) {
  return (
    <div className="relative">
      <label className="sr-only" htmlFor={id}>Buscar</label>
      <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-suave" aria-hidden />
      <input id={id} type="search" className={entradaCls + " pl-9"} placeholder={dica} value={valor} onChange={(e) => aoMudar(e.target.value)} />
    </div>
  );
}

/** Botões de escolha múltipla (nenhum marcado = todos). */
export function FiltroOpcoes({ rotulo, opcoes, valor, aoMudar }:
  { rotulo: string; opcoes: { id: string; rotulo: string; n?: number }[]; valor: string[]; aoMudar: (v: string[]) => void }) {
  return (
    <div role="group" aria-label={rotulo} className="flex flex-wrap items-center gap-2">
      <span className="text-sm font-bold">{rotulo}:</span>
      {opcoes.map((o) => {
        const on = valor.includes(o.id);
        return (
          <button key={o.id} type="button" aria-pressed={on} onClick={() => aoMudar(on ? valor.filter((x) => x !== o.id) : [...valor, o.id])}
            className={cx("rounded-full border px-3 py-1 text-sm", on ? "border-lente bg-lente-clara font-bold text-lente" : "border-linha hover:bg-elevada")}>
            {o.rotulo}{o.n != null ? ` (${o.n})` : ""}
          </button>
        );
      })}
    </div>
  );
}

export function BarraFiltros({ children, ativos, aoLimpar }: { children: ReactNode; ativos: number; aoLimpar: () => void }) {
  return (
    <div className="mb-6 flex flex-col gap-3 rounded-grande border border-linha bg-superficie p-4">
      {children}
      {ativos > 0 && (
        <div>
          <button type="button" onClick={aoLimpar} className="flex items-center gap-1 text-sm text-lente underline">
            <X className="h-4 w-4" aria-hidden /> Limpar filtros ({ativos})
          </button>
        </div>
      )}
    </div>
  );
}

// Busca: número ("165,27", "1.000", "1000") procura valores iguais; texto procura dentro de venda, OS, descrição…
function numeroDaBusca(b: string): number | null {
  const t = b.replace(/r\$\s*/i, "").trim();
  if (!/^\d{1,3}(\.\d{3})*(,\d{1,2})?$|^\d+([.,]\d{1,2})?$/.test(t)) return null;
  const n = /,/.test(t) ? Number(t.replace(/\./g, "").replace(",", ".")) : /^\d{1,3}(\.\d{3})+$/.test(t) ? Number(t.replace(/\./g, "")) : Number(t);
  return Number.isFinite(n) ? n : null;
}

export function casaBusca(busca: string, ...campos: unknown[]): boolean {
  const b = busca.trim().toLowerCase();
  if (!b) return true;
  const n = numeroDaBusca(b);
  const visita = (v: unknown): boolean => {
    if (v == null) return false;
    if (typeof v === "number") return n != null && Math.abs(v - n) < 0.005;
    if (typeof v === "string") {
      if (v.toLowerCase().includes(b)) return true;
      if (n != null && /^-?\d+(\.\d+)?$/.test(v)) return Math.abs(Number(v) - n) < 0.005;
      return false;
    }
    if (Array.isArray(v)) return v.some(visita);
    if (typeof v === "object") return Object.values(v as Record<string, unknown>).some(visita);
    return false;
  };
  return campos.some(visita);
}
