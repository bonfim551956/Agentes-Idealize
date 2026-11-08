import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { BrainCircuit } from "lucide-react";
import { rpc } from "../lib/api";
import { traduzir } from "../lib/erros";
import { Botao, Cabecalho, Carregando, ErroCaixa, Painel, Secao, Tabela, cx, entradaCls, td, th } from "../ui/base";

// Qual modelo de IA cada agente usa, por nível de dificuldade. Quem escolhe é a diretoria.
type Nivel = "rapido" | "avancado" | "maximo";
type Dados = {
  pode_editar: boolean;
  modelos: Record<Nivel, string>;
  tarefas: { id: string; nome: string; ajuda: string; nivel: Nivel; usado: string | null }[];
};

const NIVEL: Record<Nivel, { rotulo: string; ajuda: string }> = {
  rapido: { rotulo: "Rápido", ajuda: "Respostas simples e curtas. Mais barato e mais rápido." },
  avancado: { rotulo: "Avançado", ajuda: "Perguntas sobre os números e leitura de comprovantes." },
  maximo: { rotulo: "Máximo", ajuda: "O mais inteligente: investigar erro, achar divergência, ler extrato inteiro." },
};
const MODELOS = [
  ["claude-fable-5-1", "Claude Fable 5.1 (o mais inteligente)"],
  ["claude-opus-5-5", "Claude Opus 5.5"],
  ["claude-sonnet-5-5", "Claude Sonnet 5.5"],
  ["claude-haiku-5-5", "Claude Haiku 5.5 (o mais simples)"],
] as const;
const nomeModelo = (m: string | null) => MODELOS.find(([k]) => k === m)?.[1].replace(/ \(.*\)$/, "") ?? m ?? "—";

export function Ia() {
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ["ia"], queryFn: () => rpc<Dados>("painel_ia") });
  const [mods, setMods] = useState<Partial<Record<Nivel, string>>>({});
  const [niv, setNiv] = useState<Record<string, Nivel>>({});
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [salvo, setSalvo] = useState(false);
  if (q.isLoading) return <Carregando linhas={5} />;
  if (q.error || !q.data) return <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} />;
  const d = q.data;
  const mudou = Object.keys(mods).length + Object.keys(niv).length > 0;
  async function salvar() {
    setEnviando(true); setErro(null); setSalvo(false);
    try {
      await rpc("painel_ia_salvar", { p_modelos: mods, p_niveis: niv });
      setMods({}); setNiv({}); setSalvo(true); void qc.invalidateQueries({ queryKey: ["ia"] });
    } catch (e) { setErro(traduzir(e).message); } finally { setEnviando(false); }
  }
  return (
    <>
      <Cabecalho titulo="Inteligência dos agentes"
        descricao="Cada tarefa usa o modelo de IA do nível que você escolher. Se o modelo escolhido não estiver disponível na hora, o agente usa o próximo da lista sozinho, para nunca ficar sem responder." />

      <Secao titulo="Os três níveis" descricao="Qual modelo vale para cada nível.">
        <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
          {(Object.keys(NIVEL) as Nivel[]).map((n) => (
            <Painel key={n} className="flex flex-col gap-2 p-4">
              <p className="font-bold">{NIVEL[n].rotulo}</p>
              <p className="text-sm text-suave">{NIVEL[n].ajuda}</p>
              <label className="sr-only" htmlFor={`ia-${n}`}>Modelo do nível {NIVEL[n].rotulo}</label>
              <select id={`ia-${n}`} className={entradaCls} disabled={!d.pode_editar} value={mods[n] ?? d.modelos[n]}
                onChange={(e) => setMods({ ...mods, [n]: e.target.value })}>
                {MODELOS.map(([k, r]) => <option key={k} value={k}>{r}</option>)}
              </select>
            </Painel>
          ))}
        </div>
      </Secao>

      <Secao titulo="Nível de cada tarefa">
        <Tabela rotulo="Nível de cada tarefa">
          <thead><tr><th className={th}>Tarefa</th><th className={th}>Nível</th><th className={th}>Modelo que vai usar</th><th className={th}>Último usado</th></tr></thead>
          <tbody>{d.tarefas.map((t) => {
            const nv = niv[t.id] ?? t.nivel;
            return (
              <tr key={t.id}>
                <td className={td}><span className="font-bold">{t.nome}</span><p className="text-xs text-suave">{t.ajuda}</p></td>
                <td className={td}>
                  <label className="sr-only" htmlFor={`nv-${t.id}`}>Nível de {t.nome}</label>
                  <select id={`nv-${t.id}`} className={cx(entradaCls, "w-40")} disabled={!d.pode_editar} value={nv}
                    onChange={(e) => setNiv({ ...niv, [t.id]: e.target.value as Nivel })}>
                    {(Object.keys(NIVEL) as Nivel[]).map((n) => <option key={n} value={n}>{NIVEL[n].rotulo}</option>)}
                  </select>
                </td>
                <td className={td}>{nomeModelo(mods[nv] ?? d.modelos[nv])}</td>
                <td className={td}>{nomeModelo(t.usado)}</td>
              </tr>
            );
          })}</tbody>
        </Tabela>
        <p className="mt-3 flex items-center gap-2 text-xs text-suave"><BrainCircuit className="h-4 w-4" aria-hidden />
          Os agentes de conteúdo, o Radar, os Concorrentes, o Auditor de atendimento e a Conferência de conversões rodam como tarefas agendadas do Claude, hoje no Claude Opus 5.5 (a troca delas é feita por mim, não por esta tela).</p>
      </Secao>

      {d.pode_editar && (
        <div className="flex items-center gap-3">
          <Botao variante="primario" carregando={enviando} disabled={!mudou} onClick={salvar}>Salvar</Botao>
          {erro && <p role="alert" className="text-sm font-bold text-critico">{erro}</p>}
          {salvo && <p role="status" className="text-sm font-bold text-ok">Salvo. Vale a partir da próxima resposta.</p>}
        </div>
      )}
    </>
  );
}
