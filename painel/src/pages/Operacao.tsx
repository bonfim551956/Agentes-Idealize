import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { rpc, type Operacao as O } from "../lib/api";
import { dataHora, relativo, STATUS_INTEGRACAO } from "../lib/format";
import { Botao, Cabecalho, Campo, Carregando, ErroCaixa, Etiqueta, Painel, Secao, Tabela, entradaCls, td, th } from "../ui/base";
import { Confirmar } from "../ui/Confirmar";

type Regras = { inatividade_horas: number; dias: number; pode_alterar: boolean };

// Quanto tempo o painel fica aberto sem pedir login de novo (pedido 07/11). Só quem administra altera.
function SessaoPainel() {
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ["sessao_regras"], queryFn: () => rpc<Regras>("painel_sessao_regras") });
  const [horas, setHoras] = useState(12);
  const [dias, setDias] = useState(7);
  useEffect(() => { if (q.data) { setHoras(q.data.inatividade_horas); setDias(q.data.dias); } }, [q.data]);
  if (q.isLoading) return <Carregando linhas={2} />;
  if (q.error) return <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} />;
  const r = q.data!;
  const horasOk = Number.isInteger(horas) && horas >= 1 && horas <= 72;
  const diasOk = Number.isInteger(dias) && dias >= 1 && dias <= 30;
  const mudou = horas !== r.inatividade_horas || dias !== r.dias;
  return (
    <Secao titulo="Sessão do painel" descricao="Quanto tempo o painel fica aberto no mesmo aparelho sem pedir login de novo. O código do autenticador continua obrigatório.">
      <Painel className="flex flex-col gap-4 p-4">
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <Campo id="s-horas" rotulo="Sair depois de quantas horas sem uso" ajuda="Entre 1 e 72 horas." erro={horasOk ? null : "Use um número entre 1 e 72."}>
            <input id="s-horas" type="number" inputMode="numeric" min={1} max={72} className={entradaCls} disabled={!r.pode_alterar}
              aria-invalid={!horasOk} value={Number.isNaN(horas) ? "" : horas} onChange={(e) => setHoras(e.target.valueAsNumber)} />
          </Campo>
          <Campo id="s-dias" rotulo="Pedir senha e código de novo a cada quantos dias" ajuda="Entre 1 e 30 dias, por aparelho." erro={diasOk ? null : "Use um número entre 1 e 30."}>
            <input id="s-dias" type="number" inputMode="numeric" min={1} max={30} className={entradaCls} disabled={!r.pode_alterar}
              aria-invalid={!diasOk} value={Number.isNaN(dias) ? "" : dias} onChange={(e) => setDias(e.target.valueAsNumber)} />
          </Campo>
        </div>
        {r.pode_alterar ? (
          <div>
            <Confirmar gatilho={<Botao variante="primario" disabled={!mudou || !horasOk || !diasOk}>Salvar tempos</Botao>}
              titulo="Alterar o tempo de sessão?" rotuloConfirmar="Salvar"
              descricao={`O painel vai sair depois de ${horas} h sem uso e pedir senha e código a cada ${dias} dias. Vale para todos, a partir do próximo acesso.`}
              motivo={{ rotulo: "Motivo da mudança", minimo: 5 }}
              aoConfirmar={(m) => rpc("painel_sessao_definir", { p_inatividade_horas: horas, p_dias: dias, p_motivo: m })}
              aoConcluir={() => { void qc.invalidateQueries({ queryKey: ["sessao_regras"] }); }} />
          </div>
        ) : <p className="text-sm text-suave">Só quem administra o painel altera esses tempos.</p>}
      </Painel>
    </Secao>
  );
}

function Chave({ nome, ligado, explicacao }: { nome: string; ligado: boolean; explicacao: string }) {
  return (
    <Painel className="flex flex-col gap-2 p-4">
      <div className="flex items-center justify-between gap-2"><span className="font-bold">{nome}</span>
        <Etiqueta tom={ligado ? "ok" : "neutro"}>{ligado ? "Ligado" : "Desligado"}</Etiqueta></div>
      <p className="text-sm text-suave">{explicacao}</p>
    </Painel>
  );
}

