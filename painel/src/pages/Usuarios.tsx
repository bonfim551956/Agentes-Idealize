import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link2, Plus, UserCheck, UserX, X } from "lucide-react";
import { rpc, type Usuarios as U } from "../lib/api";
import { data, dinheiro, PAPEL } from "../lib/format";
import { Botao, Cabecalho, Campo, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, entradaCls, td, th } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

type Pessoa = U["principais"][number];

function ConcederPapel({ pessoa, u, aoConcluir }: { pessoa: Pessoa; u: U; aoConcluir: () => void }) {
  const [papel, setPapel] = useState("consulta");
  const [unidade, setUnidade] = useState("");
  const [validade, setValidade] = useState("");
  const papeis = u.papeis.filter((p) => !p.id.startsWith("agente_"));
  return (
    <Confirmar
      gatilho={<Botao tamanho="sm" icone={<Plus className="h-4 w-4" aria-hidden />}>Dar papel</Botao>}
      titulo={`Dar papel a ${pessoa.nome}`} rotuloConfirmar="Dar papel"
      descricao="O papel vale na próxima ação da pessoa. O que cada papel pode fazer está na tabela de políticas abaixo."
      detalhes={
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Campo id="np-papel" rotulo="Papel">
            <select id="np-papel" className={entradaCls} value={papel} onChange={(e) => { setPapel(e.target.value); if (e.target.value === "admin") setUnidade(""); }}>
              {papeis.map((p) => <option key={p.id} value={p.id}>{PAPEL[p.id] ?? p.nome}</option>)}
            </select>
          </Campo>
          <Campo id="np-unidade" rotulo="Onde vale">
            <select id="np-unidade" className={entradaCls} value={unidade} disabled={papel === "admin"} onChange={(e) => setUnidade(e.target.value)}>
              <option value="">Todas as unidades</option>
              {u.unidades.filter((x) => x.ativo).map((x) => <option key={x.id} value={x.id}>{x.nome}</option>)}
            </select>
          </Campo>
          <Campo id="np-validade" rotulo="Vale até (opcional)" ajuda="Em branco, vale até ser revogado.">
            <input id="np-validade" type="date" className={entradaCls} value={validade} onChange={(e) => setValidade(e.target.value)} />
          </Campo>
        </div>
      }
      motivo={{ rotulo: "Motivo", minimo: 5 }}
      aoConfirmar={(m) => rpc("painel_papel_conceder", {
        p_principal: pessoa.id, p_papel: papel, p_unidade: unidade || null,
        p_valido_ate: validade ? `${validade}T23:59:59-03:00` : null, p_motivo: m })}
      aoConcluir={aoConcluir} />
  );
}

function VincularLogin({ pessoa, aoConcluir }: { pessoa: Pessoa; aoConcluir: () => void }) {
  const [email, setEmail] = useState("");
  return (
    <Confirmar
      gatilho={<Botao tamanho="sm" icone={<Link2 className="h-4 w-4" aria-hidden />}>{pessoa.vinculado ? "Trocar login" : "Vincular login"}</Botao>}
      titulo={`Vincular login a ${pessoa.nome}`} rotuloConfirmar="Vincular"
      descricao="Crie antes o usuário (e-mail e senha) em Supabase, Authentication. A pessoa vai cadastrar o autenticador no primeiro acesso."
      detalhes={<Campo id="vl-email" rotulo="E-mail do login"><input id="vl-email" type="email" className={entradaCls} value={email} onChange={(e) => setEmail(e.target.value)} /></Campo>}
      motivo={{ rotulo: "Motivo", minimo: 5 }}
      aoConfirmar={(m) => rpc("painel_usuario_vincular", { p_principal: pessoa.id, p_email: email, p_motivo: m })}
      aoConcluir={aoConcluir} />
  );
}

