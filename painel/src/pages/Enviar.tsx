import { useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { AlarmClock, CheckCircle2, FileUp, Upload } from "lucide-react";
import { useSessao } from "../auth/Sessao";
import { rpc, type EnviosPainel } from "../lib/api";
import { supabase } from "../lib/supabase";
import { traduzir } from "../lib/erros";
import { data, dataHora, dinheiro, numero, relativo, rotuloUnidade, type Tom } from "../lib/format";
import { Botao, Cabecalho, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, Vazio, cx, entradaCls, td, tdn, th } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

const TIPOS: [string, string][] = [["auto", "O sistema descobre"], ["extrato", "Extrato do banco"], ["fatura", "Fatura do cartão"],
  ["stone", "Relatório da Stone"], ["comprovante", "Comprovante de pagamento"], ["boleto", "Boleto a pagar"], ["nota", "Nota fiscal"]];
const ROTULO_TIPO: Record<string, string> = Object.fromEntries([...TIPOS, ["outro", "Não reconhecido"]]);
const STATUS: Record<string, { rotulo: string; tom: Tom }> = {
  aguardando_arquivo: { rotulo: "Enviando", tom: "neutro" }, recebido: { rotulo: "Na fila para leitura", tom: "neutro" },
  lendo: { rotulo: "Lendo", tom: "lente" }, conferir: { rotulo: "Para conferir", tom: "atencao" }, lancado: { rotulo: "Lançado", tom: "ok" },
  descartado: { rotulo: "Descartado", tom: "neutro" }, erro: { rotulo: "Erro", tom: "critico" },
};
type Envio = EnviosPainel["envios"][number];
type Resultado = { nome: string; ok: boolean; texto: string };

async function enviarArquivo(f: File, unidade: string, tipo: string, conta: string): Promise<Resultado> {
  const corpo = new FormData();
  corpo.append("unidade", unidade); corpo.append("tipo", tipo); if (conta) corpo.append("conta", conta); corpo.append("arquivo", f);
  const { data: r, error } = await supabase.functions.invoke("fin-envio", { body: corpo });
  if (error) {
    let msg = traduzir(error).message;
    try { const j = await (error as { context?: Response }).context?.json(); if (j?.erro) msg = j.erro; } catch { /* mantém a mensagem */ }
    return { nome: f.name, ok: false, texto: msg };
  }
  return { nome: f.name, ok: true, texto: r?.duplicado ? "já tinha sido enviado; não entrou de novo" : "recebido" };
}

function Linhas({ e, categorias, escolhas, setEscolha }: { e: Envio; categorias: EnviosPainel["categorias"];
  escolhas: Record<string, string>; setEscolha: (i: string, v: string) => void }) {
  const l = e.leitura;
  if (!l) return null;
  if (e.tipo === "extrato" && l.linhas) return (
    <Tabela rotulo={`Movimentos lidos de ${e.nome_arquivo}`}>
      <thead><tr><th className={th}>Data</th><th className={th}>Descrição</th><th className={th}>Valor</th></tr></thead>
      <tbody>{l.linhas.slice(0, 200).map((x, i) => (
        <tr key={i}><td className={tdn}>{data(x.data)}</td><td className={td}>{x.descricao}</td>
          <td className={cx(tdn, (x.valor ?? 0) < 0 && "text-critico")}>{x.valor == null ? "ilegível" : dinheiro(x.valor)}</td></tr>))}</tbody>
    </Tabela>);
  if (e.tipo === "fatura" && l.compras) return (
    <Tabela rotulo={`Compras lidas de ${e.nome_arquivo}`}>
      <thead><tr><th className={th}>Data</th><th className={th}>Compra</th><th className={th}>Valor</th><th className={th}>Categoria</th></tr></thead>
      <tbody>{l.compras.slice(0, 300).map((x, i) => {
        const k = String(i + 1);
        return (
          <tr key={i}><td className={tdn}>{data(x.data)}</td><td className={td}>{x.descricao}{x.parcela ? ` (${x.parcela})` : ""}</td>
            <td className={tdn}>{x.valor == null ? "ilegível" : dinheiro(x.valor)}</td>
            <td className={td}>{(x.valor ?? 0) <= 0 ? <span className="text-suave">não é compra</span> : (
              <><label className="sr-only" htmlFor={`cat-${e.id}-${k}`}>Categoria de {x.descricao}</label>
                <select id={`cat-${e.id}-${k}`} className={cx(entradaCls, "py-1")} value={escolhas[k] ?? x.categoria ?? ""} onChange={(ev) => setEscolha(k, ev.target.value)}>
                  <option value="">Classificar depois</option>
                  {categorias.map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
                </select></>)}</td></tr>);
      })}</tbody>
    </Tabela>);
  if (e.tipo === "stone" && l.transacoes) return (
    <Tabela rotulo={`Vendas lidas de ${e.nome_arquivo}`}>
      <thead><tr><th className={th}>Data</th><th className={th}>Forma</th><th className={th}>Valor bruto</th></tr></thead>
      <tbody>{l.transacoes.slice(0, 300).map((x, i) => (
        <tr key={i}><td className={tdn}>{data(x.data)}</td><td className={td}>{x.forma ?? "ilegível"}</td><td className={tdn}>{x.valor == null ? "ilegível" : dinheiro(x.valor)}</td></tr>))}</tbody>
    </Tabela>);
  if (l.itens) return (
    <Tabela rotulo={`Itens lidos de ${e.nome_arquivo}`}>
      <thead><tr><th className={th}>Favorecido</th><th className={th}>Data</th><th className={th}>Valor</th></tr></thead>
      <tbody>{l.itens.map((x, i) => (
        <tr key={i}><td className={td}>{x.favorecido ?? "—"}</td><td className={tdn}>{data(x.data ?? x.vencimento ?? null)}</td>
          <td className={tdn}>{x.valor == null ? "ilegível" : dinheiro(x.valor)}</td></tr>))}</tbody>
    </Tabela>);
  return null;
}

function Conferir({ e, r, aoConcluir }: { e: Envio; r: EnviosPainel; aoConcluir: () => void }) {
  const precisaConta = (e.tipo === "extrato" || e.tipo === "fatura") && !e.conta_id;
  const contas = r.contas.filter((c) => c.unidade_id === e.unidade_id && (e.tipo === "fatura" ? c.tipo === "cartao_credito" : c.tipo !== "cartao_credito"));
  const [conta, setConta] = useState("");
  const [escolhas, setEscolhas] = useState<Record<string, string>>({});
  const c = e.checagens;
  const fecha = c?.ok !== false && e.tipo !== "outro";
  return (
    <div className="mt-3 flex flex-col gap-3">
      <div className={cx("rounded-medio border px-3 py-2 text-sm", c?.ok === false ? "border-critico/40 bg-critico-fundo text-critico" : c?.ok ? "border-ok/40 bg-ok-fundo" : "border-atencao/40 bg-atencao-fundo text-atencao")}>
        {c?.ok === true && <p className="font-bold">As contas fecham: {numero(c.itens)} linha(s){c.esperado != null ? `, somando ${dinheiro(c.soma)} = ${dinheiro(c.esperado)}` : ""}.</p>}
        {c?.ok === false && <p className="font-bold">As contas não fecham. Não dá para lançar: confira o arquivo e envie de novo, ou descarte.</p>}
        {c?.ok == null && e.tipo !== "outro" && <p className="font-bold">Lido, mas sem total no arquivo para conferir: olhe as linhas com atenção.</p>}
        {(c?.avisos ?? []).map((a, i) => <p key={i}>{a}</p>)}
        {e.motivo && <p>{e.motivo}</p>}
      </div>
      <Linhas e={e} categorias={r.categorias} escolhas={escolhas} setEscolha={(i, v) => setEscolhas((s) => ({ ...s, [i]: v }))} />
      {e.pode_confirmar && (
        <div className="flex flex-wrap items-end gap-2">
          {precisaConta && fecha && (
            <div>
              <label className="mb-1 block text-xs text-suave" htmlFor={`conta-${e.id}`}>{e.tipo === "fatura" ? "Cartão desta fatura" : "Conta deste extrato"}</label>
              <select id={`conta-${e.id}`} className={entradaCls} value={conta} onChange={(ev) => setConta(ev.target.value)}>
                <option value="">Escolha…</option>
                {contas.map((x) => <option key={x.id} value={x.id}>{x.apelido}{x.final ? ` (final ${x.final})` : ""}</option>)}
              </select>
            </div>
          )}
          {fecha && (
            <Confirmar gatilho={<Botao tamanho="sm" variante="primario" disabled={precisaConta && !conta}>Conferi, pode lançar</Botao>}
              titulo="Lançar o que foi lido?" rotuloConfirmar="Lançar"
              descricao={`Confirme que as linhas acima batem com o arquivo ${e.nome_arquivo}. O lançamento fica registrado com o seu nome.`}
              aoConfirmar={() => rpc("painel_envio_confirmar", { p_id: e.id, p_conta: conta || null, p_categorias: escolhas })} aoConcluir={aoConcluir} />
          )}
          <Confirmar gatilho={<Botao tamanho="sm">Descartar</Botao>} titulo="Descartar este envio?" rotuloConfirmar="Descartar" variante="perigo"
            descricao="Nada é lançado. Você pode enviar o arquivo corrigido depois." motivo={{ rotulo: "Motivo", minimo: 3 }}
            aoConfirmar={(m) => rpc("painel_envio_descartar", { p_id: e.id, p_motivo: m })} aoConcluir={aoConcluir} />
        </div>
      )}
    </div>
  );
}

export function Enviar() {
  const { eu } = useSessao();
  const qc = useQueryClient();
  const [unidade, setUnidade] = useState(eu.unidades.length === 1 ? eu.unidades[0].id : "");
  const [tipo, setTipo] = useState("auto");
  const [conta, setConta] = useState("");
  const [arquivos, setArquivos] = useState<File[]>([]);
  const [enviando, setEnviando] = useState(false);
  const [resultados, setResultados] = useState<Resultado[]>([]);
  const [arrastando, setArrastando] = useState(false);
  const q = useQuery({ queryKey: ["envios"], queryFn: () => rpc<EnviosPainel>("painel_envios", { p_unidade: null }), refetchInterval: 30_000 });
  const contas = useMemo(() => (q.data?.contas ?? []).filter((c) => c.unidade_id === unidade
    && (tipo === "fatura" ? c.tipo === "cartao_credito" : tipo === "extrato" ? c.tipo !== "cartao_credito" : true)), [q.data, unidade, tipo]);
  const atualizar = () => { void qc.invalidateQueries({ queryKey: ["envios"] }); };

  async function enviar() {
    if (!unidade || !arquivos.length) return;
    setEnviando(true); setResultados([]);
    const rs: Resultado[] = [];
    for (const f of arquivos) rs.push(await enviarArquivo(f, unidade, tipo, conta));
    setResultados(rs); setArquivos([]); setEnviando(false); atualizar();
  }

  return (
    <>
      <Cabecalho titulo="Enviar arquivos"
        descricao="Extrato do banco, fatura do cartão, relatório da Stone, comprovantes, boletos e notas. OFX do banco entra sozinho; PDF, foto e planilha são lidos e ficam para você conferir antes de lançar." />
      {q.isLoading ? <Carregando linhas={4} /> : q.error ? <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} /> : (() => {
        const r = q.data!;
        const conferir = r.envios.filter((e) => e.status === "conferir");
        return (
          <>
            {!r.leitura_ligada && (
              <div role="status" className="mb-6 rounded-grande border border-atencao/40 bg-atencao-fundo px-6 py-4 text-sm text-atencao">
                <span className="font-bold">Leitura desligada:</span> os arquivos ficam guardados na fila e são lidos quando o agente for ligado.
              </div>
            )}
            {r.faltando.length > 0 && (
              <Secao titulo="Está faltando" descricao="O Supervisor cobra no resumo do WhatsApp até chegar.">
                <ul className="flex flex-col gap-2">
                  {r.faltando.map((f) => (
                    <li key={`${f.esperado_id}-${f.prazo}`}><Painel className="flex items-center gap-3 px-4 py-3 text-sm">
                      <AlarmClock className="h-4 w-4 shrink-0 text-atencao" aria-hidden /><span>{f.descricao}</span></Painel></li>
                  ))}
                </ul>
              </Secao>
            )}

            <Secao titulo="Novo envio">
              <Painel className="flex flex-col gap-4 p-4">
                <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
                  <div><label className="mb-1 block text-xs text-suave" htmlFor="env-loja">Loja</label>
                    <select id="env-loja" className={entradaCls} value={unidade} onChange={(e) => { setUnidade(e.target.value); setConta(""); }}>
                      <option value="">Escolha a loja…</option>
                      {eu.unidades.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
                    </select></div>
                  <div><label className="mb-1 block text-xs text-suave" htmlFor="env-tipo">O que é</label>
                    <select id="env-tipo" className={entradaCls} value={tipo} onChange={(e) => { setTipo(e.target.value); setConta(""); }}>
                      {TIPOS.map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                    </select></div>
                  <div><label className="mb-1 block text-xs text-suave" htmlFor="env-conta">Conta ou cartão (se souber)</label>
                    <select id="env-conta" className={entradaCls} value={conta} onChange={(e) => setConta(e.target.value)} disabled={!unidade}>
                      <option value="">Não sei / não se aplica</option>
                      {contas.map((c) => <option key={c.id} value={c.id}>{c.apelido}{c.final ? ` (final ${c.final})` : ""}</option>)}
                    </select></div>
                </div>
                <label htmlFor="env-arquivos"
                  onDragOver={(e) => { e.preventDefault(); setArrastando(true); }} onDragLeave={() => setArrastando(false)}
                  onDrop={(e) => { e.preventDefault(); setArrastando(false); setArquivos([...e.dataTransfer.files]); }}
                  className={cx("flex cursor-pointer flex-col items-center gap-2 rounded-grande border-2 border-dashed px-4 py-8 text-center text-sm",
                    arrastando ? "border-lente bg-lente-clara" : "border-linha hover:bg-elevada")}>
                  <FileUp className="h-6 w-6 text-suave" aria-hidden />
                  <span className="font-bold">{arquivos.length ? `${arquivos.length} arquivo(s): ${arquivos.map((f) => f.name).join(", ")}` : "Arraste os arquivos aqui ou toque para escolher"}</span>
                  <span className="text-suave">PDF, foto, CSV, planilha ou OFX, até {r.max_mb} MB cada</span>
                  <input id="env-arquivos" type="file" multiple className="sr-only" accept=".pdf,.jpg,.jpeg,.png,.webp,.csv,.txt,.xls,.xlsx,.ofx"
                    onChange={(e) => setArquivos([...(e.target.files ?? [])])} />
                </label>
                <div><Botao variante="primario" icone={<Upload className="h-4 w-4" />} carregando={enviando} disabled={!unidade || !arquivos.length} onClick={enviar}>Enviar</Botao></div>
                {resultados.length > 0 && (
                  <ul className="flex flex-col gap-1 text-sm" aria-live="polite">
                    {resultados.map((x, i) => <li key={i} className={x.ok ? "" : "text-critico"}><b>{x.nome}:</b> {x.texto}</li>)}
                  </ul>
                )}
              </Painel>
            </Secao>

            <Secao titulo="Para conferir" descricao="Lido pelo sistema, esperando alguém conferir e confirmar.">
              {!conferir.length ? <Vazio titulo="Nada para conferir" icone={<CheckCircle2 className="h-6 w-6" />} /> : (
                <ul className="flex flex-col gap-3">
                  {conferir.map((e) => (
                    <li key={e.id}><Painel className="p-4">
                      <div className="flex flex-wrap items-center gap-2">
                        <Etiqueta tom="atencao">{ROTULO_TIPO[e.tipo ?? e.tipo_declarado] ?? e.tipo}</Etiqueta>
                        <h2 className="text-base font-bold">{e.nome_arquivo}</h2>
                      </div>
                      <p className="mt-1 text-sm text-suave">{rotuloUnidade(e.unidade_id, eu.unidades)} · enviado por {e.enviado_por ?? "—"} {relativo(e.criado_em)}</p>
                      <Conferir e={e} r={r} aoConcluir={atualizar} />
                    </Painel></li>
                  ))}
                </ul>
              )}
            </Secao>

            <Secao titulo="Enviados">
              {!r.envios.length ? <Vazio titulo="Nenhum arquivo enviado ainda" icone={<FileUp className="h-6 w-6" />} /> : (
                <Tabela rotulo="Arquivos enviados">
                  <thead><tr><th className={th}>Arquivo</th><th className={th}>Tipo</th><th className={th}>Loja</th><th className={th}>Situação</th><th className={th}>Enviado</th></tr></thead>
                  <tbody>{r.envios.map((e) => (
                    <tr key={e.id}>
                      <td className={td}><span className="font-bold">{e.nome_arquivo}</span>{e.motivo && e.status !== "conferir" && <p className="text-sm text-suave">{e.motivo}</p>}</td>
                      <td className={td}>{ROTULO_TIPO[e.tipo ?? e.tipo_declarado] ?? "—"}</td>
                      <td className={td}>{rotuloUnidade(e.unidade_id, eu.unidades)}</td>
                      <td className={td}><Etiqueta tom={STATUS[e.status]?.tom}>{STATUS[e.status]?.rotulo ?? e.status}</Etiqueta></td>
                      <td className={tdn}>{dataHora(e.criado_em)}<p className="text-sm text-suave">{e.enviado_por ?? ""}</p></td>
                    </tr>
                  ))}</tbody>
                </Tabela>
              )}
            </Secao>
          </>
        );
      })()}
    </>
  );
}
