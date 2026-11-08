import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Sessao, useSessao } from "./auth/Sessao";
import { LojaTravada } from "./lib/loja";
import { Inicio } from "./pages/Inicio";
import { WhatsApp } from "./pages/WhatsApp";
import { Ia } from "./pages/Ia";
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
import { Laboratorio } from "./pages/Laboratorio";
import { Comercial } from "./pages/Comercial";
import { Marketing } from "./pages/Marketing";
import { Caixa } from "./pages/Caixa";
import { Cobrancas } from "./pages/Cobrancas";
import { Rh } from "./pages/Rh";
import { Atribuicao } from "./pages/Atribuicao";
import { Supervisor } from "./pages/Supervisor";
import { Enviar } from "./pages/Enviar";
import { Relatorio } from "./pages/Relatorio";
import { Mercado } from "./pages/Mercado";
import { Conteudo } from "./pages/Conteudo";
import { Multicredito } from "./pages/Multicredito";
import { OrigemVendas } from "./pages/OrigemVendas";
import { Atendimento } from "./pages/Atendimento";
import { Central } from "./pages/Central";

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
        <Route path="/" element={<Inicio />} />
        <Route path="/visao-geral" element={<VisaoGeral />} />
        <Route path="/relatorio" element={<Relatorio />} />
        <Route path="/mercado" element={<Mercado />} />
        <Route path="/conteudo" element={<Conteudo />} />
        <Route path="/multicrediario" element={<Multicredito />} />
        <Route path="/origem-vendas" element={<OrigemVendas />} />
        <Route path="/atendimento" element={<Atendimento />} />
        <Route path="/central" element={<Central />} />
        <Route path="/aprovacoes" element={<Aprovacoes />} />
        <Route path="/tarefas" element={<Tarefas />} />
        <Route path="/tarefas/:id" element={<TarefaDetalhe />} />
        <Route path="/incidentes" element={<Incidentes />} />
        <Route path="/pendencias" element={<Pendencias />} />
        <Route path="/financeiro" element={<Financeiro />} />
        <Route path="/agentes" element={<Agentes />} />
        <Route path="/laboratorio" element={<Laboratorio />} />
        <Route path="/comercial" element={<Comercial />} />
        <Route path="/marketing" element={<Marketing />} />
        <Route path="/caixa" element={<Caixa />} />
        <Route path="/cobrancas" element={<Cobrancas />} />
        <Route path="/rh" element={<Rh />} />
        <Route path="/retorno" element={<Atribuicao />} />
        <Route path="/supervisor" element={<Supervisor />} />
        <Route path="/enviar" element={<Enviar />} />
        <Route path="/custos" element={<Custos />} />
        {eu.pode.consultar_global && <Route path="/ia" element={<Ia />} />}
        {eu.pode.auditoria && <Route path="/auditoria" element={<Auditoria />} />}
        <Route path="/operacao" element={<Operacao />} />
        {eu.pode.administrar && <Route path="/usuarios" element={<Usuarios />} />}
        {eu.pode.administrar && <Route path="/whatsapp" element={<WhatsApp />} />}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Shell>
  );
}

export function App() {
  return (
    <QueryClientProvider client={cliente}>
      <BrowserRouter>
        <Sessao><LojaTravada><Rotas /></LojaTravada></Sessao>
      </BrowserRouter>
    </QueryClientProvider>
  );
}
