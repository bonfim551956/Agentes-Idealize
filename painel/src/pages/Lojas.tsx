import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Plus, Store } from "lucide-react";
import { rpc } from "../lib/api";
import { data } from "../lib/format";
import { Botao, Cabecalho, Campo, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, cx, entradaCls, td, tdn, th } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

// Lojas da rede: ativar/desativar e cadastrar loja nova. Loja desativada some do painel, do relatório e do WhatsApp;
// os agentes continuam lendo os dados dela, para tudo voltar em dia quando ela for ativada.
type Loja = { id: string; nome: string; ativa: boolean; criada_em: string; codigo_adm: string | null; codigo_rh: string | null;
  funis: number; contas_anuncio: number; contas_banco: number; pessoas: number };

const slug = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 30);

function NovaLoja({ aoSalvar, aoCancelar }: { aoSalvar: () => void; aoCancelar: () => void }) {
  const [nome, setNome] = useState("");
  const [adm, setAdm] = useState("");
  const [rh, setRh] = useState("");
  const [ativa, setAtiva] = useState(true);
  const id = slug(nome);
  const ok = nome.trim().length >= 3 && /^[a-z][a-z0-9_]{2,30}$/.test(id);
  return (
    <Painel className="mb-8 flex flex-col gap-4 p-6">
      <p className="text-lg font-bold">Nova loja</p>
      <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <Campo id="nl-nome" rotulo="Nome da loja" ajuda={id ? `Código no painel: ${id}` : "Ex.: Santos"}>
          <input id="nl-nome" className={entradaCls} value={nome} onChange={(e) => setNome(e.target.value)} />
        </Campo>
        <Campo id="nl-adm" rotulo="Nome da loja no ADM e no Lab" ajuda="Como aparece no sistema da loja, sem espaço. Ex.: saovicente">
          <input id="nl-adm" className={entradaCls} value={adm} onChange={(e) => setAdm(e.target.value.toLowerCase().replace(/\s+/g, ""))} />
        </Campo>
        <Campo id="nl-rh" rotulo="Nome da loja no RH 360" ajuda="Ex.: SAOVICENTE">
          <input id="nl-rh" className={entradaCls} value={rh} onChange={(e) => setRh(e.target.value.toUpperCase().replace(/\s+/g, ""))} />
        </Campo>
      </div>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" className="h-4 w-4" checked={ativa} onChange={(e) => setAtiva(e.target.checked)} />
        Já começar ativa (os agentes passam a mostrar os avisos dela no painel)</label>
      <p className="text-sm text-suave">Depois de criar: escolha o funil da Kommo em Comercial e a conta de anúncio em Marketing. A conta do banco eu cadastro quando chegar o primeiro extrato.</p>
      <div className="flex gap-2">
        <Confirmar gatilho={<Botao variante="primario" disabled={!ok}>Criar loja</Botao>} titulo={`Criar a loja ${nome.trim()}?`} rotuloConfirmar="Criar loja"
          descricao={`Código ${id}${adm ? `, ADM/Lab "${adm}"` : ""}${rh ? `, RH 360 "${rh}"` : ""}. ${ativa ? "Começa ativa." : "Começa desativada."}`}
          motivo={{ rotulo: "Motivo", minimo: 5 }}
          aoConfirmar={(m) => rpc("painel_loja_salvar", { p_id: id, p_nome: nome.trim(), p_ativa: ativa, p_codigo_adm: adm || null, p_codigo_rh: rh || null, p_motivo: m })}
          aoConcluir={aoSalvar} />
        <Botao variante="fantasma" onClick={aoCancelar}>Cancelar</Botao>
      </div>
    </Painel>
  );
}

export function Lojas() {
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ["lojas"], queryFn: () => rpc<Loja[]>("painel_lojas") });
  const [nova, setNova] = useState(false);
  const recarregar = () => { setNova(false); void qc.invalidateQueries(); };
  return (
    <>
      <Cabecalho titulo="Lojas"
        descricao="Ative só as lojas que os agentes devem acompanhar agora. Loja desativada some do painel, do relatório do dia e dos avisos no WhatsApp; os agentes continuam lendo os dados dela, e tudo volta em dia quando você ativar de novo."
        acoes={!nova ? <Botao variante="primario" icone={<Plus className="h-4 w-4" aria-hidden />} onClick={() => setNova(true)}>Nova loja</Botao> : undefined} />
      {nova && <NovaLoja aoSalvar={recarregar} aoCancelar={() => setNova(false)} />}
      {q.isLoading ? <Carregando linhas={4} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (
        <Secao titulo="Lojas da rede">
          <Tabela rotulo="Lojas da rede">
            <thead><tr><th className={th}>Loja</th><th className={th}>Situação</th><th className={th}>Nome no ADM / Lab</th><th className={th}>Nome no RH 360</th>
              <th className={th}>Ligações</th><th className={th}><span className="sr-only">Ação</span></th></tr></thead>
            <tbody>{q.data!.map((l) => (
              <tr key={l.id} className={cx(!l.ativa && "opacity-70")}>
                <td className={td}><span className="font-bold">{l.nome}</span><p className="text-xs text-suave">{l.id} · desde {data(l.criada_em)}</p></td>
                <td className={td}>{l.ativa ? <Etiqueta tom="ok">Ativa</Etiqueta> : <Etiqueta tom="neutro">Desativada</Etiqueta>}</td>
                <td className={tdn}>{l.codigo_adm ?? <span className="text-suave">—</span>}</td>
                <td className={tdn}>{l.codigo_rh ?? <span className="text-suave">—</span>}</td>
                <td className={cx(td, "text-sm text-suave")}>{l.funis} funil(is) Kommo · {l.contas_anuncio} conta(s) de anúncio · {l.contas_banco} conta(s) do banco · {l.pessoas} pessoa(s)</td>
                <td className={td}>
                  <Confirmar gatilho={<Botao tamanho="sm" variante={l.ativa ? "secundario" : "primario"}>{l.ativa ? "Desativar" : "Ativar"}</Botao>}
                    titulo={`${l.ativa ? "Desativar" : "Ativar"} ${l.nome}?`} rotuloConfirmar={l.ativa ? "Desativar" : "Ativar"}
                    descricao={l.ativa ? "A loja some do painel, do relatório do dia e dos avisos no WhatsApp. Nenhum dado é apagado e os agentes continuam lendo." : "A loja volta a aparecer em todas as telas, com os avisos já em dia."}
                    motivo={{ rotulo: "Motivo", minimo: 5 }}
                    aoConfirmar={(m) => rpc("painel_loja_salvar", { p_id: l.id, p_nome: l.nome, p_ativa: !l.ativa, p_codigo_adm: null, p_codigo_rh: null, p_motivo: m })}
                    aoConcluir={recarregar} />
                </td>
              </tr>
            ))}</tbody>
          </Tabela>
          <p className="mt-3 flex items-center gap-2 text-xs text-suave"><Store className="h-4 w-4" aria-hidden />"Administrativo / Grupo" é a estrutura central (despesas do grupo); deixe sempre ativa.</p>
        </Secao>
      )}
    </>
  );
}
