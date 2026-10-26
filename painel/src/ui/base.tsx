import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from "react";
import { AlertTriangle, Loader2, RotateCw } from "lucide-react";
import type { Tom } from "../lib/format";

export function cx(...c: (string | false | null | undefined)[]) {
  return c.filter(Boolean).join(" ");
}

type Variante = "primario" | "secundario" | "perigo" | "fantasma";
type BotaoProps = ButtonHTMLAttributes<HTMLButtonElement> & { variante?: Variante; carregando?: boolean; icone?: ReactNode; tamanho?: "md" | "sm" };

const VARIANTES: Record<Variante, string> = {
  primario: "bg-lente-forte sobre-lente hover:bg-lente-forte/90 active:bg-lente-forte/80 border border-transparent",
  secundario: "bg-superficie text-tinta border border-linha hover:bg-elevada active:bg-linha/60",
  perigo: "bg-critico sobre-lente hover:bg-critico/90 active:bg-critico/80 border border-transparent",
  fantasma: "bg-transparent text-lente border border-transparent hover:bg-lente-clara active:bg-lente-clara/70",
};

export const Botao = forwardRef<HTMLButtonElement, BotaoProps>(function Botao(
  { variante = "secundario", carregando, icone, tamanho = "md", className, children, disabled, ...rest }, ref) {
  return (
    <button
      ref={ref}
      {...rest}
      disabled={disabled || carregando}
      aria-busy={carregando || undefined}
      className={cx(
        "inline-flex shrink-0 items-center justify-center gap-2 whitespace-nowrap rounded-medio font-bold transition-colors",
        "disabled:cursor-not-allowed disabled:opacity-50",
        tamanho === "md" ? "h-10 px-4 text-sm" : "h-8 px-3 text-xs",
        VARIANTES[variante], className)}
    >
      {carregando ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : icone}
      {children}
    </button>
  );
});

const TONS: Record<Tom, string> = {
  neutro: "bg-elevada text-suave",
  lente: "bg-lente-clara text-lente",
  ok: "bg-ok-fundo text-ok",
  atencao: "bg-atencao-fundo text-atencao",
  critico: "bg-critico-fundo text-critico",
};

export function Etiqueta({ tom = "neutro", children, className }: { tom?: Tom; children: ReactNode; className?: string }) {
  return (
    <span className={cx("inline-flex items-center gap-1 whitespace-nowrap rounded-pequeno px-2 py-1 text-xs font-bold", TONS[tom], className)}>
      <span aria-hidden className={cx("h-2 w-2 rounded-full",
        tom === "ok" ? "bg-ok" : tom === "atencao" ? "bg-atencao" : tom === "critico" ? "bg-critico" : tom === "lente" ? "bg-lente" : "bg-suave")} />
      {children}
    </span>
  );
}

export function Cabecalho({ titulo, descricao, acoes }: { titulo: string; descricao?: ReactNode; acoes?: ReactNode }) {
  return (
    <header className="mb-8 flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
      <div className="max-w-leitura">
        <h1 className="text-2xl">{titulo}</h1>
        {descricao && <p className="mt-2 text-suave">{descricao}</p>}
      </div>
      {acoes && <div className="flex flex-wrap gap-2">{acoes}</div>}
    </header>
  );
}

export function Secao({ titulo, descricao, children, acoes }: { titulo: string; descricao?: ReactNode; children: ReactNode; acoes?: ReactNode }) {
  return (
    <section className="mb-12">
      <div className="mb-4 flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 className="text-lg">{titulo}</h2>
          {descricao && <p className="mt-1 text-sm text-suave">{descricao}</p>}
        </div>
        {acoes}
      </div>
      {children}
    </section>
  );
}

export function Carregando({ linhas = 4, rotulo = "Carregando" }: { linhas?: number; rotulo?: string }) {
  return (
    <div role="status" aria-label={rotulo} className="flex flex-col gap-2">
      {Array.from({ length: linhas }, (_, i) => (
        <div key={i} className="h-12 animate-pulse rounded-medio bg-elevada" style={{ opacity: 1 - i * 0.15 }} />
      ))}
      <span className="sr-only">{rotulo}…</span>
    </div>
  );
}

