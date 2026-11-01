import { useState } from "react";
import { api } from "../api";
import { useAuth } from "../auth";
import { useSim } from "../sim";
import { Async, Card, Table, Badge, Pagination, Modal, Kpi, useAsync, useToast, num, money, dateStr } from "../components/ui";

export default function Procurement() {
  const [tab, setTab] = useState("recs");
  return (
    <>
      <div className="page-h">
        <div><h1>Procurement</h1><p>Recommendations from <span className="mono">usp_GenerateRecommendations</span> (EOQ, reorder point, safety stock). Approving one calls a stored procedure that creates the purchase order.</p></div>
        <div className="tabs">
          <button className={"tab" + (tab === "recs" ? " on" : "")} onClick={() => setTab("recs")}>Recommendations</button>
          <button className={"tab" + (tab === "po" ? " on" : "")} onClick={() => setTab("po")}>Purchase orders</button>
        </div>
      </div>
      {tab === "recs" ? <Recs /> : <Orders />}
    </>
  );
}

function Recs() {
  const { version, bump } = useSim();
  const { can } = useAuth();
  const toast = useToast();
  const [status, setStatus] = useState("OPEN");
  const [action, setAction] = useState("");
  const [page, setPage] = useState(1);
  const [busy, setBusy] = useState(null);
  const list = useAsync(() => api.get("/recommendations", { status, action, page, page_size: 12 }), [status, action, page, version]);

  const act = async (id, what) => {
    setBusy(id);
    try {
      const r = await api.post(`/recommendations/${id}/${what}`);
      toast(what === "approve" ? `Purchase order #${r.po_id} created` : "Recommendation dismissed");
      bump();
    } catch (e) { toast(e.message, "err"); } finally { setBusy(null); }
  };
  const refresh = async () => {
    setBusy("refresh");
    try { await api.post("/recommendations/refresh"); toast("Recommendations recalculated in SQL"); bump(); }
    catch (e) { toast(e.message, "err"); } finally { setBusy(null); }
  };

  return (
    <>
      <Async state={list}>
        {(d) => {
          const s = d.open_summary || [];
          const sum = (f) => s.filter(f).reduce((a, r) => a + Number(r.Items || 0), 0);
          return (
            <div className="grid g4 mb">
              <Kpi label="Open: order now" value={num(sum((r) => r.Action === "ORDER"))} tone="red" hint="items needing a purchase order" />
              <Kpi label="Urgent (P1)" value={num(sum((r) => r.Action === "ORDER" && r.Priority === 1))} tone="amber" hint="at or near stockout" />
              <Kpi label="Watch" value={num(sum((r) => r.Action === "WATCH"))} tone="violet" hint="close to reorder point" />
              <Kpi label="Overstock" value={num(sum((r) => r.Action === "OVERSTOCK"))} hint="more than needed" />
            </div>
          );
        }}
      </Async>
      <div className="filters">
        <div className="field"><span>Status</span>
          <select value={status} onChange={(e) => { setStatus(e.target.value); setPage(1); }}>
            <option value="OPEN">Open</option><option value="APPROVED">Approved</option><option value="DISMISSED">Dismissed</option><option value="">All</option>
          </select>
        </div>
        <div className="field"><span>Action</span>
          <select value={action} onChange={(e) => { setAction(e.target.value); setPage(1); }}>
            <option value="">All</option><option>ORDER</option><option>WATCH</option><option>OVERSTOCK</option>
          </select>
        </div>
        <div className="spacer" />
        {can("MANAGER") && <button className="btn ghost" disabled={busy === "refresh"} onClick={refresh}>Recalculate</button>}
      </div>
      <Card pad={false}>
        <Async state={list} height={300}>
          {(d) => (
            <>
              <Table dense rows={d.items.map((r) => ({ ...r, id: r.RecId }))} columns={[
                { key: "Priority", label: "P", render: (r) => <Badge tone={r.Priority <= 1 ? "red" : r.Priority === 2 ? "amber" : "gray"}>{"P" + r.Priority}</Badge> },
                { key: "Action", label: "Action", render: (r) => <Badge>{r.Action}</Badge> },
                { key: "ProductName", label: "Product", render: (r) => <div>{r.ProductName}<div className="muted small mono">{r.Sku}</div></div> },
                { key: "City", label: "Warehouse" },
                { key: "SupplierName", label: "Supplier", render: (r) => <div>{r.SupplierName || "–"}<div className="muted small">{r.LeadTimeDays ? r.LeadTimeDays + " day lead" : ""}</div></div> },
                { key: "OrderQty", label: "Qty", align: "right", render: (r) => num(r.OrderQty) },
                { key: "EstimatedCost", label: "Est. cost", align: "right", render: (r) => money(r.EstimatedCost) },
                { key: "Reason", label: "Why", render: (r) => <span className="muted small">{r.Reason}</span> },
                { key: "Status", label: "Status", render: (r) => <Badge>{r.Status}</Badge> },
                { key: "act", label: "", render: (r) => r.Status === "OPEN" && r.Action === "ORDER" && can("MANAGER") ? (
                  <div style={{ display: "flex", gap: 6 }}>
                    <button className="btn good sm" disabled={busy === r.RecId} onClick={() => act(r.RecId, "approve")}>Approve</button>
                    <button className="btn ghost sm" disabled={busy === r.RecId} onClick={() => act(r.RecId, "dismiss")}>Dismiss</button>
                  </div>) : null },
              ]} empty="Nothing to show for this filter." />
              <Pagination page={d.page} pageSize={d.page_size} total={d.total} onPage={setPage} />
            </>
          )}
        </Async>
      </Card>
    </>
  );
}

