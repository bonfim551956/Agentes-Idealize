import { useState } from "react";
import { Link } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { CheckCircle2 } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc } from "../lib/api";
import { data, numero, rotuloUnidade } from "../lib/format";
import { Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Vazio, cx, entradaCls } from "../ui/base";

// Tudo o que precisa de alguém num lugar só: arquivos para conferir ou com erro, avisos do Caixa, Cobranças,
// Multicrediário, pendências financeiras e incidentes. Cada item leva para a tela onde se resolve.
type Item = { area: string; tipo: string; gravidade: number; unidade_id: string | null; dia: string | null; titulo: string; texto: string; link: string; desde: string };
type Area = { area: string; itens: number; urgentes: number; link: string };
type Dados = { total: number; urgentes: number; areas: Area[]; itens: Item[] };

const ROTULO_TIPO: Record<string, string> = {
  valor_diferente: "Valor diferente", valor_com_entrada: "ADM somou a entrada", centavos: "Centavos", venda_sem_adm: "Venda sem ADM",
  adm_sem_venda: "ADM sem venda", sem_os: "Sem OS", data_diferente: "Data diferente", parcela_sem_baixa: "Parcela sem baixa",
  parcela_sem_carne: "Carnê fora do ADM", documento_pendente: "Documento",
};

export function Central() {
  const { eu } = useSessao();
  const [area, setArea] = useState("");
  const [unidade, setUnidade] = useState("");
  const [so, setSo] = useState(false);
  const q = useQuery({ queryKey: ["central", unidade], queryFn: () => rpc<Dados>("painel_central", { p_unidade: unidade || null }), refetchInterval: 120_000 });
  const d = q.data;
  const itens = (d?.itens ?? []).filter((i) => (!area || i.area === area) && (!so || i.gravidade === 1));
  return (
    <>
      <Cabecalho titulo="Tudo para resolver"
        descricao={d ? `${numero(d.total)} itens abertos, ${numero(d.urgentes)} urgentes. Arquivos para conferir, erros de leitura e avisos dos agentes, num lugar só.`
          : "Arquivos para conferir, erros de leitura e avisos dos agentes, num lugar só."} />
      {q.isLoading ? <Carregando linhas={6} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : !d ? null : (
        <>
          <div className="mb-6 grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
            {d.areas.map((a) => (
              <button key={a.area} onClick={() => setArea(area === a.area ? "" : a.area)} aria-pressed={area === a.area}
                className={cx("rounded-grande border p-4 text-left", area === a.area ? "border-lente bg-lente-clara" : "border-linha bg-superficie hover:bg-elevada")}>
                <p className="text-xs text-suave">{a.area}</p>
                <p className={cx("text-2xl font-bold", a.urgentes > 0 && "text-critico")}>{numero(a.itens)}</p>
                <p className="text-xs text-suave">{a.urgentes > 0 ? `${numero(a.urgentes)} urgente(s)` : "nada urgente"}</p>
              </button>
            ))}
          </div>
          <div className="mb-6 flex flex-wrap items-center gap-3">
            <label className="sr-only" htmlFor="ce-un">Loja</label>
            <select id="ce-un" className={entradaCls + " sm:max-w-xs"} value={unidade} onChange={(e) => setUnidade(e.target.value)}>
              <option value="">Todas as lojas</option>{eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
            </select>
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={so} onChange={(e) => setSo(e.target.checked)} />Só urgentes</label>
            {area && <button className="text-sm text-lente underline" onClick={() => setArea("")}>Ver todas as áreas</button>}
          </div>
          {!itens.length ? <Vazio titulo="Nada para resolver" icone={<CheckCircle2 className="h-6 w-6" />}>Tudo em dia por aqui.</Vazio> : (
            <ul className="flex flex-col gap-2">
              {itens.map((i, k) => (
                <li key={`${i.area}-${k}`}>
                  <Painel className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
                    <div className="min-w-0">
                      <div className="mb-1 flex flex-wrap items-center gap-2">
                        <Etiqueta tom={i.gravidade === 1 ? "critico" : i.gravidade === 2 ? "atencao" : "neutro"}>{i.area} · {ROTULO_TIPO[i.tipo] ?? i.tipo}</Etiqueta>
                        <span className="text-xs text-suave">{i.unidade_id ? rotuloUnidade(i.unidade_id, eu.unidades) : "Rede"}{i.dia ? ` · ${data(i.dia)}` : ""}</span>
                      </div>
                      <p className="font-bold">{i.titulo}</p>
                      <p className="text-sm text-suave">{i.texto}</p>
                    </div>
                    <Link to={i.link} className="shrink-0 rounded-medio border border-linha px-3 py-2 text-sm font-bold hover:bg-elevada">Resolver</Link>
                  </Painel>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </>
  );
}
