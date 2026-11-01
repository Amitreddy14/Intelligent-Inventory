import { useState } from "react";
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Legend } from "recharts";
import { api } from "../api";
import { useAuth } from "../auth";
import { useSim } from "../sim";
import { Async, Card, Kpi, Field, Table, Badge, useAsync, useToast, num, money, dateStr, tooltipStyle, COLORS } from "../components/ui";

export default function Simulation() {
  const { version, bump } = useSim();
  const { can } = useAuth();
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const [last, setLast] = useState(null);
  const [days, setDays] = useState(7);

  const state = useAsync(() => api.get("/simulation/state"), [version]);
  const events = useAsync(() => api.get("/simulation/events"), [version]);
  const trend = useAsync(() => api.get("/dashboard/sales-trend", { days: 45 }), [version]);
  const suppliers = useAsync(() => api.get("/suppliers"), []);
  const cats = useAsync(() => api.get("/categories"), []);

  const call = async (fn, okMsg) => {
    setBusy(true);
    try { const r = await fn(); if (okMsg) toast(typeof okMsg === "function" ? okMsg(r) : okMsg); bump(); return r; }
    catch (e) { toast(e.message, "err"); } finally { setBusy(false); }
  };

  const advance = async (n) => {
    const r = await call(() => api.post("/simulation/advance", { days: n }), (x) => `Advanced to ${dateStr(x.NewSimDate)}`);
    if (r) setLast(r);
  };
  const reset = () => {
    if (!window.confirm("Reset the simulation to 1 Nov 2026 and restore the starting stock? Orders and sales created since will be removed.")) return;
    call(() => api.post("/simulation/reset"), "Simulation reset to the starting state").then(() => setLast(null));
  };

  const mgr = can("MANAGER");

  return (
    <>
      <div className="page-h">
        <div><h1>Simulation</h1><p>Move the clock forward and watch sales, stock, forecasts and recommendations update. Every step is a stored procedure.</p></div>
        {can("ADMIN") && <button className="btn danger sm" disabled={busy} onClick={reset}>Reset simulation</button>}
      </div>

      <Async state={state}>
        {(s) => (
          <div className="grid g3 mb">
            <Kpi label="Simulated date" value={dateStr(s.sim_date)} tone="violet" />
            <Kpi label="Orders on the way" value={num(s.open_orders?.Orders)} hint={s.open_orders?.NextArrival ? "next arrival " + dateStr(s.open_orders.NextArrival) : "none"} />
            <Kpi label="Active demand spikes" value={num(s.active_spikes.length)} tone={s.active_spikes.length ? "amber" : ""} hint={s.active_spikes[0]?.Description || "demand is normal"} />
          </div>
        )}
      </Async>

      {!mgr && <div className="errbox mb" style={{ background: "rgba(91,157,255,.08)", borderColor: "rgba(91,157,255,.3)", color: "#b9d3ff" }}>You are signed in as a viewer, so simulation controls are read-only. Sign in as manager or admin to run scenarios.</div>}

      <div className="grid g2 mb">
        <Card title="Advance time" subtitle="usp_AdvanceDays loops usp_SimStep in one transaction, then refreshes forecasts and recommendations">
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 14 }}>
            {[1, 7, 14, 30].map((n) => <button key={n} className="btn" disabled={!mgr || busy} onClick={() => advance(n)}>+{n} day{n > 1 ? "s" : ""}</button>)}
          </div>
          <div style={{ display: "flex", gap: 8, alignItems: "end" }}>
            <Field label="Custom days (1 to 60)"><input type="number" min="1" max="60" value={days} onChange={(e) => setDays(Number(e.target.value))} style={{ width: 120 }} /></Field>
            <button className="btn ghost" disabled={!mgr || busy || days < 1 || days > 60} onClick={() => advance(days)}>Advance</button>
          </div>
          {busy && <p className="muted small" style={{ marginTop: 12 }}>Running in SQL Server, this can take a few seconds…</p>}
          {last && (
            <>
              <div className="sep" />
              <p className="muted small" style={{ marginBottom: 8 }}>Last run: {dateStr(last.FromDate)} → {dateStr(last.ToDate)} ({last.DaysAdvanced} days)</p>
              <div className="grid g2">
                <Kpi label="Units sold" value={num(last.UnitsSold)} tone="green" hint={money(last.Revenue)} />
                <Kpi label="Units lost" value={num(last.UnitsLost)} tone="red" hint={money(last.LostRevenue) + " missed"} />
              </div>
              <p className="small" style={{ marginTop: 10 }}>Orders received: <b>{num(last.OrdersReceived)}</b></p>
            </>
          )}
        </Card>

        <Card title="Sales since the start" subtitle="Last 45 days; lost units appear when stock runs out">
          <Async state={trend} height={260}>
            {(d) => (
              <ResponsiveContainer width="100%" height={260}>
                <AreaChart data={d.map((r) => ({ ...r, date: String(r.SaleDate).slice(5, 10) }))}>
                  <CartesianGrid stroke={COLORS.grid} vertical={false} />
                  <XAxis dataKey="date" stroke={COLORS.axis} fontSize={11} interval={Math.floor(d.length / 7)} />
                  <YAxis stroke={COLORS.axis} fontSize={11} />
                  <Tooltip {...tooltipStyle} />
                  <Legend />
                  <Area dataKey="Units" name="Units sold" stroke={COLORS.blue} fill={COLORS.blue} fillOpacity={0.2} strokeWidth={2} />
                  <Area dataKey="LostUnits" name="Lost units" stroke={COLORS.red} fill={COLORS.red} fillOpacity={0.25} strokeWidth={2} />
                </AreaChart>
              </ResponsiveContainer>
            )}
          </Async>
        </Card>
      </div>

      <div className="grid g3 mb">
        <Spike disabled={!mgr || busy} cats={cats.data || []} onRun={(b) => call(() => api.post("/simulation/demand-spike", b), "Demand spike scheduled")} />
        <Delay disabled={!mgr || busy} suppliers={suppliers.data || []} onRun={(b) => call(() => api.post("/simulation/supplier-delay", b), "Supplier delay applied to open orders")} />
        <Price disabled={!mgr || busy} onRun={(b) => call(() => api.post("/simulation/price-change", b), "Price updated (audited by trigger)")} />
      </div>

      <Card title="Event log" subtitle="Everything the simulation has done" pad={false}>
        <Async state={events}>
          {(d) => (
            <Table dense rows={d.map((r) => ({ ...r, id: r.EventId }))} empty="No events yet. Advance time or run a scenario." columns={[
              { key: "EventId", label: "#", mono: true },
              { key: "EventType", label: "Type", render: (r) => <Badge tone="violet">{r.EventType}</Badge> },
              { key: "SimDate", label: "Sim date", render: (r) => dateStr(r.SimDate) },
              { key: "Description", label: "Description" },
              { key: "CreatedBy", label: "By" },
            ]} />
          )}
        </Async>
      </Card>
    </>
  );
}

