import { Check, X } from "lucide-react";
import { rpc } from "../lib/api";
import { Botao } from "./base";
import { Confirmar } from "./Confirmar";
import { Impressao } from "./Impressao";

// Aprovar/rejeitar uma tarefa. O hash enviado é o que a pessoa VIU; se a operação mudou, o banco recusa.
export function BotoesDecisao({ tarefa, hash, resumo, aoConcluir }: { tarefa: string; hash: string; resumo: string; aoConcluir: () => void }) {
  const conferencia = (
    <div className="flex flex-col gap-2 rounded-medio bg-elevada px-4 py-3">
      <p className="text-sm">{resumo}</p>
      <div className="flex items-center gap-2 text-xs text-suave">Código da operação: <Impressao hash={hash} /></div>
    </div>
  );
  return (
    <div className="flex flex-wrap gap-2">
      <Confirmar
        gatilho={<Botao variante="primario" icone={<Check className="h-4 w-4" aria-hidden />}>Aprovar</Botao>}
        titulo="Aprovar esta operação?" rotuloConfirmar="Aprovar"
        descricao="Sua aprovação vale só para a operação com este código. Se qualquer dado mudar, ela deixa de valer."
        detalhes={conferencia}
        motivo={{ rotulo: "Comentário (opcional)", minimo: 0, obrigatorio: false }}
        aoConfirmar={(m) => rpc("painel_aprovar", { p_tarefa: tarefa, p_decisao: "aprovar", p_hash: hash, p_comentario: m || null })}
        aoConcluir={aoConcluir} />
      <Confirmar
        gatilho={<Botao icone={<X className="h-4 w-4" aria-hidden />}>Rejeitar</Botao>}
        titulo="Rejeitar esta operação?" rotuloConfirmar="Rejeitar" variante="perigo"
        descricao="A tarefa é encerrada e o agente não executa. Para fazer depois, ele precisa pedir de novo."
        detalhes={conferencia}
        motivo={{ rotulo: "Motivo da rejeição", minimo: 5, ajuda: "Quem pediu vai ver este motivo." }}
        aoConfirmar={(m) => rpc("painel_aprovar", { p_tarefa: tarefa, p_decisao: "rejeitar", p_hash: hash, p_comentario: m })}
        aoConcluir={aoConcluir} />
    </div>
  );
}
