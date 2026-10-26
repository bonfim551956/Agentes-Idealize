#!/usr/bin/env python3
"""Gera o SQL da homologação em modo observação:
   1) importa o extrato (JSON do ofx_to_json.py) na conta indicada
   2) registra os lançamentos confirmados do Finance AI (export do ADM, só leitura) como 'pendente', origem whatsapp
   3) roda conciliação e lançamento do extrato
Uso: gerar_carga_homologacao.py extrato.json adm.json conta unidade > carga.sql
Nada é aprovado nem fechado: só observação.
"""
import json, sys

CAT = {'aluguel':'aluguel','beneficios':'beneficios','contabilidade':'contabilidade','emprestimos':'emprestimos',
  'equipamentos':'equipamentos','estornos':'devolucoes','exames_ocupacionais':'exames','folha':'folha',
  'fornecedores':'fornecedores_diversos','impostos':'impostos','indique_ganhe':'indique_ganhe','juridico':'juridico',
  'laboratorio':'laboratorio','manutencao':'manutencao','marketing':'marketing_geral','material':'suprimentos',
  'optometria':'prestadores','outras_saidas':'outras_despesas','premiacoes':'premios','pro_labore':'pro_labore',
  'reunioes':'reunioes','seguranca':'seguranca','sistemas':'sistemas','tarifas':'tarifas',
  'transferencia_grupo':'repasse_intercompany','transporte':'deslocamento','utilidades':'agua_luz_telefone'}

def q(v):
    return 'null' if v is None else "'" + str(v).replace("'", "''") + "'"

def doc_valido(d):
    d = ''.join(ch for ch in (d or '') if ch.isdigit())
    return d if len(d) in (11, 14) else None

extrato, adm, conta, unidade = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3], sys.argv[4]
out = [f"-- carga de homologação (observação) — conta {conta}, unidade {unidade}"]
linhas = json.dumps(extrato['linhas'], ensure_ascii=False).replace("'", "''")
out.append(f"select fin.importar_extrato({q(conta)}, {q(extrato['arquivo_sha256'])}, 'ofx', '{linhas}'::jsonb, "
           f"'homologacao', null, {extrato['saldo_final'] or 'null'}) as importacao;")
n = 0
for l in adm['lancamentos']:
    if l['status'] != 'confirmado' or l['unidade'] != unidade:
        continue
    n += 1
    desc = f"[FAI #{l['numero']}] {l['desc'] or ''}".strip()
    out.append("select fin.registrar_lancamento('despesa','saida',{v},{u},{d},'finance_ai_whatsapp','whatsapp',null,{c},{fav},{doc},{desc},{d},'pendente',{idb});".format(
        v=l['valor'], u=q(unidade), d=q(l['data']), c=q(CAT.get(l['cat'])), fav=q(l['favorecido']),
        doc=q(doc_valido(l['doc'])), desc=q(desc), idb=q(l['documento_id'])))
out.append(f"select fin.conciliar({q(conta)}, 'agente_financeiro') as conciliacao;")
out.append(f"select fin.lancar_do_extrato({q(conta)}, 'agente_financeiro') as lancar_extrato;")
print("\n".join(out))
print(f"-- {n} lançamentos do Finance AI", file=sys.stderr)
