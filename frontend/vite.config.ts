import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import path from 'path'
import { execSync } from 'node:child_process'

// Phoenix dev server address; override with PHOENIX_PORT=4002 npm run dev
const target = `http://localhost:${process.env.PHOENIX_PORT ?? 4001}`

// Baked into the bundle so prod can tell which commit it runs (Settings).
function gitCommit(): string {
  try {
    return execSync('git rev-parse --short HEAD').toString().trim()
  } catch {
    return 'unknown'
  }
}

export default defineConfig({
  plugins: [vue()],
  define: {
    __BUILD_COMMIT__: JSON.stringify(gitCommit()),
    __BUILD_DATE__: JSON.stringify(new Date().toISOString().slice(0, 10))
  },
  base: '/',
  build: {
    outDir: path.resolve(__dirname, '../priv/static'),
    emptyOutDir: true,
    rollupOptions: {
      output: {
        // Split the rarely-changing framework core into a cacheable vendor
        // chunk; route-specific deps (e.g. flatpickr) stay with their chunk.
        manualChunks(id) {
          if (/node_modules\/(@?vue|pinia|@vue)\//.test(id)) return 'vendor'
        }
      }
    }
  },
  server: {
    port: 5001,
    proxy: {
      '/api': {
        target,
        changeOrigin: true
      },
      '/socket': {
        target,
        changeOrigin: true,
        ws: true
      },
      '/files': {
        target,
        changeOrigin: true
      },
      '/uploads': {
        target,
        changeOrigin: true
      }
    }
  }
})
