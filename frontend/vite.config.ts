import { defineConfig, type Plugin } from 'vite'
import vue from '@vitejs/plugin-vue'
import path from 'path'
import { copyFileSync, mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
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

// /api/docs is served by Phoenix from priv/static/swagger, not by the SPA, so
// the assets are copied out of swagger-ui-dist here: the docs page then works
// on an instance with no internet access (it used to pull them from a CDN).
function swaggerAssets(): Plugin {
  const files = [
    'swagger-ui.css',
    'swagger-ui-bundle.js',
    'swagger-ui-standalone-preset.js'
  ]
  return {
    name: 'servant-swagger-assets',
    apply: 'build',
    closeBundle() {
      const require = createRequire(import.meta.url)
      const src = path.dirname(require.resolve('swagger-ui-dist/package.json'))
      const dest = path.resolve(import.meta.dirname, '../priv/static/swagger')
      mkdirSync(dest, { recursive: true })
      for (const f of files) {
        copyFileSync(path.join(src, f), path.join(dest, f))
      }
    }
  }
}

export default defineConfig({
  plugins: [vue(), swaggerAssets()],
  define: {
    __BUILD_COMMIT__: JSON.stringify(gitCommit()),
    __BUILD_DATE__: JSON.stringify(new Date().toISOString().slice(0, 10))
  },
  base: '/',
  build: {
    outDir: path.resolve(import.meta.dirname, '../priv/static'),
    emptyOutDir: true,
    // face-api (~1.3 MB) is one indivisible library, already loaded on demand
    // by the face scan; the limit sits just above it so any other chunk that
    // grows past it still warns.
    chunkSizeWarningLimit: 1400,
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
