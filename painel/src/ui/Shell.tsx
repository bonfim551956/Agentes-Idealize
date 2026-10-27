import { useEffect, useState, type ReactNode } from "react";
import { NavLink, useLocation } from "react-router-dom";
import * as Dialog from "@radix-ui/react-dialog";
import { useQuery } from "@tanstack/react-query";
import {
  Activity, Bot, CircleDollarSign, ClipboardCheck, FileSearch, Gauge, ListChecks, LogOut, Menu, Moon,
  ServerCog, ShieldAlert, Sun, Users, Wallet, X, AlertOctagon, FlaskConical, MessagesSquare, Megaphone, Landmark, HandCoins, UsersRound,
} from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type Resumo } from "../lib/api";
import { Marca } from "./Marca";
import { cx } from "./base";

type Item = { para: string; rotulo: string; icone: ReactNode; contagem?: number; urgente?: boolean };

function useTema() {
  const [tema, setTema] = useState<"claro" | "escuro">(() => {
    try {
      const s = localStorage.getItem("painel-tema");
      if (s === "claro" || s === "escuro") return s;
    } catch { /* sem storage */ }
    return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "escuro" : "claro";
  });
  useEffect(() => {
    document.documentElement.dataset.tema = tema;
    try { localStorage.setItem("painel-tema", tema); } catch { /* sem storage */ }
  }, [tema]);
  return [tema, () => setTema((t) => (t === "claro" ? "escuro" : "claro"))] as const;
}

export function useResumo() {
  return useQuery({ queryKey: ["resumo"], queryFn: () => rpc<Resumo>("painel_resumo"), refetchInterval: 30_000 });
}

