import type { ReactNode } from "react";
import { Loader2 } from "lucide-react";
import { Marca } from "../ui/Marca";

export function TelaCentral({ titulo, children, carregando }: { titulo: string; children?: ReactNode; carregando?: boolean }) {
  return (
    <main className="flex min-h-full items-center justify-center px-4 py-12">
      <div className="w-full max-w-md">
        <Marca className="mb-12" />
        <h1 className="flex items-center gap-2 text-xl">
          {carregando && <Loader2 className="h-5 w-5 animate-spin text-lente" aria-hidden />}
          {titulo}
        </h1>
        {children && <div className="mt-4 text-suave">{children}</div>}
      </div>
    </main>
  );
}
