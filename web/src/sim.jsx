import { createContext, useContext, useEffect, useState, useCallback } from "react";
import { api } from "./api";
import { useAuth } from "./auth";

const SimCtx = createContext({ simDate: null, version: 0, bump: () => {} });
export const useSim = () => useContext(SimCtx);

// Holds the simulated "today" and a version counter. Pages refetch when `version` changes,
// so advancing the clock or approving an order refreshes every screen.
export function SimProvider({ children }) {
  const { user } = useAuth();
  const [simDate, setSimDate] = useState(null);
  const [version, setVersion] = useState(0);

  const refresh = useCallback(() => {
    if (!user) return;
    api.get("/simulation/state").then((s) => setSimDate(s.sim_date)).catch(() => {});
  }, [user]);

  useEffect(() => { refresh(); }, [refresh, version]);

  const bump = useCallback(() => setVersion((v) => v + 1), []);

  return <SimCtx.Provider value={{ simDate, version, bump }}>{children}</SimCtx.Provider>;
}
