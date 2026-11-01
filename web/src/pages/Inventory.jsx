import { useState } from "react";
import { api } from "../api";
import { useSim } from "../sim";
import { Async, Card, Table, Badge, Pagination, Modal, Field, Kpi, useAsync, num, money, dateStr } from "../components/ui";

const STATUSES = ["STOCKOUT", "CRITICAL", "LOW", "HEALTHY", "OVERSTOCK"];

export default function Inventory() {
  const { version } = useSim();
  const [f, setF] = useState({ warehouse_id: "", status: "", category_id: "", search: "" });
  const [page, setPage] = useState(1);
  const [detail, setDetail] = useState(null);
  const set = (k, v) => { setF((x) => ({ ...x, [k]: v })); setPage(1); };

  const wh = useAsync(() => api.get("/warehouses"), []);
  const cats = useAsync(() => api.get("/categories"), []);
  const list = useAsync(() => api.get("/inventory", { ...f, page, page_size: 15 }), [f, page, version]);

  return (
    <>
      <div className="page-h"><div><h1>Inventory</h1><p>Live stock position from <span className="mono">vw_StockHealth</span>. Click a row for details.</p></div></div>

      <div className="filters">
        <Field label="Search"><input value={f.search} onChange={(e) => set("search", e.target.value)} placeholder="Product or SKU" /></Field>
        <Field label="Warehouse">
          <select value={f.warehouse_id} onChange={(e) => set("warehouse_id", e.target.value)}>
            <option value="">All</option>
            {(wh.data || []).map((w) => <option key={w.WarehouseId} value={w.WarehouseId}>{w.City}</option>)}
          </select>
        </Field>
        <Field label="Status">
          <select value={f.status} onChange={(e) => set("status", e.target.value)}>
            <option value="">All</option>
            {STATUSES.map((s) => <option key={s}>{s}</option>)}
          </select>
        </Field>
        <Field label="Category">
          <select value={f.category_id} onChange={(e) => set("category_id", e.target.value)}>
            <option value="">All</option>
            {(cats.data || []).filter((c) => c.ParentCategoryId).map((c) => <option key={c.CategoryId} value={c.CategoryId}>{c.Name}</option>)}
          </select>
        </Field>
      </div>

      <Card pad={false}>
        <Async state={list} height={300}>
          {(d) => (
            <>
              <Table onRowClick={setDetail} dense rows={d.items.map((r) => ({ ...r, id: r.ProductId + "-" + r.WarehouseId }))} columns={[
                { key: "Sku", label: "SKU", mono: true },
                { key: "ProductName", label: "Product" },
                { key: "City", label: "Warehouse" },
                { key: "OnHand", label: "On hand", align: "right", render: (r) => num(r.OnHand) },
                { key: "OnOrder", label: "On order", align: "right", render: (r) => num(r.OnOrder) },
                { key: "ReorderPoint", label: "Reorder pt", align: "right", render: (r) => num(r.ReorderPoint) },
                { key: "AvgDaily28", label: "Avg/day", align: "right", render: (r) => num(r.AvgDaily28, 1) },
                { key: "DaysOfCover", label: "Cover (d)", align: "right", render: (r) => num(r.DaysOfCover, 1) },
                { key: "StockValue", label: "Value", align: "right", render: (r) => money(r.StockValue) },
                { key: "StockStatus", label: "Status", render: (r) => <Badge>{r.StockStatus}</Badge> },
              ]} />
              <Pagination page={d.page} pageSize={d.page_size} total={d.total} onPage={setPage} />
            </>
          )}
        </Async>
      </Card>

      {detail && <ProductModal row={detail} onClose={() => setDetail(null)} />}
    </>
  );
}

function ProductModal({ row, onClose }) {
  const d = useAsync(() => api.get("/products/" + row.ProductId), [row.ProductId]);
  const mv = useAsync(() => api.get("/stock-movements", { product_id: row.ProductId, warehouse_id: row.WarehouseId, limit: 12 }), [row]);
  return (
    <Modal wide title={row.ProductName + " · " + row.City} onClose={onClose}>
      <Async state={d}>
        {(x) => (
          <>
            <div className="grid g4 mb">
              <Kpi label="ABC / XYZ" value={(x.segment?.AbcClass || "–") + " / " + (x.segment?.XyzClass || "–")} tone="violet" hint={"weekly CV " + num(x.segment?.WeeklyCV, 2)} />
              <Kpi label="Unit price" value={money(x.product.UnitPrice)} hint={"cost " + money(x.product.UnitCost)} />
              <Kpi label="On hand" value={num(row.OnHand)} hint={num(row.Reserved) + " reserved"} />
              <Kpi label="Safety stock" value={num(row.SafetyStock)} tone="amber" hint={"reorder at " + num(row.ReorderPoint)} />
            </div>
            <div className="grid g2">
              <div>
                <h3 style={{ marginBottom: 8 }}>Supplier ranking</h3>
                <p className="muted small" style={{ marginBottom: 8 }}>ROW_NUMBER over adjusted cost = price × (1 − discount) ÷ reliability, JSON terms parsed in SQL.</p>
                <Table dense rows={x.suppliers.map((s) => ({ ...s, id: s.SupplierId }))} columns={[
                  { key: "SupplierRank", label: "#" },
                  { key: "SupplierName", label: "Supplier" },
                  { key: "UnitPrice", label: "Price", align: "right", render: (r) => money(r.UnitPrice) },
                  { key: "LeadTimeDays", label: "Lead (d)", align: "right" },
                  { key: "ReliabilityPct", label: "Reliab.", align: "right", render: (r) => num(r.ReliabilityPct, 0) + "%" },
                  { key: "AdjustedUnitCost", label: "Adj. cost", align: "right", render: (r) => num(r.AdjustedUnitCost, 2) },
                ]} />
              </div>
              <div>
                <h3 style={{ marginBottom: 8 }}>Recent stock movements</h3>
                <Async state={mv}>
                  {(m) => (
                    <Table dense rows={m.map((r) => ({ ...r, id: r.MovementId }))} columns={[
                      { key: "MovementDate", label: "Date", render: (r) => dateStr(r.MovementDate) },
                      { key: "MovementType", label: "Type" },
                      { key: "Quantity", label: "Qty", align: "right", render: (r) => num(r.Quantity) },
                      { key: "RefType", label: "Ref", render: (r) => (r.RefType ? r.RefType + " " + (r.RefId ?? "") : "–") },
                    ]} />
                  )}
                </Async>
              </div>
            </div>
          </>
        )}
      </Async>
    </Modal>
  );
}
