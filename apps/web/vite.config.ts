import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

/**
 * Builds straight into Phoenix's priv/static/app.
 *
 * Why no separate dev server: with two servers, cookie/CSRF/proxy settings
 * drift apart easily, and real devices would have two addresses to hit.
 * `vite build --watch` only refreshes files; Phoenix serves everything.
 */
export default defineConfig({
  plugins: [react()],
  base: "/app/",
  resolve: {
    alias: {
      "@core": resolve(import.meta.dirname, "../../packages/core/src"),
      "@": resolve(import.meta.dirname, "src"),
    },
  },
  build: {
    outDir: resolve(import.meta.dirname, "../../backend/priv/static/app"),
    emptyOutDir: true,
    // Source maps in dev mode only. Don't expose the original code in the production bundle.
    sourcemap: process.env.NODE_ENV !== "production",
    rollupOptions: {
      output: {
        entryFileNames: "assets/[name]-[hash].js",
        chunkFileNames: "assets/[name]-[hash].js",
        assetFileNames: "assets/[name]-[hash][extname]",
      },
    },
  },
});
