import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The Go binary embeds the build output from internal/web/dist, so Vite emits
// there. During dev, /api and /healthz proxy to the local backend on :8080.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "../internal/web/dist",
    emptyOutDir: true,
  },
  server: {
    proxy: {
      "/api": "http://localhost:8080",
      "/healthz": "http://localhost:8080",
    },
  },
});
