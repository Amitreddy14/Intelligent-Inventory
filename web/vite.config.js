import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev server: `npm run dev` on http://localhost:5173, forwarding /api to the FastAPI container.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: { "/api": { target: "http://localhost:8000", changeOrigin: true } },
  },
});
