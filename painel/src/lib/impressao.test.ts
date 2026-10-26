import { describe, expect, it } from "vitest";
import { blocos, codigoCurto } from "./impressao";
import { relativo, STATUS_TAREFA } from "./format";
import { traduzir } from "./erros";

describe("impressão digital da operação", () => {
  const h = "a3f09c11d2e4b5c6a7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e";
  it("é determinística", () => expect(blocos(h)).toEqual(blocos(h)));
  it("muda quando o hash muda", () => expect(blocos(h)).not.toEqual(blocos("b" + h.slice(1))));
  it("hash curto demais não vira desenho falso", () => expect(blocos("abc")).toEqual([]));
  it("código curto em 3 grupos", () => expect(codigoCurto(h)).toBe("a3f0 9c11 d2e4"));
});

describe("formatação", () => {
  it("tempo relativo", () => {
    const agora = Date.parse("2026-10-26T12:00:00Z");
    expect(relativo("2026-10-26T11:58:00Z", agora)).toBe("há 2 min");
    expect(relativo("2026-10-24T12:00:00Z", agora)).toBe("há 2 dias");
    expect(relativo(null, agora)).toBe("nunca");
  });
  it("todo status da tarefa no banco tem rótulo", () => {
    for (const s of ["pendente","aguardando_aprovacao","pronta","executando","validando","concluida","falhou","bloqueada","incerta","cancelada","rejeitada"])
      expect(STATUS_TAREFA[s]).toBeDefined();
  });
});

describe("erros", () => {
  it("2FA", () => expect(traduzir({ message: "confirme o segundo fator (2FA) para continuar" }).tipo).toBe("2fa"));
  it("sem vínculo", () => expect(traduzir({ message: "usuário sem acesso ao painel" }).tipo).toBe("acesso"));
  it("permissão mantém o texto do banco", () =>
    expect(traduzir({ code: "42501", message: "sem permissão para administrar no escopo global" }).message)
      .toBe("Sem permissão para administrar no escopo global."));
  it("limite", () => expect(traduzir({ message: "muitas requisições; aguarde um minuto" }).tipo).toBe("limite"));
});
