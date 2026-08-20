import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

/**
 * Phoenix 의 priv/static/app 으로 직접 빌드한다.
 *
 * 개발 서버를 따로 띄우지 않는 이유: 서버가 둘이면 쿠키·CSRF·프록시 설정이
 * 어긋나기 쉽고, 실기기에서 붙을 주소도 둘이 된다.
 * `vite build --watch` 로 파일만 갱신하고 Phoenix 가 전부 서빙한다.
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
    // 소스맵은 개발 모드에서만. 운영 번들에 원본 코드를 노출하지 않는다.
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
