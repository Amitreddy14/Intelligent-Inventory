import { NavLink } from "react-router-dom";
import { useAuth } from "../auth";
import { useSim } from "../sim";
import { Badge } from "./ui";

const NAV = [
  { to: "/", label: "Overview", icon: "◧" },
  { to: "/forecast", label: "Forecast", icon: "∿" },
  { to: "/inventory", label: "Inventory", icon: "▤" },
  { to: "/procurement", label: "Procurement", icon: "⇄" },
  { to: "/simulation", label: "Simulation", icon: "▶" },
  { to: "/sql", label: "SQL Showcase", icon: "‹/›" },
];

export default function Layout({ children }) {
  const { user, logout, can } = useAuth();
  const { simDate } = useSim();
  return (
    <div className="shell">
      <aside className="side">
        <div className="brand">
          <div className="logo">IQ</div>
          <div>
            <div className="brand-t">Inventory IQ</div>
            <div className="brand-s">Forecast · Optimize · Procure</div>
          </div>
        </div>
        <nav>
          {NAV.map((n) => (
            <NavLink key={n.to} to={n.to} end={n.to === "/"} className={({ isActive }) => "nav" + (isActive ? " active" : "")}>
              <span className="ico">{n.icon}</span>{n.label}
            </NavLink>
          ))}
          {can("ADMIN") && (
            <NavLink to="/admin" className={({ isActive }) => "nav" + (isActive ? " active" : "")}>
              <span className="ico">⚙</span>Admin
            </NavLink>
          )}
        </nav>
        <div className="side-foot">
          <div className="who">
            <div className="avatar">{(user.full_name || user.username).slice(0, 1).toUpperCase()}</div>
            <div>
              <div className="who-n">{user.full_name || user.username}</div>
              <Badge>{user.role}</Badge>
            </div>
          </div>
          <button className="btn ghost sm full" onClick={logout}>Sign out</button>
        </div>
      </aside>
      <div className="main">
        <header className="topbar">
          <div className="muted small">Simulated date</div>
          <div className="simdate">{simDate ? String(simDate).slice(0, 10) : "…"}</div>
          <div className="spacer" />
          <span className="pill"><span className="live" /> SQL Server · InventoryDB</span>
        </header>
        <main className="content">{children}</main>
      </div>
    </div>
  );
}