function Navegacao({ aoNavegar }: { aoNavegar?: () => void }) {
  const { eu } = useSessao();
  const { data: r } = useResumo();
  const incidentes = r ? Object.values(r.incidentes).reduce((a, b) => a + b, 0) : undefined;
  const ic = "h-4 w-4 shrink-0";
  const grupos: { titulo: string; itens: Item[] }[] = [
    { titulo: "Precisa de decisão", itens: [
      { para: "/aprovacoes", rotulo: "Aprovações", icone: <ClipboardCheck className={ic} />, contagem: r?.aprovacoes_pendentes, urgente: true },
      { para: "/incidentes", rotulo: "Incidentes", icone: <ShieldAlert className={ic} />, contagem: incidentes, urgente: true },
      { para: "/pendencias", rotulo: "Pendências financeiras", icone: <AlertOctagon className={ic} />, contagem: r?.pendencias_fin.abertas },
    ] },
    { titulo: "Acompanhar", itens: [
      { para: "/", rotulo: "Visão geral", icone: <Gauge className={ic} /> },
      { para: "/tarefas", rotulo: "Tarefas", icone: <ListChecks className={ic} /> },
      { para: "/agentes", rotulo: "Agentes", icone: <Bot className={ic} /> },
      { para: "/financeiro", rotulo: "Financeiro por loja", icone: <Wallet className={ic} /> },
      { para: "/caixa", rotulo: "Caixa das lojas", icone: <Landmark className={ic} /> },
      { para: "/cobrancas", rotulo: "Cobranças", icone: <HandCoins className={ic} /> },
      { para: "/laboratorio", rotulo: "Laboratório", icone: <FlaskConical className={ic} /> },
      { para: "/comercial", rotulo: "Comercial", icone: <MessagesSquare className={ic} /> },
      { para: "/marketing", rotulo: "Marketing", icone: <Megaphone className={ic} /> },
      { para: "/rh", rotulo: "RH", icone: <UsersRound className={ic} /> },
      { para: "/custos", rotulo: "Custos de IA", icone: <CircleDollarSign className={ic} /> },
    ] },
    { titulo: "Controle", itens: [
      ...(eu.pode.auditoria ? [{ para: "/auditoria", rotulo: "Histórico auditado", icone: <FileSearch className={ic} /> }] : []),
      { para: "/operacao", rotulo: "Operação e integrações", icone: <ServerCog className={ic} /> },
      ...(eu.pode.administrar ? [{ para: "/usuarios", rotulo: "Pessoas e permissões", icone: <Users className={ic} /> }] : []),
    ] },
  ];
  return (
    <nav aria-label="Seções do painel" className="flex flex-col gap-6">
      {grupos.map((g) => (
        <div key={g.titulo}>
          <p className="mb-2 px-3 text-xs text-suave">{g.titulo}</p>
          <ul className="flex flex-col gap-1">
            {g.itens.map((i) => (
              <li key={i.para}>
                <NavLink to={i.para} end={i.para === "/"} onClick={aoNavegar}
                  className={({ isActive }) => cx(
                    "flex items-center gap-3 rounded-medio px-3 py-2 text-sm",
                    isActive ? "bg-lente-clara font-bold text-lente" : "text-tinta hover:bg-elevada")}>
                  {i.icone}
                  <span className="flex-1">{i.rotulo}</span>
                  {i.contagem ? (
                    <span className={cx("min-w-6 rounded-pequeno px-2 text-center text-xs font-bold",
                      i.urgente ? "bg-atencao-fundo text-atencao" : "bg-elevada text-suave")}
                      aria-label={`${i.contagem} em aberto`}>{i.contagem}</span>
                  ) : null}
                </NavLink>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </nav>
  );
}

function Rodape() {
  const { eu, sair, email } = useSessao();
  const [tema, alternar] = useTema();
  return (
    <div className="flex flex-col gap-2 border-t border-linha pt-4">
      <div className="px-3">
        <p className="text-sm font-bold">{eu.nome}</p>
        <p className="truncate text-xs text-suave">{email}</p>
      </div>
      <div className="flex gap-1">
        <button onClick={alternar} className="flex flex-1 items-center gap-2 rounded-medio px-3 py-2 text-sm hover:bg-elevada"
          aria-label={tema === "claro" ? "Usar tema escuro" : "Usar tema claro"}>
          {tema === "claro" ? <Moon className="h-4 w-4" aria-hidden /> : <Sun className="h-4 w-4" aria-hidden />}
          {tema === "claro" ? "Tema escuro" : "Tema claro"}
        </button>
        <button onClick={() => void sair()} className="flex items-center gap-2 rounded-medio px-3 py-2 text-sm hover:bg-elevada">
          <LogOut className="h-4 w-4" aria-hidden /> Sair
        </button>
      </div>
    </div>
  );
}

export function Shell({ children }: { children: ReactNode }) {
  const [menu, setMenu] = useState(false);
  const { data: r } = useResumo();
  const loc = useLocation();
  useEffect(() => { window.scrollTo(0, 0); }, [loc.pathname]);

  return (
    <div className="min-h-full lg:grid lg:grid-cols-[264px_1fr]">
      <aside className="sticky top-0 hidden h-screen flex-col gap-8 overflow-y-auto border-r border-linha bg-superficie px-4 py-6 lg:flex">
        <Marca className="px-3" />
        <div className="flex-1"><Navegacao /></div>
        <Rodape />
      </aside>

      <div className="sticky top-0 z-30 flex items-center justify-between border-b border-linha bg-superficie px-4 py-2 lg:hidden">
        <Marca compacta />
        <Dialog.Root open={menu} onOpenChange={setMenu}>
          <Dialog.Trigger asChild>
            <button className="rounded-medio p-2 hover:bg-elevada" aria-label="Abrir menu"><Menu className="h-5 w-5" /></button>
          </Dialog.Trigger>
          <Dialog.Portal>
            <Dialog.Overlay className="fixed inset-0 z-40 bg-tinta/40" />
            <Dialog.Content className="fixed inset-y-0 right-0 z-50 flex w-[300px] max-w-[85vw] flex-col gap-6 overflow-y-auto bg-superficie px-4 py-6">
              <div className="flex items-center justify-between">
                <Dialog.Title className="font-bold">Menu</Dialog.Title>
                <Dialog.Close asChild><button className="rounded-medio p-2 hover:bg-elevada" aria-label="Fechar menu"><X className="h-5 w-5" /></button></Dialog.Close>
              </div>
              <Dialog.Description className="sr-only">Navegação entre as seções do painel</Dialog.Description>
              <div className="flex-1"><Navegacao aoNavegar={() => setMenu(false)} /></div>
              <Rodape />
            </Dialog.Content>
          </Dialog.Portal>
        </Dialog.Root>
      </div>

      <div className="min-w-0">
        {r?.plataforma_pausada && (
          <div role="status" className="flex items-center gap-2 bg-atencao-fundo px-4 py-2 text-sm font-bold text-atencao lg:px-12">
            <Activity className="h-4 w-4" aria-hidden />
            Modo seguro ligado: os agentes não executam tarefas novas, só monitoramento.
          </div>
        )}
        <main className="mx-auto w-full max-w-[1200px] px-4 py-8 sm:px-8 lg:px-12 lg:py-12">{children}</main>
      </div>
    </div>
  );
}
