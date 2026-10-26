/** @type {import('tailwindcss').Config} */
const v = (n) => `rgb(var(--${n}) / <alpha-value>)`;
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  darkMode: ["selector", '[data-tema="escuro"]'],
  theme: {
    // escala tipográfica do Diego: 12/14/16/20/24/32/48 — títulos 1.2, corpo 1.5
    fontSize: {
      xs: ["12px", { lineHeight: "1.5" }],
      sm: ["14px", { lineHeight: "1.5" }],
      base: ["16px", { lineHeight: "1.5" }],
      lg: ["20px", { lineHeight: "1.2" }],
      xl: ["24px", { lineHeight: "1.2" }],
      "2xl": ["32px", { lineHeight: "1.2" }],
      "3xl": ["48px", { lineHeight: "1.2" }],
    },
    fontFamily: { sans: ['"Atkinson Hyperlegible Next Variable"', "system-ui", "sans-serif"] },
    extend: {
      colors: {
        fundo: v("fundo"), superficie: v("superficie"), elevada: v("elevada"),
        tinta: v("tinta"), suave: v("suave"), linha: v("linha"),
        lente: v("lente"), "lente-forte": v("lente-forte"), "lente-clara": v("lente-clara"),
        ok: v("ok"), "ok-fundo": v("ok-fundo"),
        atencao: v("atencao"), "atencao-fundo": v("atencao-fundo"),
        critico: v("critico"), "critico-fundo": v("critico-fundo"),
      },
      borderRadius: { pequeno: "4px", medio: "8px", grande: "12px" },
      maxWidth: { leitura: "72ch" },
    },
  },
  plugins: [],
};
