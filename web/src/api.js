// Small fetch wrapper. The token lives in localStorage; a 401 logs the user out.
const KEY = "inv_token";
const USER = "inv_user";

export const token = {
  get: () => { try { return localStorage.getItem(KEY); } catch { return null; } },
  set: (t) => { try { localStorage.setItem(KEY, t); } catch { /* ignore */ } },
  clear: () => { try { localStorage.removeItem(KEY); localStorage.removeItem(USER); } catch { /* ignore */ } },
};
export const savedUser = () => { try { return JSON.parse(localStorage.getItem(USER)); } catch { return null; } };
export const saveUser = (u) => { try { localStorage.setItem(USER, JSON.stringify(u)); } catch { /* ignore */ } };

let onUnauthorized = () => {};
export const setUnauthorizedHandler = (fn) => { onUnauthorized = fn; };

function qs(params) {
  const p = new URLSearchParams();
  Object.entries(params || {}).forEach(([k, v]) => {
    if (v !== undefined && v !== null && v !== "") p.append(k, v);
  });
  const s = p.toString();
  return s ? "?" + s : "";
}

async function request(method, path, { params, body, form } = {}) {
  const headers = {};
  const t = token.get();
  if (t) headers.Authorization = "Bearer " + t;
  let payload;
  if (form) {
    headers["Content-Type"] = "application/x-www-form-urlencoded";
    payload = new URLSearchParams(form).toString();
  } else if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    payload = JSON.stringify(body);
  }
  let res;
  try {
    res = await fetch("/api" + path + qs(params), { method, headers, body: payload });
  } catch {
    throw new Error("Cannot reach the API. Is the backend running?");
  }
  if (res.status === 401 && path !== "/auth/login") {
    token.clear();
    onUnauthorized();
    throw new Error("Session expired. Please sign in again.");
  }
  let data = null;
  try { data = await res.json(); } catch { /* empty body */ }
  if (!res.ok) {
    let msg = data && data.detail;
    if (Array.isArray(msg)) msg = msg.map((e) => (e.loc ? e.loc.slice(1).join(".") + ": " : "") + e.msg).join("; ");
    throw new Error(msg || "Request failed (" + res.status + ")");
  }
  return data;
}

export const api = {
  get: (path, params) => request("GET", path, { params }),
  post: (path, body) => request("POST", path, { body: body ?? {} }),
  patch: (path, body) => request("PATCH", path, { body }),
  login: (username, password) => request("POST", "/auth/login", { form: { username, password } }),
};
