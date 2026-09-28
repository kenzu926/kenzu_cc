import path from "node:path";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const root = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [react()],
  resolve: { alias: { "@": path.resolve(root) } },
  server: {
    host: "0.0.0.0",
    port: 5173,
    proxy: {
      "/snapshot": "http://127.0.0.1:3000",
      "/command": "http://127.0.0.1:3000",
      "/terminal": "http://127.0.0.1:3000",
      "/health": "http://127.0.0.1:3000",
    },
  },
});
