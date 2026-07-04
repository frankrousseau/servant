import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import path from "path";

// Phoenix dev server address; override with PHOENIX_PORT=4002 npm run dev
const target = `http://localhost:${process.env.PHOENIX_PORT ?? 4001}`;

export default defineConfig({
  plugins: [vue()],
  base: "/",
  build: {
    outDir: path.resolve(__dirname, "../priv/static"),
    emptyOutDir: true,
    rollupOptions: {
      output: {
        // Split the rarely-changing framework core into a cacheable vendor
        // chunk; route-specific deps (e.g. flatpickr) stay with their chunk.
        manualChunks(id) {
          if (/node_modules\/(@?vue|pinia|@vue)\//.test(id)) return "vendor";
        },
      },
    },
  },
  server: {
    proxy: {
      "/api": {
        target,
        changeOrigin: true,
      },
      "/socket": {
        target,
        changeOrigin: true,
        ws: true,
      },
      "/files": {
        target,
        changeOrigin: true,
      },
      "/uploads": {
        target,
        changeOrigin: true,
      },
    },
  },
});
