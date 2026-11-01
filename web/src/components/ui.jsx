import { createContext, useContext, useEffect, useState, useCallback, useRef } from "react";

/* ---------- formatters ---------- */
export const num = (v, d = 0) =>
  v === null || v === undefined || v === "" || Number.isNaN(Number(v))
    ? "–"
    : Number(v).toLocaleString("en-IN", { maximumFractionDigits: d, minimumFractionDigits: d });
export const money = (v) => (v === null || v === undefined ? "–" : "₹" + num(v, 0));
export const compact = (v) => {
  const n = Number(v);
  if (Number.isNaN(n)) return "–";
  if (Math.abs(n) >= 1e7) return "₹" + (n / 1e7).toFixed(2) + " Cr";
  if (Math.abs(n) >= 1e5) return "₹" + (n / 1e5).toFixed(2) + " L";
  if (Math.abs(n) >= 1e3) return "₹" + (n / 1e3).toFixed(1) + " K";
  return "₹" + n.toFixed(0);
};
export const dateStr = (v) => (v ? String(v).slice(0, 10) : "–");

/* ---------- data hook ---------- */
export function useAsync(fn, deps) {
  const [state, setState] = useState({ data: null, error: null, loading: true });
  const seq = useRef(0);
  useEffect(() => {
    const id = ++seq.current;
    setState((s) => ({ ...s, loading: true, error: null }));
    fn()
      .then((data) => id === seq.current && setState({ data, error: null, loading: false }))
      .catch((e) => id === seq.current && setState({ data: null, error: e.message, loading: false }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  return state;
}

/* ---------- toast ---------- */
const ToastCtx = createContext(() => {});
export const useToast = () => useContext(ToastCtx);

export function ToastProvider({ children }) {
  const [items, setItems] = useState([]);
  const push = useCallback((message, kind = "ok") => {
    const id = Math.random().toString(36).slice(2);
    setItems((l) => [...l, { id, message, kind }]);
    setTimeout(() => setItems((l) => l.filter((t) => t.id !== id)), kind === "err" ? 7000 : 4000);
  }, []);
  return (
    <ToastCtx.Provider value={push}>
      {children}
      <div className="toasts">
        {items.map((t) => (
          <div key={t.id} className={"toast " + t.kind}>{t.message}</div>
        ))}
      </div>
    </ToastCtx.Provider>
  );
}

/* ---------- small building blocks ---------- */
export function Spinner({ label = "Loading" }) {
  return <div className="spinner"><span className="dot" /> {label}…</div>;
}

export function ErrorBox({ message }) {
  return <div className="errbox">{message}</div>;
}

export function Async({ state, children, height }) {
  if (state.loading && !state.data) return <div style={{ minHeight: height || 80 }}><Spinner /></div>;
  if (state.error) return <ErrorBox message={state.error} />;
  return children(state.data);
}

export function Card({ title, subtitle, actions, children, className = "", pad = true }) {
  return (
    <section className={"card " + className}>
      {(title || actions) && (
        <header className="card-h">
          <div>
            {title && <h3>{title}</h3>}
            {subtitle && <p className="muted small">{subtitle}</p>}
          </div>
          {actions && <div className="card-actions">{actions}</div>}
        </header>
      )}
      <div className={pad ? "card-b" : ""}>{children}</div>
    </section>
  );
}

export function Kpi({ label, value, hint, tone }) {
  return (
    <div className={"kpi " + (tone || "")}>
      <div className="kpi-label">{label}</div>
      <div className="kpi-value">{value}</div>
      {hint && <div className="kpi-hint">{hint}</div>}
    </div>
  );
}

const TONES = {
  STOCKOUT: "red", CRITICAL: "red", LOW: "amber", HEALTHY: "green", OVERSTOCK: "blue",
  ORDER: "red", WATCH: "amber", OPEN: "blue", APPROVED: "violet", IN_TRANSIT: "violet",
  RECEIVED: "green", DISMISSED: "gray", CANCELLED: "gray", DRAFT: "gray", PLACED: "violet",
  ADMIN: "violet", MANAGER: "blue", VIEWER: "gray",
};
export function Badge({ children, tone }) {
  const t = tone || TONES[String(children)] || "gray";
  return <span className={"badge " + t}>{String(children).replace("_", " ")}</span>;
}

export function Table({ columns, rows, empty = "No rows", onRowClick, dense }) {
  if (!rows || rows.length === 0) return <div className="empty">{empty}</div>;
  return (
    <div className="table-wrap">
      <table className={"tbl" + (dense ? " dense" : "") + (onRowClick ? " click" : "")}>
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key} className={c.align === "right" ? "r" : ""}>{c.label}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={r.id ?? i} onClick={onRowClick ? () => onRowClick(r) : undefined}>
              {columns.map((c) => (
                <td key={c.key} className={(c.align === "right" ? "r " : "") + (c.mono ? "mono" : "")}>
                  {c.render ? c.render(r) : r[c.key] ?? "–"}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function Pagination({ page, pageSize, total, onPage }) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  return (
    <div className="pager">
      <span className="muted small">{num(total)} rows · page {page} of {pages}</span>
      <div>
        <button className="btn ghost sm" disabled={page <= 1} onClick={() => onPage(page - 1)}>Previous</button>
        <button className="btn ghost sm" disabled={page >= pages} onClick={() => onPage(page + 1)}>Next</button>
      </div>
    </div>
  );
}

export function Modal({ title, onClose, children, wide }) {
  useEffect(() => {
    const h = (e) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [onClose]);
  return (
    <div className="modal-bg" onMouseDown={onClose}>
      <div className={"modal" + (wide ? " wide" : "")} onMouseDown={(e) => e.stopPropagation()}>
        <header className="card-h">
          <h3>{title}</h3>
          <button className="btn ghost sm" onClick={onClose}>Close</button>
        </header>
        <div className="card-b">{children}</div>
      </div>
    </div>
  );
}

export function Field({ label, children }) {
  return <label className="field"><span>{label}</span>{children}</label>;
}

/* Recharts dark tooltip style */
export const tooltipStyle = {
  contentStyle: { background: "#161b26", border: "1px solid #2a3142", borderRadius: 8, fontSize: 12 },
  labelStyle: { color: "#9aa4b8" },
  itemStyle: { color: "#e6e9f0" },
};
export const COLORS = {
  blue: "#5b9dff", green: "#34d39a", amber: "#f5b94a", red: "#ff6b7a", violet: "#a78bfa", teal: "#2dd4bf", grid: "#222a3b", axis: "#6b7590",
};
