import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Sessao, useSessao } from "./auth/Sessao";
import { Shell } from "./ui/Shell";
import { ErroPainel } from "./lib/erros";
import { VisaoGeral } from "./pages/VisaoGeral";
import { Aprovacoes } from "./pages/Aprovacoes";
import { Tarefas } from "./pages/Tarefas";
import { TarefaDetalhe } from "./pages/TarefaDetalhe";
import { Incidentes } from "./pages/Incidentes";
import { Pendencias } from "./pages/Pendencias";
import { Financeiro } from "./pages/Financeiro";
import { Agentes } from "./pages/Agentes";
import { Custos } from "./pages/Custos";
import { Auditoria } from "./pages/Auditoria";
import { Operacao } from "./pages/Operacao";
import { Usuarios } from "./pages/Usuarios";

const cliente = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 15_000,
      refetchOnWindowFocus: true,
      // erro de permissão/2FA não melhora tentando de novo
      retry: (n, e) => !(e instanceof ErroPainel && ["acesso", "2fa", "validacao"].includes(e.tipo)) && n < 2,
    },
  },
});

function Rotas() {
  const { eu } = useSessao();
  return (
    <Shell>
      <Routes>
        <Route path="/" element={<VisaoGeral />} />
        <Route path="/aprovacoes" element={<Aprovacoes />} />
        <Route path="/tarefas" element={<Tarefas />} />
        <Route path="/tarefas/:id" element={<TarefaDetalhe />} />
        <Route path="/incidentes" element={<Incidentes />} />
        <Route path="/pendencias" element={<Pendencias />} />
        <Route path="/financeiro" element={<Financeiro />} />
        <Route path="/agentes" element={<Agentes />} />
        <Route path="/custos" element={<Custos />} />
        {eu.pode.auditoria && <Route path="/auditoria" element={<Auditoria />} />}
        <Route path="/operacao" element={<Operacao />} />
        {eu.pode.administrar && <Route path="/usuarios" element={<Usuarios />} />}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Shell>
  );
}

export function App() {
  return (
    <QueryClientProvider client={cliente}>
      <BrowserRouter>
        <Sessao><Rotas /></Sessao>
      </BrowserRouter>
    </QueryClientProvider>
  );
}
