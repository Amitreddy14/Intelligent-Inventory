import { createContext, useContext, useEffect, useState, useCallback } from "react";
import { api, token, savedUser, saveUser, setUnauthorizedHandler } from "./api";

const AuthCtx = createContext(null);
export const useAuth = () => useContext(AuthCtx);

const RANK = { VIEWER: 1, MANAGER: 2, ADMIN: 3 };

export function AuthProvider({ children }) {
  const [user, setUser] = useState(token.get() ? savedUser() : null);

  const logout = useCallback(() => { token.clear(); setUser(null); }, []);

  useEffect(() => { setUnauthorizedHandler(logout); }, [logout]);

  // Validate a stored token once on start
  useEffect(() => {
    if (!token.get()) return;
    api.get("/auth/me").then((u) => { setUser(u); saveUser(u); }).catch(() => {});
  }, []);

  const login = async (username, password) => {
    const res = await api.login(username, password);
    token.set(res.access_token);
    saveUser(res.user);
    setUser(res.user);
  };

  const can = (role) => !!user && RANK[user.role] >= RANK[role];

  return <AuthCtx.Provider value={{ user, login, logout, can }}>{children}</AuthCtx.Provider>;
}