const RECURSO_LIVRE = "";
function NovaPolitica({ u, aoConcluir }: { u: U; aoConcluir: () => void }) {
  const [f, setF] = useState({ papel: "financeiro", recurso: RECURSO_LIVRE, operacao: "", categoria: "aprovacao", risco: "medio",
    unidade: "", limite: "", aprovadores: "1", papel_aprovador: "diretoria" });
  const m = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }));
  return (
    <Confirmar
      gatilho={<Botao icone={<Plus className="h-4 w-4" aria-hidden />}>Nova versão de política</Botao>}
      titulo="Definir política" rotuloConfirmar="Salvar política"
      descricao="Se já existir política para o mesmo papel, operação e unidade, ela é encerrada e esta vira a nova versão. Nada é apagado."
      detalhes={
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Campo id="po-papel" rotulo="Papel"><select id="po-papel" className={entradaCls} value={f.papel} onChange={m("papel")}>
            {u.papeis.map((p) => <option key={p.id} value={p.id}>{PAPEL[p.id] ?? p.nome}</option>)}</select></Campo>
          <Campo id="po-cat" rotulo="Decisão"><select id="po-cat" className={entradaCls} value={f.categoria} onChange={m("categoria")}>
            <option value="automatica">Automática</option><option value="aprovacao">Exige aprovação</option><option value="proibida">Proibida</option></select></Campo>
          <Campo id="po-rec" rotulo="Recurso" ajuda="Ex.: fin.lancamento"><input id="po-rec" className={entradaCls} value={f.recurso} onChange={m("recurso")} /></Campo>
          <Campo id="po-op" rotulo="Operação" ajuda="Ex.: registrar_comprovante"><input id="po-op" className={entradaCls} value={f.operacao} onChange={m("operacao")} /></Campo>
          <Campo id="po-risco" rotulo="Risco"><select id="po-risco" className={entradaCls} value={f.risco} onChange={m("risco")}>
            {["baixo", "medio", "alto", "critico"].map((r) => <option key={r}>{r}</option>)}</select></Campo>
          <Campo id="po-un" rotulo="Onde vale"><select id="po-un" className={entradaCls} value={f.unidade} onChange={m("unidade")}>
            <option value="">Todas as unidades</option>{u.unidades.map((x) => <option key={x.id} value={x.id}>{x.nome}</option>)}</select></Campo>
          <Campo id="po-lim" rotulo="Automática até (R$)" ajuda="Opcional. Acima disso exige aprovação."><input id="po-lim" inputMode="decimal" className={entradaCls} value={f.limite} onChange={m("limite")} /></Campo>
          {f.categoria === "aprovacao" && (<>
            <Campo id="po-apr" rotulo="Quem aprova"><select id="po-apr" className={entradaCls} value={f.papel_aprovador} onChange={m("papel_aprovador")}>
              {u.papeis.filter((p) => !p.id.startsWith("agente_")).map((p) => <option key={p.id} value={p.id}>{PAPEL[p.id] ?? p.nome}</option>)}</select></Campo>
            <Campo id="po-n" rotulo="Aprovações necessárias"><select id="po-n" className={entradaCls} value={f.aprovadores} onChange={m("aprovadores")}>
              {["1", "2", "3"].map((n) => <option key={n}>{n}</option>)}</select></Campo>
          </>)}
        </div>
      }
      motivo={{ rotulo: "Motivo da mudança", minimo: 5 }}
      aoConfirmar={(mot) => rpc("painel_politica_definir", {
        p_papel: f.papel, p_recurso: f.recurso.trim(), p_operacao: f.operacao.trim(), p_categoria: f.categoria, p_risco: f.risco,
        p_unidade: f.unidade || null, p_limite: f.limite ? Number(f.limite.replace(/\./g, "").replace(",", ".")) : null,
        p_aprovadores: Number(f.aprovadores), p_papel_aprovador: f.categoria === "aprovacao" ? f.papel_aprovador : null, p_motivo: mot })}
      aoConcluir={aoConcluir} />
  );
}

