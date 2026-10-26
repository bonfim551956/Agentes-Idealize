import { cx } from "./base";

// Marca: uma lente vista de frente (aro + centro óptico)
export function Marca({ className, compacta }: { className?: string; compacta?: boolean }) {
  return (
    <div className={cx("flex items-center gap-2", className)}>
      <svg viewBox="0 0 32 32" className="h-8 w-8" aria-hidden>
        <rect width="32" height="32" rx="8" className="fill-lente" />
        <circle cx="16" cy="16" r="8" fill="none" strokeWidth="3" className="stroke-superficie" />
        <circle cx="16" cy="16" r="2.5" className="fill-superficie" />
      </svg>
      {!compacta && (
        <span className="leading-tight">
          <span className="block font-bold">Idealize AI</span>
          <span className="block text-xs text-suave">Painel da plataforma</span>
        </span>
      )}
    </div>
  );
}
