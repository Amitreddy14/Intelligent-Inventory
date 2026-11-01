import { useState } from "react";
import { useAuth } from "../auth";

const DEMO = [
  { u: "admin", p: "Admin@123", r: "Admin" },
  { u: "manager", p: "Manager@123", r: "Manager" },
  { u: "viewer", p: "Viewer@123", r: "Viewer" },
];

export default function Login() {
  const { login } = useAuth();
  const [username, setU] = useState("admin");
  const [password, setP] = useState("Admin@123");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async (e) => {
    e.preventDefault();
    setBusy(true); setErr("");
    try { await login(username, password); } catch (x) { setErr(x.message); } finally { setBusy(false); }
  };

  return (
    <div className="login-wrap">
      <div className="login-art">
        <div className="logo" style={{ width: 52, height: 52, fontSize: 20 }}>IQ</div>
        <h1>Intelligent Inventory Control<br />&amp; Demand Forecasting</h1>
        <p className="muted">Forecasting, inventory optimization and procurement recommendation, computed inside SQL Server.</p>
        <ul style={{ paddingLeft: 18 }}>
          <li>Window functions and CTEs for demand analytics</li>
          <li>Stored procedures and triggers for business rules and audit</li>
          <li>Partitioned tables, columnstore and covering indexes</li>
        </ul>
      </div>
      <div className="login-form">
        <form className="login-box" onSubmit={submit}>
          <div>
            <h1>Sign in</h1>
            <p className="muted">Use one of the demo accounts below.</p>
          </div>
          <label className="field"><span>Username</span><input value={username} onChange={(e) => setU(e.target.value)} autoFocus /></label>
          <label className="field"><span>Password</span><input type="password" value={password} onChange={(e) => setP(e.target.value)} /></label>
          {err && <div className="errbox">{err}</div>}
          <button className="btn" disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button>
          <div className="demo-accts">
            {DEMO.map((d) => (
              <button type="button" key={d.u} className="btn ghost sm" onClick={() => { setU(d.u); setP(d.p); }}>{d.r}</button>
            ))}
          </div>
        </form>
      </div>
    </div>
  );
}
