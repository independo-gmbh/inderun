import { defineConfig } from "vite";

export default defineConfig({
  server: {
    proxy: {
      "/api/inderun": {
        target: "http://127.0.0.1:8787",
        changeOrigin: true
      }
    }
  },
  test: {
    environment: "happy-dom",
    include: ["src/**/*.test.ts"]
  }
});
