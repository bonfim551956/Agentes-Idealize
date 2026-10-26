import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "tests",
  timeout: 30_000,
  fullyParallel: true,
  reporter: [["list"]],
  use: { baseURL: "http://127.0.0.1:4173", locale: "pt-BR", timezoneId: "America/Sao_Paulo" },
  webServer: {
    command: "npx vite build --mode teste && npx vite preview --port 4173 --strictPort --host 127.0.0.1",
    url: "http://127.0.0.1:4173", reuseExistingServer: false, timeout: 120_000,
    env: { VITE_SUPABASE_URL: "https://mock.supabase.test", VITE_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_teste" },
  },
  projects: [
    { name: "computador", use: { ...devices["Desktop Chrome"], viewport: { width: 1366, height: 900 } } },
    { name: "celular", use: { ...devices["Pixel 7"] }, grep: /@celular/ },
  ],
});