export function Vazio({ titulo, children, icone }: { titulo: string; children?: ReactNode; icone?: ReactNode }) {
  return (
    <div className="flex flex-col items-start gap-2 rounded-grande border border-dashed border-linha px-6 py-8">
      {icone && <div className="text-suave">{icone}</div>}
      <p className="font-bold">{titulo}</p>
      {children && <div className="max-w-leitura text-sm text-suave">{children}</div>}
    </div>
  );
}

export function ErroCaixa({ erro, tentarDeNovo }: { erro: unknown; tentarDeNovo?: () => void }) {
  const msg = erro instanceof Error ? erro.message : String(erro);
  return (
    <div role="alert" className="flex flex-col gap-4 rounded-grande border border-critico/40 bg-critico-fundo px-6 py-4 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex items-start gap-2 text-critico">
        <AlertTriangle className="mt-1 h-4 w-4 shrink-0" aria-hidden />
        <p className="text-sm font-bold">{msg}</p>
      </div>
      {tentarDeNovo && <Botao tamanho="sm" icone={<RotateCw className="h-4 w-4" aria-hidden />} onClick={tentarDeNovo}>Tentar de novo</Botao>}
    </div>
  );
}

export function Campo({ rotulo, ajuda, erro, children, id }: { rotulo: string; ajuda?: string; erro?: string | null; children: ReactNode; id: string }) {
  return (
    <div className="flex flex-col gap-1">
      <label htmlFor={id} className="text-sm font-bold">{rotulo}</label>
      {children}
      {erro ? <p id={`${id}-erro`} className="text-xs font-bold text-critico">{erro}</p>
            : ajuda ? <p id={`${id}-ajuda`} className="text-xs text-suave">{ajuda}</p> : null}
    </div>
  );
}

export const entradaCls =
  "w-full rounded-medio border border-linha bg-superficie px-3 py-2 text-base text-tinta placeholder:text-suave " +
  "hover:border-suave focus:border-lente focus:outline-none focus:ring-2 focus:ring-lente/30 disabled:opacity-50 aria-[invalid=true]:border-critico";

export function Painel({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cx("rounded-grande border border-linha bg-superficie", className)}>{children}</div>;
}

export function Tabela({ children, rotulo }: { children: ReactNode; rotulo: string }) {
  return (
    <div className="overflow-x-auto rounded-grande border border-linha bg-superficie">
      <table className="w-full min-w-[640px] border-collapse text-left text-sm" aria-label={rotulo}>{children}</table>
    </div>
  );
}
export const th = "border-b border-linha px-4 py-3 text-xs font-bold text-suave";
export const td = "border-b border-linha/70 px-4 py-3 align-top";
export const tdn = td + " whitespace-nowrap";

// Mostra um objeto (payload/evidência) como lista de pares legível
export function Dados({ valor, nivel = 0 }: { valor: unknown; nivel?: number }) {
  if (valor == null || (typeof valor === "object" && Object.keys(valor as object).length === 0))
    return <span className="text-suave">—</span>;
  if (typeof valor !== "object") return <span className="break-words">{String(valor)}</span>;
  if (Array.isArray(valor))
    return (
      <ol className="flex flex-col gap-2">
        {valor.map((v, i) => <li key={i} className="rounded-medio bg-elevada px-3 py-2"><Dados valor={v} nivel={nivel + 1} /></li>)}
      </ol>
    );
  return (
    <dl className={cx("grid grid-cols-1 gap-x-4 gap-y-1 sm:grid-cols-[minmax(120px,max-content)_1fr]", nivel > 0 && "text-sm")}>
      {Object.entries(valor as Record<string, unknown>).map(([k, v]) => (
        <div key={k} className="contents">
          <dt className="text-suave">{k.replace(/_/g, " ")}</dt>
          <dd className="min-w-0"><Dados valor={v} nivel={nivel + 1} /></dd>
        </div>
      ))}
    </dl>
  );
}
