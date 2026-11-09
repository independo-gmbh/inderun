import { defineConfig } from "vitest/config";

export default defineConfig({
  optimizeDeps: {
    // Transformers.js ships its own ONNX Runtime WASM assets and must not be pre-bundled.
    exclude: ["@huggingface/transformers"]
  },
  server: {
    // Cross-origin isolation lets onnxruntime-web use WASM threads for on-device execution.
    headers: {
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp"
    },
    proxy: {
      // The proxy serves the Voices lab asset relay at /assets; keep the page-relative path distinct.
      "/api/inderun/assets": {
        target: "http://127.0.0.1:8787",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api\/inderun\/assets/u, "/assets")
      },
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