function Spike({ onRun, disabled, cats }) {
  const [scope, setScope] = useState("category");
  const [id, setId] = useState("");
  const [mult, setMult] = useState(2);
  const [d, setD] = useState(7);
  const tops = cats.filter((c) => !c.ParentCategoryId);
  const run = () => {
    const body = { multiplier: Number(mult), days: Number(d) };
    if (scope === "product") body.product_id = Number(id); else body.category_id = Number(id || tops[0]?.CategoryId);
    onRun(body);
  };
  return (
    <Card title="Demand spike" subtitle="Multiplies demand for a category or product">
      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <Field label="Target">
          <select value={scope} onChange={(e) => { setScope(e.target.value); setId(""); }}>
            <option value="category">Category</option><option value="product">Single product (ID)</option>
          </select>
        </Field>
        {scope === "category" ? (
          <Field label="Category">
            <select value={id} onChange={(e) => setId(e.target.value)}>
              {cats.map((c) => <option key={c.CategoryId} value={c.CategoryId}>{c.ParentCategoryId ? "— " : ""}{c.Name}</option>)}
            </select>
          </Field>
        ) : (
          <Field label="Product ID"><input type="number" min="1" value={id} onChange={(e) => setId(e.target.value)} placeholder="e.g. 42" /></Field>
        )}
        <div className="grid g2">
          <Field label="Multiplier (×)"><input type="number" step="0.1" min="0.1" max="10" value={mult} onChange={(e) => setMult(e.target.value)} /></Field>
          <Field label="Days"><input type="number" min="1" max="60" value={d} onChange={(e) => setD(e.target.value)} /></Field>
        </div>
        <button className="btn" disabled={disabled || (scope === "product" && !id)} onClick={run}>Start spike</button>
      </div>
    </Card>
  );
}

function Delay({ onRun, disabled, suppliers }) {
  const [sid, setSid] = useState("");
  const [days, setDays] = useState(7);
  return (
    <Card title="Supplier delay" subtitle="Pushes back every open order from one supplier">
      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <Field label="Supplier">
          <select value={sid} onChange={(e) => setSid(e.target.value)}>
            <option value="">Choose…</option>
            {suppliers.map((s) => <option key={s.SupplierId} value={s.SupplierId}>{s.Name}</option>)}
          </select>
        </Field>
        <Field label="Delay (days, 1 to 30)"><input type="number" min="1" max="30" value={days} onChange={(e) => setDays(e.target.value)} /></Field>
        <button className="btn" disabled={disabled || !sid} onClick={() => onRun({ supplier_id: Number(sid), delay_days: Number(days) })}>Apply delay</button>
      </div>
    </Card>
  );
}

function Price({ onRun, disabled }) {
  const [pid, setPid] = useState("");
  const [cost, setCost] = useState("");
  const [price, setPrice] = useState("");
  const go = () => {
    const b = { product_id: Number(pid) };
    if (cost) b.new_cost = Number(cost);
    if (price) b.new_price = Number(price);
    onRun(b);
  };
  return (
    <Card title="Price / cost change" subtitle="Updates the product; a trigger writes the audit row">
      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <Field label="Product ID"><input type="number" min="1" value={pid} onChange={(e) => setPid(e.target.value)} placeholder="e.g. 42" /></Field>
        <div className="grid g2">
          <Field label="New unit cost"><input type="number" step="0.01" value={cost} onChange={(e) => setCost(e.target.value)} /></Field>
          <Field label="New unit price"><input type="number" step="0.01" value={price} onChange={(e) => setPrice(e.target.value)} /></Field>
        </div>
        <button className="btn" disabled={disabled || !pid || (!cost && !price)} onClick={go}>Apply change</button>
      </div>
    </Card>
  );
}