export function Usuarios() {
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ["usuarios"], queryFn: () => rpc<U>("painel_usuarios") });
  const concluir = () => { void qc.invalidateQueries(); };
  if (q.isLoading) return <Carregando linhas={6} />;
  if (q.error) return <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} />;
  const u = q.data!;
  const unidadeNome = (id: string | null) => (id ? u.unidades.find((x) => x.id === id)?.nome ?? id : "todas as unidades");
  const pessoas = u.principais.filter((p) => p.tipo === "usuario");
  const agentes = u.principais.filter((p) => p.tipo === "agente");

  return (
    <>
      <Cabecalho titulo="Pessoas e permissões"
        descricao="Quem acessa, com que papel e em quais unidades. Você não altera o próprio acesso por aqui, e as permissões do administrador só mudam por mudança revisada no banco." />
      <Secao titulo="Pessoas">
        <ul className="flex flex-col gap-2">
          {pessoas.map((p) => (
            <li key={p.id}>
              <Painel className="flex flex-col gap-4 p-4 lg:flex-row lg:items-start lg:justify-between">
                <div>
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-bold">{p.nome}{p.eu && " (você)"}</h3>
                    {!p.ativo && <Etiqueta tom="critico">Sem acesso</Etiqueta>}
                    <Etiqueta tom={p.vinculado ? "ok" : "neutro"}>{p.vinculado ? "Login vinculado" : "Sem login no painel"}</Etiqueta>
                  </div>
                  {p.telefone && <p className="mt-1 text-sm text-suave">WhatsApp terminado em {p.telefone.slice(-4)}</p>}
                  <ul className="mt-2 flex flex-wrap gap-2" aria-label="Papéis">
                    {p.papeis.length ? p.papeis.map((pp) => (
                      <li key={`${pp.papel}-${pp.unidade}`} className="inline-flex items-center gap-1 rounded-pequeno bg-lente-clara py-1 pl-2 pr-1 text-xs font-bold text-lente">
                        {PAPEL[pp.papel] ?? pp.papel}, {unidadeNome(pp.unidade)}{pp.valido_ate && `, até ${data(pp.valido_ate)}`}
                        {!p.eu && (
                          <Confirmar
                            gatilho={<button className="rounded-pequeno p-1 hover:bg-lente/20" aria-label={`Revogar ${PAPEL[pp.papel] ?? pp.papel} de ${p.nome}`}><X className="h-3 w-3" /></button>}
                            titulo="Revogar papel?" rotuloConfirmar="Revogar" variante="perigo"
                            descricao={`${p.nome} perde o papel ${PAPEL[pp.papel] ?? pp.papel} em ${unidadeNome(pp.unidade)} na próxima ação.`}
                            motivo={{ rotulo: "Motivo", minimo: 5 }}
                            aoConfirmar={(m) => rpc("painel_papel_revogar", { p_principal: p.id, p_papel: pp.papel, p_unidade: pp.unidade, p_motivo: m })}
                            aoConcluir={concluir} />
                        )}
                      </li>
                    )) : <li className="text-sm text-suave">Nenhum papel: não vê nada no painel.</li>}
                  </ul>
                </div>
                {!p.eu && (
                  <div className="flex shrink-0 flex-wrap gap-2">
                    <ConcederPapel pessoa={p} u={u} aoConcluir={concluir} />
                    <VincularLogin pessoa={p} aoConcluir={concluir} />
                    <Confirmar
                      gatilho={<Botao tamanho="sm" variante={p.ativo ? "fantasma" : "primario"} icone={p.ativo ? <UserX className="h-4 w-4" aria-hidden /> : <UserCheck className="h-4 w-4" aria-hidden />}>{p.ativo ? "Suspender acesso" : "Reativar acesso"}</Botao>}
                      titulo={p.ativo ? `Suspender ${p.nome}?` : `Reativar ${p.nome}?`} rotuloConfirmar={p.ativo ? "Suspender" : "Reativar"} variante={p.ativo ? "perigo" : "primario"}
                      descricao={p.ativo ? "A pessoa perde o acesso ao painel e ao WhatsApp do financeiro na hora. Os papéis ficam guardados." : "A pessoa volta a ter os papéis que já tinha."}
                      motivo={{ rotulo: "Motivo", minimo: 5 }}
                      aoConfirmar={(m) => rpc("painel_usuario_ativo", { p_principal: p.id, p_ativo: !p.ativo, p_motivo: m })} aoConcluir={concluir} />
                  </div>
                )}
              </Painel>
            </li>
          ))}
        </ul>
        <p className="mt-4 text-sm text-suave">Agentes ({agentes.map((a) => a.nome).join(", ")}) têm papéis próprios de máquina e não são gerenciados aqui.</p>
      </Secao>

      <Secao titulo="Políticas vigentes" descricao="A matriz que decide o que é automático, o que exige aprovação e o que é proibido. Sem política, a resposta é não."
        acoes={<NovaPolitica u={u} aoConcluir={concluir} />}>
        <Tabela rotulo="Políticas vigentes">
          <thead><tr><th className={th}>Papel</th><th className={th}>Operação</th><th className={th}>Onde</th><th className={th}>Decisão</th><th className={th}>Risco</th><th className={th}>Desde</th></tr></thead>
          <tbody>{u.politicas.map((p) => (
            <tr key={p.id}>
              <td className={td}>{PAPEL[p.papel] ?? p.papel}</td>
              <td className={td}><span className="font-bold">{p.recurso}.{p.operacao}</span><span className="block text-xs text-suave">nº {p.id}, versão {p.versao}</span></td>
              <td className={td}>{unidadeNome(p.unidade)}</td>
              <td className={td}>
                <Etiqueta tom={p.categoria === "proibida" ? "critico" : p.categoria === "aprovacao" ? "atencao" : "ok"}>
                  {p.categoria === "automatica" ? "Automática" : p.categoria === "aprovacao" ? "Aprovação" : "Proibida"}
                </Etiqueta>
                {p.categoria === "aprovacao" && <span className="mt-1 block text-xs text-suave">{p.aprovadores_minimos}× {PAPEL[p.papel_aprovador ?? ""] ?? p.papel_aprovador}</span>}
                {p.limite_valor != null && <span className="mt-1 block text-xs text-suave">automática até {dinheiro(p.limite_valor)}</span>}
              </td>
              <td className={td}>{p.risco}</td>
              <td className={td}>{data(p.valido_de)}</td>
            </tr>
          ))}</tbody>
        </Tabela>
      </Secao>
    </>
  );
}
