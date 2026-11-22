import { svelte } from "@sveltejs/vite-plugin-svelte";
import { defineConfig } from "vite";

// The app is built into dist/ and served by the agent (src/web.ts); `npm run dev` proxies the API to a local agent.
export default defineConfig({
  plugins: [svelte()],
  // Mermaid (diagrams) is split off and loaded on demand, so its large chunks are expected.
  build: { outDir: "dist", emptyOutDir: true, target: "es2023", sourcemap: false, chunkSizeWarningLimit: 2000 },
  server: { proxy: { "/api": "http://127.0.0.1:8092" }, fs: { allow: [".."] } },
});
