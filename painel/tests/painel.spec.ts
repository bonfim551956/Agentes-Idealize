import { expect, test } from "@playwright/test";
import { EU_GERENTE, HASH, instalar } from "./mock";

test.describe("entrada", () => {
  test("senha errada mostra mensagem clara", async ({ page }) => {
    await instalar(page, { logado: false });
    await page.goto("/");
    await page.getByLabel("E-mail").fill("diego@teste.local");
    await page.getByLabel("Senha").fill("errada");
    await page.getByRole("button", { name: "Entrar" }).click();
    await expect(page.getByRole("alert")).toHaveText("E-mail ou senha incorretos.");
  });

  test("senha certa pede o código do autenticador e depois abre o painel", async ({ page }) => {
    await instalar(page, { logado: false });
    await page.goto("/");
    await page.getByLabel("E-mail").fill("diego@teste.local");
    await page.getByLabel("Senha").fill("senha-certa");
    await page.getByRole("button", { name: "Entrar" }).click();
    await expect(page.getByRole("heading", { name: "Confirme que é você" })).toBeVisible();
    await page.getByLabel("Código de 6 dígitos").fill("000000");
    await page.getByRole("button", { name: "Confirmar" }).click();
    await expect(page.getByRole("alert")).toContainText("Código incorreto");
    await page.getByLabel("Código de 6 dígitos").fill("123456");
    await page.getByRole("button", { name: "Confirmar" }).click();
    await expect(page.getByRole("heading", { name: "Plataforma operando" })).toBeVisible();
  });

  test("sem autenticador cadastrado, obriga a ativar o 2FA", async ({ page }) => {
    await instalar(page, { logado: "aal1", comFator: false });
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Ative a verificação em duas etapas" })).toBeVisible();
    await expect(page.getByAltText("QR code para o aplicativo autenticador")).toBeVisible();
    await expect(page.getByText("JBSWY3DPEHPK3PXP")).toBeVisible();
  });

  test("login sem vínculo vê aviso e não vê dados", async ({ page }) => {
    const chamadas = await instalar(page, { logado: "aal2", rpc: {
      painel_eu: () => ({ status: 403, body: { code: "42501", message: "usuário sem acesso ao painel" } }) } });
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Acesso ainda não liberado" })).toBeVisible();
    expect(chamadas.map((c) => c.fn)).toEqual(["painel_eu"]);
  });
});