export function Operacao() {
  const q = useQuery({ queryKey: ["operacao"], queryFn: () => rpc<O>("painel_operacao") });
  if (q.isLoading) return <Carregando linhas={6} />;
  if (q.error) return <ErroCaixa erro={q.error} tentarDeNovo={() => q.refetch()} />;
  const o = q.data!;
  return (
    <>
      <Cabecalho titulo="Operação e integrações" descricao="Chaves de liberação, sistemas conectados, versões instaladas e agendamentos." />
      <Secao titulo="Chaves de liberação" descricao="Cada canal novo nasce desligado e é ligado por etapas, com aprovação.">
        <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
          <Chave nome="Modo seguro" ligado={o.chaves.plataforma_pausada} explicacao="Ligado, nenhum agente começa tarefa nova. Controlado na visão geral." />
          <Chave nome="Canal WhatsApp do financeiro" ligado={o.chaves.fin_whatsapp_ativo} explicacao="Recebe comprovantes dos grupos das lojas. Desligado, mensagens são ignoradas sem gravar nada." />
          <Chave nome="Respostas no WhatsApp" ligado={o.chaves.fin_whatsapp_responder} explicacao="Desligado, o agente trabalha em modo sombra: registra, mas não responde no grupo." />
        </div>
        <p className="mt-4 text-sm text-suave">Os canais externos são ligados por mudança revisada no banco, não por botão, para que cada liberação tenha teste e registro.</p>
      </Secao>
      <SessaoPainel />
      <Secao titulo="Integrações" descricao="Começam só com leitura; escrita é liberada depois de testada e aprovada.">
        <Tabela rotulo="Integrações">
          <thead><tr><th className={th}>Sistema</th><th className={th}>Estado</th><th className={th}>Escrita</th><th className={th}>Último ok</th><th className={th}>Observação</th></tr></thead>
          <tbody>{o.integracoes.map((i) => {
            const s = STATUS_INTEGRACAO[i.status];
            return (
              <tr key={i.id}><td className={td}><span className="font-bold">{i.nome}</span></td>
                <td className={td}><Etiqueta tom={s?.tom}>{s?.rotulo ?? i.status}</Etiqueta></td>
                <td className={td}>{i.escrita_habilitada ? "Liberada" : "Só leitura"}</td>
                <td className={td} title={dataHora(i.ultimo_ok_em)}>{relativo(i.ultimo_ok_em)}</td>
                <td className={td + " text-suave"}>{i.observacoes ?? "—"}</td></tr>
            );
          })}</tbody>
        </Tabela>
      </Secao>
      <div className="grid grid-cols-1 gap-x-8 lg:grid-cols-2">
        <Secao titulo="Versões instaladas">
          <Painel className="p-4 text-sm">
            <dl className="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
              {Object.entries(o.versoes.componentes).map(([k, v]) => <div key={k} className="contents"><dt className="text-suave">{k.replace("versao_", "").replace(/_/g, " ")}</dt><dd>{v}</dd></div>)}
              {Object.entries(o.versoes.agentes).map(([k, v]) => <div key={k} className="contents"><dt className="text-suave">agente {k}</dt><dd>{v}</dd></div>)}
            </dl>
            {o.versoes.migracoes && (
              <details className="mt-4"><summary className="cursor-pointer font-bold text-lente">{o.versoes.migracoes.length} mudanças de banco aplicadas</summary>
                <ol className="mt-2 flex flex-col gap-1">{o.versoes.migracoes.map((m) => <li key={m.versao}><span className="text-suave">{m.versao}</span> {m.nome}</li>)}</ol>
              </details>
            )}
          </Painel>
        </Secao>
        <Secao titulo="Agendamentos">
          <Painel className="p-4 text-sm">
            {o.agendamentos.cron?.length ? (
              <ul className="mb-4 flex flex-col gap-1">{o.agendamentos.cron.map((c) => <li key={c.nome} className="flex justify-between gap-2"><span>{c.nome}</span><span className="text-suave">{c.agenda}{c.ativo ? "" : " (parado)"}</span></li>)}</ul>
            ) : <p className="mb-4 text-suave">Nenhuma rotina agendada no banco.</p>}
            <p>{o.agendamentos.tarefas_futuras} tarefas esperando horário para rodar{o.agendamentos.proxima_tarefa_em && `, a próxima ${relativo(o.agendamentos.proxima_tarefa_em)}`}.</p>
          </Painel>
        </Secao>
      </div>
    </>
  );
}
