import { useNavigate } from "react-router-dom";
import { AreaChart, Area, BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Legend, LineChart, Line } from "recharts";
import { api } from "../api";
import { useSim } from "../sim";
import { Async, Card, Kpi, Table, Badge, useAsync, num, money, compact, tooltipStyle, COLORS } from "../components/ui";

const day = (d) => String(d).slice(5, 10);

export default function Overview() {
  const { version } = useSim();
  const nav = useNavigate();
  const summary = useAsync(() => api.get("/dashboard/summary"), [version]);
  const trend = useAsync(() => api.get("/dashboard/sales-trend", { days: 90 }), [version]);
  const wh = useAsync(() => api.get("/dashboard/stock-by-warehouse"), [version]);
  const cats = useAsync(() => api.get("/dashboard/category-rollup"), [version]);
  const abc = useAsync(() => api.get("/dashboard/abc-xyz"), [version]);
  const top = useAsync(() => api.get("/dashboard/top-sellers", { limit: 8 }), [version]);

  return (
    <>
      <div className="page-h">
        <div><h1>Overview</h1><p>Sales, stock health and work waiting for you, straight from SQL views.</p></div>
      </div>

      <Async state={summary}>
        {(s) => (
          <div className="grid g4 mb">
            <Kpi label="Revenue (30 days)" value={compact(s.sales30.Revenue30)} hint={num(s.sales30.Units30) + " units sold"} />
            <Kpi label="Fill rate" value={num(s.sales30.FillRatePct, 1) + "%"} tone={s.sales30.FillRatePct < 95 ? "amber" : "green"} hint={num(s.sales30.LostUnits30) + " units lost"} />
            <Kpi label="Stock value" value={compact(s.stock.StockValue)} tone="violet" hint={num(s.stock.Items) + " SKU-warehouse items"} />
            <Kpi label="Forecast WAPE" value={num(s.forecast_accuracy?.WapePct, 1) + "%"} tone="green" hint={(s.forecast_accuracy?.Method || "") + " · bias " + num(s.forecast_accuracy?.BiasPct, 1) + "%"} />
            <Kpi label="Stockouts" value={num(s.stock.Stockouts)} tone="red" hint="zero on hand" />
            <Kpi label="Critical / Low" value={num(s.stock.Critical) + " / " + num(s.stock.Low)} tone="amber" hint="below reorder point" />
            <Kpi label="Orders to place" value={num(s.work.OpenOrderRecs)} tone="red" hint={num(s.work.UrgentRecs) + " urgent"} />
            <Kpi label="Open purchase orders" value={num(s.work.OpenPurchaseOrders)} hint="approved or in transit" />
          </div>
        )}
      </Async>

      <div className="grid g21 mb">
        <Card title="Daily sales, last 90 days" subtitle="Units sold vs units lost to stockouts (window query over SalesDaily)">
          <Async state={trend} height={280}>
            {(d) => (
              <ResponsiveContainer width="100%" height={280}>
                <AreaChart data={d.map((r) => ({ ...r, date: day(r.SaleDate) }))}>
                  <defs>
                    <linearGradient id="gu" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stopColor={COLORS.blue} stopOpacity={0.45} /><stop offset="100%" stopColor={COLORS.blue} stopOpacity={0} /></linearGradient>
                  </defs>
                  <CartesianGrid stroke={COLORS.grid} vertical={false} />
                  <XAxis dataKey="date" stroke={COLORS.axis} fontSize={11} interval={Math.floor(d.length / 8)} />
                  <YAxis stroke={COLORS.axis} fontSize={11} />
                  <Tooltip {...tooltipStyle} />
                  <Legend />
                  <Area type="monotone" dataKey="Units" name="Units sold" stroke={COLORS.blue} fill="url(#gu)" strokeWidth={2} />
                  <Area type="monotone" dataKey="LostUnits" name="Lost units" stroke={COLORS.red} fill="none" strokeWidth={2} />
                </AreaChart>
              </ResponsiveContainer>
            )}
          </Async>
        </Card>

        <Card title="Stock health" subtitle="Items by status">
          <Async state={summary} height={280}>
            {(s) => {
              const rows = [
                ["Stockout", s.stock.Stockouts, COLORS.red], ["Critical", s.stock.Critical, "#ff9a6b"],
                ["Low", s.stock.Low, COLORS.amber], ["Healthy", s.stock.Healthy, COLORS.green], ["Overstock", s.stock.Overstock, COLORS.blue],
              ];
              const total = rows.reduce((a, r) => a + Number(r[1] || 0), 0) || 1;
              return (
                <div>
                  <div className="bar" style={{ height: 14, marginBottom: 18 }}>
                    {rows.map(([n, v, c]) => <i key={n} style={{ width: (100 * v) / total + "%", background: c }} />)}
                  </div>
                  <Table dense columns={[
                    { key: "n", label: "Status", render: (r) => <span><i style={{ display: "inline-block", width: 9, height: 9, borderRadius: 2, background: r.c, marginRight: 8 }} />{r.n}</span> },
                    { key: "v", label: "Items", align: "right", render: (r) => num(r.v) },
                    { key: "p", label: "Share", align: "right", render: (r) => num((100 * r.v) / total, 1) + "%" },
                  ]} rows={rows.map(([n, v, c]) => ({ n, v, c }))} />
                </div>
              );
            }}
          </Async>
        </Card>
      </div>

      <div className="grid g2 mb">
        <Card title="Stock status by warehouse" subtitle="Item counts per warehouse">
          <Async state={wh} height={260}>
            {(d) => {
              const map = {};
              d.forEach((r) => { map[r.City] = map[r.City] || { city: r.City }; map[r.City][r.StockStatus] = r.Items; });
              const data = Object.values(map);
              return (
                <ResponsiveContainer width="100%" height={260}>
                  <BarChart data={data}>
                    <CartesianGrid stroke={COLORS.grid} vertical={false} />
                    <XAxis dataKey="city" stroke={COLORS.axis} fontSize={11} />
                    <YAxis stroke={COLORS.axis} fontSize={11} />
                    <Tooltip {...tooltipStyle} cursor={{ fill: "#ffffff08" }} />
                    <Legend />
                    <Bar dataKey="STOCKOUT" name="Stockout" stackId="a" fill={COLORS.red} />
                    <Bar dataKey="CRITICAL" name="Critical" stackId="a" fill="#ff9a6b" />
                    <Bar dataKey="LOW" name="Low" stackId="a" fill={COLORS.amber} />
                    <Bar dataKey="HEALTHY" name="Healthy" stackId="a" fill={COLORS.green} />
                    <Bar dataKey="OVERSTOCK" name="Overstock" stackId="a" fill={COLORS.blue} />
                  </BarChart>
                </ResponsiveContainer>
              );
            }}
          </Async>
        </Card>

        <Card title="Revenue by top category (90 days)" subtitle="Recursive CTE rolls sub-categories into their parent">
          <Async state={cats} height={260}>
            {(d) => (
              <ResponsiveContainer width="100%" height={260}>
                <BarChart data={d} layout="vertical" margin={{ left: 30 }}>
                  <CartesianGrid stroke={COLORS.grid} horizontal={false} />
                  <XAxis type="number" stroke={COLORS.axis} fontSize={11} tickFormatter={compact} />
                  <YAxis type="category" dataKey="TopCategory" stroke={COLORS.axis} fontSize={11} width={110} />
                  <Tooltip {...tooltipStyle} cursor={{ fill: "#ffffff08" }} formatter={(v) => money(v)} />
                  <Bar dataKey="Revenue90" name="Revenue" fill={COLORS.violet} radius={[0, 4, 4, 0]} />
                </BarChart>
              </ResponsiveContainer>
            )}
          </Async>
        </Card>
      </div>

      <div className="grid g2">
        <Card title="ABC / XYZ segmentation" subtitle="ABC = revenue importance · XYZ = demand variability">
          <Async state={abc}>
            {(d) => {
              const A = ["A", "B", "C"], X = ["X", "Y", "Z"];
              const get = (a, x) => d.find((r) => r.AbcClass === a && r.XyzClass === x)?.Products || 0;
              const max = Math.max(1, ...d.map((r) => r.Products));
              return (
                <table className="tbl dense">
                  <thead><tr><th></th>{X.map((x) => <th key={x} className="r">{x}</th>)}</tr></thead>
                  <tbody>
                    {A.map((a) => (
                      <tr key={a}>
                        <td><b>{a}</b></td>
                        {X.map((x) => {
                          const v = get(a, x);
                          return <td key={x} className="r" style={{ background: `rgba(91,157,255,${(v / max) * 0.45})` }}>{num(v)}</td>;
                        })}
                      </tr>
                    ))}
                  </tbody>
                </table>
              );
            }}
          </Async>
        </Card>

        <Card title="Top sellers (90 days)" subtitle="Revenue leaders; the view ranks each category with RANK()" pad={false}>
          <Async state={top}>
            {(d) => (
              <Table dense rows={d} columns={[
                { key: "ProductName", label: "Product" },
                { key: "CategoryName", label: "Category" },
                { key: "Units90", label: "Units", align: "right", render: (r) => num(r.Units90) },
                { key: "Revenue90", label: "Revenue", align: "right", render: (r) => money(r.Revenue90) },
              ]} />
            )}
          </Async>
        </Card>
      </div>
    </>
  );
}
