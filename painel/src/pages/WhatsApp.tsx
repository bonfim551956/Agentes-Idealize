import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { MessageCircle } from "lucide-react";
import { rpc } from "../lib/api";
import { traduzir } from "../lib/erros";
import { relativo } from "../lib/format";
import { Botao, Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Vazio, cx } from "../ui/base";

// Agente no WhatsApp direto com a diretoria: ligar/desligar e ver as últimas mensagens.
type Msg = { id: number; direcao: "entrada" | "saida"; tipo: string; origem: string; texto: string | null; arquivo: string | null; status: string; erro: string | null; em: string; final: string };
type Dados = { ativo: boolean; urgencias: boolean; resumos: boolean; horarios_resumo: string; papeis: string; autorizados: { nome: string; final: string }[]; mensagens: Msg[] };

const ORIGEM: Record<string, string> = { conversa: "Você", resposta: "Agente", urgencia: "Urgência", arquivo: "Arquivo", resumo: "Resumo" };

function Chave({ id, rotulo, ajuda, valor, aoMudar }: { id: string; rotulo: string; ajuda: string; valor: boolean; aoMudar: (v: boolean) => void }) {
  return (
    <label htmlFor={id} className="flex cursor-pointer items-start gap-3 rounded-medio border border-linha p-4 hover:bg-elevada">
      <input id={id} type="checkbox" className="mt-1 h-5 w-5" checked={valor} onChange={(e) => aoMudar(e.target.checked)} />
      <span><span className="block font-bold">{rotulo}</span><span className="block text-sm text-suave">{ajuda}</span></span>
    </label>
  );
}

export function WhatsApp() {
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ["whatsapp"], queryFn: () => rpc<Dados>("painel_whatsapp"), refetchInterval: 30_000 });
  const [f, setF] = useState<{ ativo: boolean; urgencias: boolean; resumos: boolean } | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [salvo, setSalvo] = useState(false);
  if (q.isLoading) return <Carregando linhas={5} />;
  if (q.error || !q.data) return <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} />;
  const d = q.data;
  const v = f ?? { ativo: d.ativo, urgencias: d.urgencias, resumos: d.resumos };
  const mudou = v.ativo !== d.ativo || v.urgencias !== d.urgencias || v.resumos !== d.resumos;
  async function salvar() {
    setEnviando(true); setErro(null); setSalvo(false);
    try {
      await rpc("painel_whatsapp_salvar", { p_ativo: v.ativo, p_urgencias: v.urgencias, p_resumos: v.resumos, p_motivo: null });
      setF(null); setSalvo(true); void qc.invalidateQueries({ queryKey: ["whatsapp"] });
    } catch (e) { setErro(traduzir(e).message); } finally { setEnviando(false); }
  }
  return (
    <>
      <Cabecalho titulo="WhatsApp do agente"
        descricao="Converse com os agentes pelo WhatsApp: pergunte, comente avisos, mande extratos e receba resumos e urgências. Só números da diretoria cadastrados no painel." />
      <div className="mb-8 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <Painel className="flex flex-col gap-3 p-6">
          <Chave id="wa-ativo" rotulo="Agente no WhatsApp ligado" valor={v.ativo} aoMudar={(x) => setF({ ...v, ativo: x })}
            ajuda="Responde perguntas, registra conversas nos avisos e recebe arquivos mandados no privado. Desligado, só repassa as mensagens para onde iam antes." />
          <Chave id="wa-urg" rotulo="Avisar urgências na hora" valor={v.urgencias} aoMudar={(x) => setF({ ...v, urgencias: x })}
            ajuda="A cada 5 minutos: Pix/Asaas não achado, dinheiro que entrou sem caixa, caixa não fechado, Multicrediário fora do caixa, divergência no Asaas, arquivo com erro e falha grave." />
          <Chave id="wa-res" rotulo={`Resumos do dia (${d.horarios_resumo.split(",").map((h) => `${h}h`).join(", ")})`} valor={v.resumos} aoMudar={(x) => setF({ ...v, resumos: x })}
            ajuda="O Supervisor manda o que precisa da diretoria nesses horários." />
          {erro && <p role="alert" className="text-sm font-bold text-critico">{erro}</p>}
          {salvo && <p role="status" className="text-sm font-bold text-ok">Salvo.</p>}
          <div><Botao variante="primario" carregando={enviando} disabled={!mudou} onClick={salvar}>Salvar</Botao></div>
        </Painel>
        <Painel className="p-6 text-sm">
          <p className="mb-2 font-bold">Quem pode falar com o agente</p>
          {!d.autorizados.length ? <p className="text-suave">Ninguém: cadastre o telefone da pessoa em Pessoas e permissões.</p> : (
            <ul className="mb-3 flex flex-col gap-1">{d.autorizados.map((a) => <li key={a.final}>{a.nome} · final {a.final}</li>)}</ul>
          )}
          <p className="text-suave">Papéis com acesso: {d.papeis.replace(/,/g, ", ")}. Mensagens de grupo e de outros números seguem para onde iam antes.</p>
          <p className="mt-3 font-bold">Como usar</p>
          <ul className="mt-1 list-disc pl-5 text-suave">
            <li>Pergunte: "o caixa de São Vicente de ontem bateu?"</li>
            <li>Comente um aviso: "o Pix de R$ 150 do dia 23 caiu na conta de Campinas"</li>
            <li>Mande o extrato com a loja na legenda: "extrato São Vicente"</li>
          </ul>
        </Painel>
      </div>

      <Secao titulo="Últimas mensagens" descricao="O que entrou e saiu pelo WhatsApp do agente (as 50 mais recentes).">
        {!d.mensagens.length ? <Vazio titulo="Nenhuma mensagem ainda" icone={<MessageCircle className="h-6 w-6" />} /> : (
          <ul className="flex flex-col gap-2">
            {d.mensagens.map((m) => (
              <li key={m.id} className={cx("flex", m.direcao === "saida" ? "justify-start" : "justify-end")}>
                <Painel className={cx("max-w-[85%] px-4 py-3 text-sm", m.direcao === "saida" ? "bg-lente-clara" : "")}>
                  <div className="mb-1 flex flex-wrap items-center gap-2 text-xs text-suave">
                    <Etiqueta tom={m.status === "erro" ? "critico" : m.origem === "urgencia" ? "atencao" : "neutro"}>{ORIGEM[m.origem] ?? m.origem}</Etiqueta>
                    <span>final {m.final} · {relativo(m.em)}{m.status === "erro" && m.erro ? ` · erro: ${m.erro}` : m.status === "pendente" ? " · enviando" : ""}</span>
                  </div>
                  {m.arquivo && <p className="font-bold">📎 {m.arquivo}</p>}
                  {m.texto && <p className="whitespace-pre-wrap">{m.texto}</p>}
                </Painel>
              </li>
            ))}
          </ul>
        )}
      </Secao>
    </>
  );
}
