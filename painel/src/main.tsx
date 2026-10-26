import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource-variable/atkinson-hyperlegible-next";
import "./index.css";
import { App } from "./App";

// aplica o tema antes do primeiro desenho (evita piscar)
try {
  const t = localStorage.getItem("painel-tema");
  document.documentElement.dataset.tema = t === "escuro" || t === "claro" ? t
    : window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "escuro" : "claro";
} catch { document.documentElement.dataset.tema = "claro"; }

createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
