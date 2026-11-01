import { useState, useEffect } from "react";
import { api } from "../api";
import { Async, Card, Table, useAsync, useToast, num } from "../components/ui";

const KW = "SELECT|FROM|WHERE|GROUP BY|ORDER BY|PARTITION BY|OVER|WITH|AS|JOIN|LEFT|INNER|CROSS|APPLY|ON|AND|OR|NOT|IN|IS|NULL|CASE|WHEN|THEN|ELSE|END|TOP|DISTINCT|UNION|ALL|ROWS|BETWEEN|PRECEDING|FOLLOWING|CURRENT|ROW|DESC|ASC|HAVING|EXEC|SET|OPTION|RECURSIVE|INSERT|UPDATE|DELETE|INTO|VALUES|DECLARE|BEGIN|TRY|CATCH|BY|LIKE";
const FN = "SUM|AVG|COUNT|MIN|MAX|LAG|LEAD|RANK|DENSE_RANK|ROW_NUMBER|NTILE|CAST|CONVERT|ISNULL|NULLIF|COALESCE|DATEADD|DATEDIFF|ROUND|SQRT|STDEV|JSON_VALUE|ISJSON|FORMAT|FLOOR|CEILING|ABS|OBJECT_ID";

function highlight(sql) {
  const esc = sql.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return esc
    .replace(/(--[^\n]*)/g, '<span class="cm">$1</span>')
    .replace(/('[^']*')/g, '<span class="str">$1</span>')
    .replace(new RegExp("\\b(" + FN + ")(?=\\s*\\()", "gi"), '<span class="fn">$1</span>')
    .replace(new RegExp("\\b(" + KW + ")\\b(?![^<]*>)", "gi"), '<span class="kw">$1</span>')
    .replace(/\b(\d+(\.\d+)?)\b(?![^<]*>)/g, '<span class="nm">$1</span>');
}

export function SqlBlock({ sql }) {
  return <div className="code" dangerouslySetInnerHTML={{ __html: highlight(sql) }} />;
}

export default function Showcase() {
  const toast = useToast();
  const list = useAsync(() => api.get("/showcase"), []);
  const [key, setKey] = useState(null);
  const [result, setResult] = useState(null);
  const [running, setRunning] = useState(false);
  const [showSql, setShowSql] = useState(true);

  useEffect(() => { if (list.data && !key) setKey(list.data[0]?.key); }, [list.data, key]);
  useEffect(() => { setResult(null); }, [key]);

  const run = async () => {
    setRunning(true);
    try { setResult(await api.post(`/showcase/${key}/run`)); }
    catch (e) { toast(e.message, "err"); } finally { setRunning(false); }
  };

  return (
    <>
      <div className="page-h">
        <div><h1>SQL Showcase</h1><p>The queries behind the dashboard. Pick a topic, read the SQL, run it live against SQL Server and see the timing.</p></div>
      </div>
      <Async state={list} height={200}>
        {(items) => {
          const cur = items.find((i) => i.key === key) || items[0];
          return (
            <div className="grid" style={{ gridTemplateColumns: "260px 1fr", alignItems: "start" }}>
              <Card pad={false} title="Topics">
                <div>
                  {items.map((i) => (
                    <div key={i.key} onClick={() => setKey(i.key)}
                      style={{ padding: "11px 16px", cursor: "pointer", borderBottom: "1px solid #1b2232", background: i.key === cur.key ? "#1a2338" : "transparent", boxShadow: i.key === cur.key ? "inset 2px 0 0 var(--blue)" : "none" }}>
                      <div style={{ fontWeight: 500 }}>{i.title}</div>
                      <div style={{ marginTop: 4 }}>{(i.tags || []).map((t) => <span key={t} className="chip">{t}</span>)}</div>
                    </div>
                  ))}
                </div>
              </Card>

              <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
                <Card title={cur.title} actions={
                  <>
                    <button className="btn ghost sm" onClick={() => setShowSql((s) => !s)}>{showSql ? "Hide SQL" : "View SQL"}</button>
                    <button className="btn" disabled={running} onClick={run}>{running ? "Running…" : "Run live"}</button>
                  </>
                }>
                  <p style={{ lineHeight: 1.6 }}>{cur.explanation}</p>
                  {cur.plan_note && <p className="muted small" style={{ marginTop: 10 }}>Execution plan tip: {cur.plan_note}</p>}
                  {cur.warmup && <p className="muted small" style={{ marginTop: 6 }}>The first run can be slower while SQL Server loads data into memory. Run it twice for a fair timing.</p>}
                </Card>

                {cur.queries.map((q, i) => {
                  const r = result && result.key === cur.key ? result.results[i] : null;
                  return (
                    <Card key={q.label} title={q.label} actions={r && <span className="chip">{num(r.elapsed_ms, 0)} ms · {num(r.row_count)} rows</span>}>
                      {showSql && <SqlBlock sql={q.sql} />}
                      {r && (
                        <div style={{ marginTop: showSql ? 14 : 0 }}>
                          <Table dense empty="Query returned no rows" rows={r.rows.map((row, j) => ({ id: j, ...Object.fromEntries(r.columns.map((c, k) => [c, Array.isArray(row) ? row[k] : row[c]])) }))}
                            columns={r.columns.map((c) => ({ key: c, label: c, render: (row) => fmt(row[c]) }))} />
                          {r.row_count > r.rows.length && <p className="muted small" style={{ marginTop: 8 }}>Showing the first {r.rows.length} of {num(r.row_count)} rows.</p>}
                        </div>
                      )}
                    </Card>
                  );
                })}
              </div>
            </div>
          );
        }}
      </Async>
    </>
  );
}

function fmt(v) {
  if (v === null || v === undefined) return "–";
  if (typeof v === "number") return Number.isInteger(v) ? num(v) : num(v, 2);
  if (typeof v === "boolean") return v ? "yes" : "no";
  const s = String(v);
  return /^\d{4}-\d{2}-\d{2}T/.test(s) ? s.slice(0, 10) : s;
}
