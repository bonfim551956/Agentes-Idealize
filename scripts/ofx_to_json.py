#!/usr/bin/env python3
"""Converte extrato OFX (SGML 1.02, como o do Sicredi) para o JSON aceito por fin.importar_extrato.

Saída: {"arquivo_sha256", "banco", "conta", "inicio", "fim", "saldo_final", "linhas": [
          {"data": "AAAA-MM-DD", "valor": ±n, "descricao": str, "documento": FITID}]}
Não altera textos do banco (só remove espaços duplicados). Valores em Decimal, sem float.
"""
import hashlib, json, re, sys
from decimal import Decimal

def tag(bloco, nome):
    m = re.search(rf"<{nome}>([^<\r\n]*)", bloco)
    return m.group(1).strip() if m else None

def data(v):
    return f"{v[0:4]}-{v[4:6]}-{v[6:8]}" if v else None

def converter(caminho):
    bruto = open(caminho, "rb").read()
    txt = bruto.decode("utf-8", errors="strict") if bruto[:3] != b"\xef\xbb\xbf" else bruto[3:].decode("utf-8")
    linhas, vistos = [], set()
    for bloco in re.findall(r"<STMTTRN>(.*?)</STMTTRN>", txt, flags=re.S):
        fitid = tag(bloco, "FITID")
        valor = Decimal(tag(bloco, "TRNAMT").replace(",", "."))
        memo = re.sub(r"\s+", " ", tag(bloco, "MEMO") or tag(bloco, "NAME") or "").strip()
        if not fitid:
            raise ValueError(f"linha sem FITID: {memo}")
        if fitid in vistos:
            raise ValueError(f"FITID repetido no arquivo: {fitid}")
        vistos.add(fitid)
        linhas.append({"data": data(tag(bloco, "DTPOSTED")), "valor": str(valor), "descricao": memo, "documento": fitid})
    ledger = re.search(r"<LEDGERBAL>(.*?)</LEDGERBAL>", txt, flags=re.S)
    return {
        "arquivo_sha256": hashlib.sha256(bruto).hexdigest(),
        "banco": tag(txt, "BANKID"), "conta": tag(txt, "ACCTID"),
        "inicio": data(tag(txt, "DTSTART")), "fim": data(tag(txt, "DTEND")),
        "saldo_final": tag(ledger.group(1), "BALAMT") if ledger else None,
        "linhas": linhas,
    }

if __name__ == "__main__":
    out = converter(sys.argv[1])
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
