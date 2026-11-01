import { useState, useMemo } from "react";
import { ComposedChart, Line, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Legend, ReferenceLine } from "recharts";
import { api } from "../api";
import { useAuth } from "../auth";
import { useSim } from "../sim";
import { Async, Card, Kpi, Field, useAsync, useToast, num, tooltipStyle, COLORS } from "../components/ui";

export default function Forecast() {
  const { version, bump } = useSim();
  const { can } = useAuth();
  const toast = useToast();
  const [search, setSearch] = useState("");
  const [productId, setProductId] = useState(null);
  const [warehouseId, setWarehouseId] = useState(1);
  const [method, setMethod] = useState("SEASONAL");
  const [running, setRunning] = useState(false);

  const warehouses = useAsync(() => api.get("/warehouses"), []);
  const products = useAsync(() => api.get("/products", { search, limit: 15 }), [search]);
  const acc = useAsync(() => api.get("/forecast/accuracy"), [version]);
  const item = useAsync(
    () => (productId ? api.get("/forecast/item", { product_id: productId, warehouse_id: warehouseId, history_days: 90 }) : Promise.resolve(null)),
    [productId, warehouseId, version]
  );

  const chart = useMemo(() => {
    const d = item.data;
    if (!d) return [];
    const map = new Map();
    const row = (dt) => { const k = String(dt).slice(0, 10); if (!map.has(k)) map.set(k, { date: k }); return map.get(k); };
    d.history.forEach((h) => { row(h.SaleDate).actual = h.Quantity; });
    d.backtest.filter((b) => b.Method === method).forEach((b) => { row(b.TargetDate).backtest = b.ForecastQty; });
    d.live_forecast.filter((f) => f.Method === method).forEach((f) => {
      const r = row(f.TargetDate);
      r.forecast = f.ForecastQty;
      r.band = [f.LowerBound, f.UpperBound];
    });
    return [...map.values()].sort((a, b) => a.date.localeCompare(b.date));
  }, [item.data, method]);

  const runForecast = async () => {
    setRunning(true);
    try { await api.post("/forecast/run"); toast("Forecast regenerated in SQL (usp_RunForecast)"); bump(); }
    catch (e) { toast(e.message, "err"); } finally { setRunning(false); }
  };

  const today = item.data?.live_forecast?.[0]?.TargetDate?.slice(0, 10);
  const sp = item.data?.stock_params;

  return (
    <>
      <div className="page-h">
        <div><h1>Forecast explorer</h1><p>Pick a product and warehouse. Forecasts come from <span className="mono">usp_RunForecast</span>, written entirely in T-SQL.</p></div>
        {can("MANAGER") && <button className="btn" disabled={running} onClick={runForecast}>{running ? "Running…" : "Re-run live forecast"}</button>}
      </div>

      <Async state={acc}>
        {(rows) => {
          const bt = (rows || []).filter((r) => r.RunType === "BACKTEST");
          const a = [...(bt.length ? bt : rows || [])].sort((x, y) => Number(x.WapePct) - Number(y.WapePct))[0];
          return (
          <div className="grid g4 mb">
            <Kpi label="Best method (backtest)" value={a?.Method || "–"} tone="green" hint={"as of " + String(a?.AsOfDate || "").slice(0, 10)} />
            <Kpi label="WAPE" value={num(a?.WapePct, 2) + "%"} hint="weighted absolute % error" />
            <Kpi label="Bias" value={num(a?.BiasPct, 2) + "%"} tone="violet" hint="+ over-forecast, − under-forecast" />
            <Kpi label="Observations" value={num(a?.Observations)} hint="item-days compared to actuals" />
          </div>
          );
        }}
      </Async>

      <div className="grid" style={{ gridTemplateColumns: "300px 1fr", alignItems: "start" }}>
        <Card title="Choose an item">
          <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
            <Field label="Search product or SKU"><input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="charger, mouse, yoga, SKU-0042" /></Field>
            <Field label="Warehouse">
              <select value={warehouseId} onChange={(e) => setWarehouseId(Number(e.target.value))}>
                {(warehouses.data || []).map((w) => <option key={w.WarehouseId} value={w.WarehouseId}>{w.City}</option>)}
              </select>
            </Field>
            <Field label="Method">
              <select value={method} onChange={(e) => setMethod(e.target.value)}>
                <option value="SEASONAL">SEASONAL (28-day avg × weekday × month)</option>
                <option value="MA28_DOW">MA28_DOW (28-day avg × weekday)</option>
              </select>
            </Field>
            <div style={{ maxHeight: 320, overflow: "auto", border: "1px solid var(--line)", borderRadius: 8 }}>
              {(products.data || []).map((p) => (
                <div key={p.ProductId} onClick={() => setProductId(p.ProductId)}
                  style={{ padding: "8px 10px", cursor: "pointer", borderBottom: "1px solid #1b2232", background: p.ProductId === productId ? "#1a2338" : "transparent" }}>
                  <div style={{ fontWeight: 500 }}>{p.Name || p.ProductName}</div>
                  <div className="muted small mono">{p.Sku}</div>
                </div>
              ))}
              {products.data && products.data.length === 0 && <div className="empty">No match. Try: charger, headphones, mouse, blender, notebook, yoga.</div>}
            </div>
          </div>
        </Card>

        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <Card title="History, backtest and forecast" subtitle="Last 90 days of sales, how the model would have predicted them, and the next 14 days with a 90% range">
            {!productId ? <div className="empty">Select a product on the left.</div> : (
              <Async state={item} height={360}>
                {(d) => d.history.length === 0 ? (
                  <div className="empty">This product is not stocked in this warehouse. Each product is stocked in 3 of the 5 warehouses, so pick another warehouse.</div>
                ) : (
                  <ResponsiveContainer width="100%" height={360}>
                    <ComposedChart data={chart}>
                      <CartesianGrid stroke={COLORS.grid} vertical={false} />
                      <XAxis dataKey="date" stroke={COLORS.axis} fontSize={11} tickFormatter={(d) => d.slice(5)} interval={Math.floor(chart.length / 9)} />
                      <YAxis stroke={COLORS.axis} fontSize={11} />
                      <Tooltip {...tooltipStyle} formatter={(v) => (Array.isArray(v) ? v.map((x) => num(x, 1)).join(" – ") : num(v, 1))} />
                      <Legend />
                      <Area dataKey="band" name="90% range" stroke="none" fill={COLORS.violet} fillOpacity={0.18} />
                      <Line dataKey="actual" name="Actual" stroke={COLORS.blue} dot={false} strokeWidth={2} />
                      <Line dataKey="backtest" name="Backtest" stroke={COLORS.amber} dot={false} strokeDasharray="4 3" strokeWidth={1.5} />
                      <Line dataKey="forecast" name="Forecast" stroke={COLORS.green} dot={{ r: 2 }} strokeWidth={2.5} />
                      {today && <ReferenceLine x={today} stroke="#8f99b0" strokeDasharray="3 3" label={{ value: "today", fill: "#8f99b0", fontSize: 11 }} />}
                    </ComposedChart>
                  </ResponsiveContainer>
                )}
              </Async>
            )}
          </Card>

          {sp && (
            <div className="grid g3">
              <Kpi label="On hand" value={num(sp.OnHand)} />
              <Kpi label="Reorder point" value={num(sp.ReorderPoint)} tone="amber" hint="lead-time demand + safety stock" />
              <Kpi label="Safety stock" value={num(sp.SafetyStock)} tone="violet" hint="z · σ · √lead time" />
            </div>
          )}
        </div>
      </div>
    </>
  );
}
