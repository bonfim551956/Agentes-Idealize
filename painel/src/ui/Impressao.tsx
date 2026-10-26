import { blocos, codigoCurto } from "../lib/impressao";

// A aprovação fica presa a este código: se a operação mudar depois que você viu, o desenho muda e o banco recusa.
export function Impressao({ hash, grande }: { hash: string; grande?: boolean }) {
  const b = blocos(hash);
  return (
    <div className="inline-flex items-center gap-3" aria-label={`Código de verificação ${codigoCurto(hash)}`}>
      <div className="flex overflow-hidden rounded-pequeno" aria-hidden>
        {b.map((x, i) => (
          <span key={i} className={grande ? "h-8 w-4" : "h-4 w-2"} style={{ background: x.cor }} />
        ))}
      </div>
      <span className={grande ? "text-base font-bold tracking-wide" : "text-xs text-suave"}>{codigoCurto(hash)}</span>
    </div>
  );
}