function Orders() {
  const { version, bump } = useSim();
  const { can } = useAuth();
  const toast = useToast();
  const [status, setStatus] = useState("");
  const [page, setPage] = useState(1);
  const [open, setOpen] = useState(null);
  const list = useAsync(() => api.get("/purchase-orders", { status, page, page_size: 12 }), [status, page, version]);

  const receive = async (id) => {
    try { await api.post(`/purchase-orders/${id}/receive`); toast(`Order #${id} received into stock`); setOpen(null); bump(); }
    catch (e) { toast(e.message, "err"); }
  };

  return (
    <>
      <div className="filters">
        <div className="field"><span>Status</span>
          <select value={status} onChange={(e) => { setStatus(e.target.value); setPage(1); }}>
            <option value="">All</option><option>APPROVED</option><option>IN_TRANSIT</option><option>RECEIVED</option><option>CANCELLED</option>
          </select>
        </div>
      </div>
      <Card pad={false}>
        <Async state={list} height={260}>
          {(d) => (
            <>
              <Table onRowClick={(r) => setOpen(r)} dense rows={d.items.map((r) => ({ ...r, id: r.PoId }))} columns={[
                { key: "PoId", label: "PO #", mono: true },
                { key: "SupplierName", label: "Supplier" },
                { key: "WarehouseCity", label: "Warehouse" },
                { key: "Lines", label: "Lines", align: "right" },
                { key: "TotalCost", label: "Total", align: "right", render: (r) => money(r.TotalCost) },
                { key: "OrderDate", label: "Ordered", render: (r) => dateStr(r.OrderDate) },
                { key: "ExpectedDate", label: "Expected", render: (r) => dateStr(r.ExpectedDate) },
                { key: "ReceivedDate", label: "Received", render: (r) => dateStr(r.ReceivedDate) },
                { key: "Status", label: "Status", render: (r) => <Badge>{r.Status}</Badge> },
                { key: "CreatedBy", label: "By" },
              ]} empty="No purchase orders yet. Approve a recommendation to create one." />
              <Pagination page={d.page} pageSize={d.page_size} total={d.total} onPage={setPage} />
            </>
          )}
        </Async>
      </Card>
      {open && <PoModal po={open} canReceive={can("MANAGER")} onReceive={receive} onClose={() => setOpen(null)} />}
    </>
  );
}

function PoModal({ po, canReceive, onReceive, onClose }) {
  const d = useAsync(() => api.get("/purchase-orders/" + po.PoId), [po.PoId]);
  return (
    <Modal wide title={`Purchase order #${po.PoId}`} onClose={onClose}>
      <Async state={d}>
        {(x) => (
          <>
            <p className="muted" style={{ marginBottom: 12 }}>{po.SupplierName} → {po.WarehouseCity} · <Badge>{po.Status}</Badge></p>
            <Table dense rows={x.lines.map((l, i) => ({ ...l, id: i }))} columns={[
              { key: "Sku", label: "SKU", mono: true },
              { key: "ProductName", label: "Product" },
              { key: "Quantity", label: "Qty", align: "right", render: (r) => num(r.Quantity) },
              { key: "UnitPrice", label: "Unit price", align: "right", render: (r) => money(r.UnitPrice) },
              { key: "LineTotal", label: "Line total", align: "right", render: (r) => money(r.LineTotal) },
            ]} />
            {canReceive && ["APPROVED", "IN_TRANSIT"].includes(po.Status) && (
              <div style={{ marginTop: 14, textAlign: "right" }}>
                <button className="btn good" onClick={() => onReceive(po.PoId)}>Receive now (usp_ReceivePo)</button>
              </div>
            )}
          </>
        )}
      </Async>
    </Modal>
  );
}
