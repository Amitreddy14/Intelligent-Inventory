import { Routes, Route, Navigate } from "react-router-dom";
import { useAuth } from "./auth";
import Layout from "./components/Layout";
import Login from "./pages/Login";
import Overview from "./pages/Overview";
import Forecast from "./pages/Forecast";
import Inventory from "./pages/Inventory";
import Procurement from "./pages/Procurement";
import Simulation from "./pages/Simulation";
import Showcase from "./pages/Showcase";
import Admin from "./pages/Admin";

export default function App() {
  const { user, can } = useAuth();
  if (!user) return <Login />;
  return (
    <Layout>
      <Routes>
        <Route path="/" element={<Overview />} />
        <Route path="/forecast" element={<Forecast />} />
        <Route path="/inventory" element={<Inventory />} />
        <Route path="/procurement" element={<Procurement />} />
        <Route path="/simulation" element={<Simulation />} />
        <Route path="/sql" element={<Showcase />} />
        <Route path="/admin" element={can("ADMIN") ? <Admin /> : <Navigate to="/" replace />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Layout>
  );
}
