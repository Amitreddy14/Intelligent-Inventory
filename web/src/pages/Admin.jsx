import { useState } from "react";
import { api } from "../api";
import { useAuth } from "../auth";
import { Async, Card, Table, Badge, Field, Modal, useAsync, useToast, dateStr } from "../components/ui";

export default function Admin() {
  const [tab, setTab] = useState("users");
  return (
    <>
      <div className="page-h">
        <div><h1>Administration</h1><p>Manage users and review the audit trail written by database triggers.</p></div>
        <div className="tabs">
          <button className={"tab" + (tab === "users" ? " on" : "")} onClick={() => setTab("users")}>Users</button>
          <button className={"tab" + (tab === "audit" ? " on" : "")} onClick={() => setTab("audit")}>Audit log</button>
        </div>
      </div>
      {tab === "users" ? <Users /> : <Audit />}
    </>
  );
}

function Users() {
  const { user } = useAuth();
  const toast = useToast();
  const [n, setN] = useState(0);
  const [adding, setAdding] = useState(false);
  const list = useAsync(() => api.get("/admin/users"), [n]);

  const patch = async (id, body, msg) => {
    try { await api.patch("/admin/users/" + id, body); toast(msg); setN((x) => x + 1); }
    catch (e) { toast(e.message, "err"); }
  };
  const resetPw = (u) => {
    const pw = window.prompt(`New password for ${u.Username} (min 8 characters):`);
    if (pw) patch(u.UserId, { password: pw }, "Password updated");
  };

  return (
    <>
      <div className="filters"><div className="spacer" /><button className="btn" onClick={() => setAdding(true)}>Add user</button></div>
      <Card pad={false}>
        <Async state={list}>
          {(d) => (
            <Table rows={d.map((r) => ({ ...r, id: r.UserId }))} columns={[
              { key: "Username", label: "Username", mono: true },
              { key: "FullName", label: "Name" },
              { key: "Role", label: "Role", render: (r) => (
                <select value={r.Role} disabled={r.Username === user.username} onChange={(e) => patch(r.UserId, { role: e.target.value }, "Role changed")}>
                  <option>ADMIN</option><option>MANAGER</option><option>VIEWER</option>
                </select>) },
              { key: "IsActive", label: "Status", render: (r) => <Badge tone={r.IsActive ? "green" : "gray"}>{r.IsActive ? "ACTIVE" : "DISABLED"}</Badge> },
              { key: "LastLoginAt", label: "Last login", render: (r) => dateStr(r.LastLoginAt) },
              { key: "act", label: "", render: (r) => (
                <div style={{ display: "flex", gap: 6 }}>
                  <button className="btn ghost sm" onClick={() => resetPw(r)}>Reset password</button>
                  {r.Username !== user.username && (
                    <button className="btn ghost sm" onClick={() => patch(r.UserId, { is_active: !r.IsActive }, r.IsActive ? "User disabled" : "User enabled")}>{r.IsActive ? "Disable" : "Enable"}</button>
                  )}
                </div>) },
            ]} />
          )}
        </Async>
      </Card>
      {adding && <AddUser onClose={() => setAdding(false)} onDone={() => { setAdding(false); setN((x) => x + 1); }} />}
    </>
  );
}

function AddUser({ onClose, onDone }) {
  const toast = useToast();
  const [f, setF] = useState({ username: "", full_name: "", password: "", role: "VIEWER" });
  const set = (k, v) => setF((x) => ({ ...x, [k]: v }));
  const save = async (e) => {
    e.preventDefault();
    try { await api.post("/admin/users", f); toast("User created"); onDone(); } catch (x) { toast(x.message, "err"); }
  };
  return (
    <Modal title="Add user" onClose={onClose}>
      <form onSubmit={save} style={{ display: "flex", flexDirection: "column", gap: 12 }}>
        <Field label="Username"><input value={f.username} onChange={(e) => set("username", e.target.value)} required minLength={3} /></Field>
        <Field label="Full name"><input value={f.full_name} onChange={(e) => set("full_name", e.target.value)} required /></Field>
        <Field label="Password (min 8 characters)"><input type="password" value={f.password} onChange={(e) => set("password", e.target.value)} required minLength={8} /></Field>
        <Field label="Role"><select value={f.role} onChange={(e) => set("role", e.target.value)}><option>VIEWER</option><option>MANAGER</option><option>ADMIN</option></select></Field>
        <button className="btn">Create user</button>
      </form>
    </Modal>
  );
}

function Audit() {
  const [table, setTable] = useState("");
  const list = useAsync(() => api.get("/admin/audit", { table_name: table, limit: 100 }), [table]);
  return (
    <>
      <div className="filters">
        <Field label="Table">
          <select value={table} onChange={(e) => setTable(e.target.value)}>
            <option value="">All</option><option>Inventory</option><option>Product</option><option>PurchaseOrder</option><option>AppUser</option>
          </select>
        </Field>
      </div>
      <Card pad={false} title="Audit trail" subtitle="Rows inserted by AFTER triggers. The acting user comes from SESSION_CONTEXT.">
        <Async state={list} height={240}>
          {(d) => (
            <Table dense rows={d.map((r) => ({ ...r, id: r.AuditId }))} empty="No audit rows yet." columns={[
              { key: "EventTime", label: "Time", render: (r) => String(r.EventTime).replace("T", " ").slice(0, 19) },
              { key: "UserName", label: "User" },
              { key: "TableName", label: "Table" },
              { key: "Operation", label: "Op", render: (r) => <Badge tone={r.Operation === "INSERT" ? "green" : r.Operation === "DELETE" ? "red" : "blue"}>{r.Operation}</Badge> },
              { key: "KeyValue", label: "Key", mono: true },
              { key: "OldValues", label: "Before", render: (r) => <span className="mono muted">{r.OldValues || "–"}</span> },
              { key: "NewValues", label: "After", render: (r) => <span className="mono">{r.NewValues || "–"}</span> },
            ]} />
          )}
        </Async>
      </Card>
    </>
  );
}
