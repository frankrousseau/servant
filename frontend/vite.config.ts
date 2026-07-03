import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import path from "path";

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
        target: "http://localhost:4000",
        changeOrigin: true,
      },
      "/socket": {
        target: "http://localhost:4000",
        changeOrigin: true,
        ws: true,
      },
      "/files": {
        target: "http://localhost:4000",
        changeOrigin: true,
      },
      "/uploads": {
        target: "http://localhost:4000",
        changeOrigin: true,
      },
    },
  },
});