test.describe("visão geral e decisões", () => {
  test("mostra o estado e o que precisa de decisão @celular", async ({ page }) => {
    await instalar(page, { logado: "aal2" });
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Plataforma operando" })).toBeVisible();
    await expect(page.getByText("Operação aguardando sua aprovação")).toBeVisible();
    await expect(page.getByText("Tarefas em estado incerto")).toBeVisible();
    await expect(page.getByText("2 bloqueiam o fechamento do mês")).toBeVisible();
    const larg = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
    expect(larg[0]).toBeLessThanOrEqual(larg[1]);
  });

  test("aprovar envia exatamente o código da operação vista", async ({ page }) => {
    const chamadas = await instalar(page, { logado: "aal2" });
    await page.goto("/aprovacoes");
    await expect(page.getByText("R$ 4.165,55").first()).toBeVisible();
    await page.getByRole("button", { name: "Aprovar" }).click();
    const dlg = page.getByRole("dialog");
    await expect(dlg.getByText("Sua aprovação vale só para a operação com este código")).toBeVisible();
    await dlg.getByRole("button", { name: "Aprovar" }).click();
    await expect(dlg).toBeHidden();
    const ap = chamadas.find((c) => c.fn === "painel_aprovar")!;
    expect(ap.corpo).toMatchObject({ p_tarefa: "00000000-0000-0000-0000-00000000aa01", p_decisao: "aprovar", p_hash: HASH });
  });

  test("rejeitar exige motivo e mostra o erro do banco", async ({ page }) => {
    const chamadas = await instalar(page, { logado: "aal2", rpc: {
      painel_aprovar: () => ({ status: 403, body: { code: "42501", message: "aprovação não corresponde à operação atual (hash divergente)" } }) } });
    await page.goto("/aprovacoes");
    await page.getByRole("button", { name: "Rejeitar" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByRole("button", { name: "Rejeitar" }).click();
    await expect(dlg.getByText("Escreva pelo menos 5 caracteres.")).toBeVisible();
    expect(chamadas.some((c) => c.fn === "painel_aprovar")).toBe(false);
    await dlg.getByLabel("Motivo da rejeição").fill("valor não confere com a fatura");
    await dlg.getByRole("button", { name: "Rejeitar" }).click();
    await expect(dlg.getByRole("alert")).toContainText("hash divergente");
    await expect(dlg).toBeVisible();
  });

  test("pausar a plataforma pede o motivo e registra", async ({ page }) => {
    const chamadas = await instalar(page, { logado: "aal2" });
    await page.goto("/");
    await page.getByRole("button", { name: "Pausar a plataforma" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("O que aconteceu").fill("teste de modo seguro");
    await dlg.getByRole("button", { name: "Pausar agora" }).click();
    await expect(dlg).toBeHidden();
    expect(chamadas.find((c) => c.fn === "painel_plataforma_pausar")!.corpo).toEqual({ p_pausar: true, p_motivo: "teste de modo seguro" });
  });

  test("tarefa incerta: conferência humana com evidência", async ({ page }) => {
    const chamadas = await instalar(page, { logado: "aal2" });
    await page.goto("/tarefas/00000000-0000-0000-0000-00000000aa02");
    await expect(page.getByRole("heading", { name: "Registrar comprovante recebido" })).toBeVisible();
    await page.getByRole("button", { name: "Não aconteceu: devolver à fila" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("O que você conferiu").fill("nenhum lançamento novo no sistema");
    await dlg.getByRole("button", { name: "Devolver à fila" }).click();
    await expect(dlg).toBeHidden();
    expect(chamadas.find((c) => c.fn === "painel_reconciliar")!.corpo).toMatchObject({ p_efetivada: false, p_evidencia: "nenhum lançamento novo no sistema" });
  });
});

test.describe("estados e permissões", () => {
  test("erro do servidor mostra o que fazer e permite tentar de novo", async ({ page }) => {
    let n = 0;
    await instalar(page, { logado: "aal2", rpc: {
      painel_tarefas: () => (++n <= 3 ? { status: 500, body: { message: "Failed to fetch" } } : { status: 200, body: [] }) } });
    await page.goto("/tarefas");
    await expect(page.getByText(/Sem conexão com o servidor|Failed to fetch/)).toBeVisible({ timeout: 15_000 });
    await page.getByRole("button", { name: "Tentar de novo" }).click();
    await expect(page.getByText("Nenhuma tarefa com esses filtros")).toBeVisible();
  });

  test("gerente não vê áreas de administração", async ({ page }) => {
    await instalar(page, { logado: "aal2", rpc: { painel_eu: EU_GERENTE } });
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Plataforma operando" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Pessoas e permissões" })).toHaveCount(0);
    await expect(page.getByRole("link", { name: "Histórico auditado" })).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Pausar a plataforma" })).toHaveCount(0);
    await page.goto("/usuarios");
    await expect(page).toHaveURL(/\/$/);
  });

  test("todas as seções abrem sem erro @celular", async ({ page }) => {
    const erros: string[] = [];
    page.on("pageerror", (e) => erros.push(e.message));
    page.on("console", (m) => { if (m.type() === "error") erros.push(m.text()); });
    await instalar(page, { logado: "aal2" });
    const secoes: [string, string][] = [
      ["/", "Plataforma operando"], ["/aprovacoes", "Aprovações"], ["/tarefas", "Tarefas"], ["/incidentes", "Incidentes"],
      ["/pendencias", "Pendências financeiras"], ["/financeiro", "Financeiro por loja"], ["/agentes", "Agentes"], ["/laboratorio", "Laboratório"], ["/comercial", "Comercial"],
      ["/custos", "Custos de IA"], ["/auditoria", "Histórico auditado"], ["/operacao", "Operação e integrações"], ["/usuarios", "Pessoas e permissões"],
    ];
    for (const [rota, titulo] of secoes) {
      await page.goto(rota);
      await expect(page.getByRole("heading", { level: 1, name: titulo })).toBeVisible();
      const [sw, w] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
      expect(sw, `rolagem horizontal em ${rota}`).toBeLessThanOrEqual(w);
    }
    expect(erros).toEqual([]);
  });

  test("laboratório mostra alertas, filtra e avisa que o agente está desligado", async ({ page }) => {
    await instalar(page, { logado: "aal2" });
    await page.goto("/laboratorio");
    await expect(page.getByText(/Agente desligado: os números abaixo são da última leitura/)).toBeVisible();
    await expect(page.getByText("OS 1001, pedido BR-55821")).toBeVisible();
    await expect(page.getByText("Cliente avisado há 21 dias, com saldo a receber.")).toBeVisible();
    await page.getByLabel("Tipo de alerta").selectOption("prazo_vencido");
    await expect(page.getByText("OS 2002, pedido BR-55102")).toHaveCount(0);
    await expect(page.getByText("OS 1001, pedido BR-55821")).toBeVisible();
  });

  test("comercial mostra quem espera resposta e define a loja de um funil", async ({ page }) => {
    const chamadas = await instalar(page, { logado: "aal2" });
    await page.goto("/comercial");
    await expect(page.getByText(/Agente desligado: os números abaixo são da última leitura, e ainda não houve nenhuma/)).toBeVisible();
    await expect(page.getByText(/Última mensagem do cliente há 50 min \(limite 30 min\)/)).toBeVisible();
    await expect(page.getByRole("cell", { name: "Atendente Bia" })).toBeVisible();
    await page.getByLabel("Tipo de alerta").selectOption("lead_parado");
    await expect(page.getByText(/Última mensagem do cliente/)).toHaveCount(0);
    await page.getByLabel("Loja do funil Funil Sorocaba").selectOption("campinas");
    await page.getByRole("row", { name: /Funil Sorocaba/ }).getByRole("button", { name: "Salvar" }).click();
    const dlg = page.getByRole("dialog");
    await dlg.getByLabel("Motivo").fill("funil é da loja de Campinas");
    await dlg.getByRole("button", { name: "Salvar" }).click();
    await expect.poll(() => chamadas.find((c) => c.fn === "painel_comercial_funil_loja")?.corpo).toEqual(
      { p_funil: 20, p_unidade: "campinas", p_motivo: "funil é da loja de Campinas" });
  });

  test("auditoria verifica a integridade", async ({ page }) => {
    await instalar(page, { logado: "aal2" });
    await page.goto("/auditoria");
    await page.getByRole("button", { name: "Verificar integridade agora" }).click();
    await expect(page.getByText(/Íntegro: 1\.288 eventos conferidos/)).toBeVisible();
  });

  test("financeiro abre a DRE e decide o fechamento com o código do pacote", async ({ page }) => {
    const chamadas = await instalar(page, { logado: "aal2" });
    await page.goto("/financeiro");
    await page.getByRole("button", { name: "São Vicente" }).click();
    await expect(page.getByText("Vendas no cartão")).toBeVisible();
    await page.getByRole("button", { name: "Aprovar fechamento" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "Aprovar e travar o mês" }).click();
    await expect(page.getByRole("dialog")).toBeHidden();
    expect(chamadas.find((c) => c.fn === "painel_fechamento_decidir")!.corpo).toEqual({ p_fechamento: "fe1", p_aprovar: true, p_hash: HASH });
  });
});
