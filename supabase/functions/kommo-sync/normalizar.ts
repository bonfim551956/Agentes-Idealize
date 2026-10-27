// Converte as respostas da API v4 da Kommo no formato do lote. Lista FECHADA de campos:
// nome do cliente, telefone, e-mail, texto de mensagem e campos personalizados nunca passam daqui.
export type Obj = Record<string, unknown>;

const id = (v: unknown): number | null => {
  const n = typeof v === "string" && /^\d+$/.test(v) ? Number(v) : v;
  return typeof n === "number" && Number.isSafeInteger(n) && n >= 0 ? n : null;
};
const epoch = (v: unknown): number | null => {
  const n = id(v);
  return n != null && n >= 1e8 && n < 1e11 ? n : null; // segundos
};
const texto = (v: unknown, max = 120): string | null => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);

export function usuario(u: Obj): Obj | null {
  const i = id(u.id);
  if (i == null) return null;
  const direitos = (u.rights ?? {}) as Obj;
  return { id: i, nome: texto(u.name) ?? `Atendente ${i}`, ativo: direitos.is_active !== false };
}

// 142 = venda ganha, 143 = venda perdida (fixos na Kommo); type 1 = etapa de entrada ("incoming leads").
export function tipoEtapa(s: Obj): "entrada" | "aberta" | "ganha" | "perdida" {
  const i = id(s.id);
  if (i === 142) return "ganha";
  if (i === 143) return "perdida";
  return s.type === 1 ? "entrada" : "aberta";
}

export function funil(p: Obj): Obj | null {
  const i = id(p.id);
  if (i == null) return null;
  const st = (((p._embedded ?? {}) as Obj).statuses ?? []) as Obj[];
  const etapas = st.flatMap((s) => {
    const e = id(s.id);
    return e == null ? [] : [{ id: e, nome: texto(s.name) ?? `Etapa ${e}`, tipo: tipoEtapa(s), ordem: id(s.sort) ?? 0 }];
  });
  return { id: i, nome: texto(p.name) ?? `Funil ${i}`, etapas };
}

export function lead(l: Obj): Obj | null {
  const i = id(l.id), f = id(l.pipeline_id), e = id(l.status_id);
  if (i == null || f == null || e == null) return null;
  const o: Obj = { id: i, funil_id: f, etapa_id: e, responsavel_id: id(l.responsible_user_id) ?? 0,
    valor: typeof l.price === "number" && isFinite(l.price) && l.price >= 0 ? l.price : 0 };
  for (const [de, para] of [["created_at", "criado_em"], ["updated_at", "atualizado_em"], ["closed_at", "fechado_em"]]) {
    const t = epoch(l[de]);
    if (t != null) o[para] = t;
  }
  return o;
}

const TIPOS_CHAT = new Set(["incoming_chat_message", "outgoing_chat_message"]);
const ENTIDADES = new Set(["lead", "contact"]);

export function evento(ev: Obj): Obj | null {
  const i = texto(ev.id, 64), em = epoch(ev.created_at), ent = id(ev.entity_id);
  if (i == null || em == null || ent == null || !TIPOS_CHAT.has(String(ev.type)) || !ENTIDADES.has(String(ev.entity_type))) return null;
  const o: Obj = { id: i, tipo: ev.type, entidade_tipo: ev.entity_type, entidade_id: ent, em };
  const u = id(ev.created_by);
  if (ev.type === "outgoing_chat_message" && u) o.usuario_id = u;
  return o;
}

export const lista = <T>(xs: Obj[], f: (x: Obj) => T | null): T[] => xs.flatMap((x) => { const r = f(x); return r == null ? [] : [r]; });
