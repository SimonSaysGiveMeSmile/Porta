import { defineConfig } from "vite";

export default defineConfig({
  server: {
    port: 5173,
    proxy: {
      "/v1": "http://localhost:8080",
    },
  },
  build: {
    target: "es2022",
    outDir: "dist",
  },
});
