#!/usr/bin/env python3
"""Validador INDEPENDENTE da homologação. Não usa a lógica do motor: recalcula a partir
das fontes brutas (OFX convertido + export do Finance AI) e confere o resultado do banco.
Uso: validar_homologacao.py extrato.json adm.json resultado.json regras_publicas.sql [regras_privadas.sql]
Sai com código 1 se qualquer verificação obrigatória falhar.
"""
import json, re, sys
from collections import Counter, defaultdict
from datetime import date
from decimal import Decimal as D

ext, adm, res = (json.load(open(p)) for p in sys.argv[1:4])
regras = []
for p in sys.argv[4:]:
    for m in re.finditer(r"\('([^']*)',\s*'(credito|debito)',\s*'(\w+)',\s*(?:'(\w+)'|null)(?:,\s*(?:'(\w+)'|null))?,\s*(\d+),", open(p).read()):
        regras.append(dict(padrao=m[1], sentido=m[2], natureza=m[3], cat=m[4], prio=int(m[6])))
regras.sort(key=lambda r: r['prio'])

def regra_para(desc, sentido):
    for r in regras:
        if r['sentido'] == sentido and r['padrao'].lower() in desc.lower():
            return r
    return None

falhas, avisos = [], []
def checar(cond, msg):
    (None if cond else falhas.append(msg))

ofx = {l['documento']: l for l in ext['linhas']}
pares = res['pares']
fitids = Counter(p['fitid'] for p in pares)
checar(set(fitids) == set(ofx), f"movimentos do OFX sem par: {set(ofx)-set(fitids)}")
checar(all(n == 1 for n in fitids.values()), f"FITID conciliado mais de uma vez: {[k for k,n in fitids.items() if n>1]}")

fai = {l['numero']: l for l in adm['lancamentos'] if l['status'] == 'confirmado'}
par_fai = {}
for p in pares:
    m = re.match(r"\[FAI #(\d+)\]", p['ldesc'] or '')
    if m:
        par_fai.setdefault(int(m[1]), []).append(p)
checar(set(par_fai) == set(fai), f"lançamentos do Finance AI sem par: {sorted(set(fai)-set(par_fai))}")
checar(all(len(v) == 1 for v in par_fai.values()), "lançamento do Finance AI com mais de um par")

for n, (p,) in par_fai.items():
    l, o = fai[n], ofx[p['fitid']]
    checar(D(str(l['valor'])) == -D(o['valor']), f"FAI #{n}: valor {l['valor']} ≠ extrato {o['valor']}")
    dd = abs((date.fromisoformat(l['data']) - date.fromisoformat(o['data'])).days)
    checar(dd <= 3, f"FAI #{n}: data {l['data']} longe do extrato {o['data']}")
    doc = ''.join(c for c in (l['doc'] or '') if c.isdigit())
    toks = set(re.findall(r'\d{11,14}', o['descricao']))
    if len(doc) in (11, 14) and toks and doc not in toks:
        falhas.append(f"FAI #{n}: CPF/CNPJ do comprovante ({doc[:3]}…) não é o do extrato — par suspeito")

cred = sum(D(l['valor']) for l in ext['linhas'] if D(l['valor']) > 0)
deb = -sum(D(l['valor']) for l in ext['linhas'] if D(l['valor']) < 0)
tu_c = sum(D(str(p['valor'])) for p in pares if p['natureza'] == 'transferencia_unidades' and p['sentido'] == 'credito')
tu_d = sum(D(str(p['valor'])) for p in pares if p['natureza'] == 'transferencia_unidades' and p['sentido'] == 'debito')
cu, cc = res['caixa_unidade'], res['caixa_consolidado']
checar(D(str(cu['entradas'])) == cred and D(str(cu['saidas'])) == deb, f"caixa da unidade {cu} ≠ extrato ({cred}/{deb})")
checar(D(str(cc['entradas'])) == cred - tu_c and D(str(cc['saidas'])) == deb - tu_d, "consolidado não excluiu as transferências entre unidades")
dre_r = sum(D(str(x['valor'])) for x in res['dre'] if x['natureza'] == 'receita')
dre_d = sum(D(str(x['valor'])) for x in res['dre'] if x['natureza'] == 'despesa')
sem_cat = sum(D(str(p['valor'])) for p in pares if p['natureza'] in ('receita','despesa') and p['cat'] is None)
# a DRE já inclui os lançamentos sem categoria (sem_cat é só informativo).
# Fora da DRE: transferências entre unidades e pagamento de fatura. Estorno abate a original, e o próprio
# movimento do estorno também está no extrato — por isso entra 2× na identidade.
fat = sum(D(str(p['valor'])) for p in pares if p['natureza'] == 'pagamento_fatura')
est = sum(D(str(p['valor'])) for p in pares if p['natureza'] == 'estorno')
checar(dre_r + dre_d + tu_c + tu_d + fat + 2 * est == cred + deb,
       f"DRE ({dre_r}/{dre_d}) + transferências ({tu_c}/{tu_d}) + fatura ({fat}) + 2×estorno ({est}) ≠ extrato ({cred}+{deb})")
if res.get('saldo') and res['saldo'].get('inicial') is not None:
    si, sf = D(str(res['saldo']['inicial'])), D(str(res['saldo']['final']))
    checar(si + cred - deb == sf, f"saldo inicial {si} + créditos − débitos ≠ saldo final {sf}")
else:
    avisos.append("saldo inicial não confirmado: abertura não verificada")
checar(res['auditoria']['adulterado_em'] is None, "cadeia de auditoria adulterada")

# divergência de classificação: Finance AI × regra declarada pelo Diego (mesmo movimento)
CAT_FAI = {}
diverg = []
for n, (p,) in par_fai.items():
    o = ofx[p['fitid']]; r = regra_para(o['descricao'], 'debito')
    esperado = (r['cat'] or r['natureza']) if r else None
    if esperado and esperado != (p['cat'] or 'sem_categoria') and not (esperado == 'transferencia_unidades'):
        diverg.append((n, p['cat'] or 'sem_categoria', esperado, D(str(p['valor'])), fai[n]['desc']))
    if r and r['natureza'] == 'transferencia_unidades':
        diverg.append((n, p['cat'], 'transferencia_unidades → sorocaba', D(str(p['valor'])), fai[n]['desc']))

nao_reg = [(p['data'], D(str(p['valor'])), p['cat'] or p['natureza'], ofx[p['fitid']]['descricao']) for p in pares
           if p['origem'] == 'extrato' and p['sentido'] == 'debito']
rel = dict(
  movimentos=len(ofx), creditos=str(cred), debitos=str(deb),
  fai_confirmados=len(fai), fai_conciliados=len(par_fai), regras_usadas=Counter(p['regra'] for p in pares),
  saidas_sem_comprovante=[(str(a), str(b), c, d) for a, b, c, d in sorted(nao_reg)],
  saidas_sem_comprovante_total=str(sum(x[1] for x in nao_reg)),
  divergencias_classificacao=[(n, a, b, str(v), d) for n, a, b, v, d in sorted(diverg)],
  dre=dict(receitas=str(dre_r), despesas=str(dre_d), sem_categoria=str(sem_cat), transf_unid_entrada=str(tu_c), transf_unid_saida=str(tu_d)),
  pendencias=[(p['tipo'], p['material'], str(p['valor']), p['mov'] or '') for p in res['pendencias']],
  pagamento_fatura=str(fat), estornos=str(est), avisos=avisos,
  falhas=falhas)
json.dump(rel, sys.stdout, ensure_ascii=False, indent=1, default=str)
sys.exit(1 if falhas else 0)
