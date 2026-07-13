import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { apiJson } from '../composables/apiClient'
import { enabledBuiltins } from '../apps/registry'
import { useAuthStore } from './auth'
import type { AppDef } from '../apps/types'

export interface InstalledApp {
  id: string
  name: string
  description: string | null
  icon: string | null
  entry_url: string
  repo_url: string
  built_in: boolean
  updated_at: string
}

// Builtin apps merged with the user's git-installed apps. Installed apps are
// loaded at runtime by importing their pre-built ES module from /files (the
// cookie authenticates the request, same as any file).
export const useAppsStore = defineStore('apps', () => {
  const installed = ref<InstalledApp[]>([])
  const loaded = ref(false)

  function toDef(app: InstalledApp): AppDef {
    // updated_at busts the browser's ES-module cache after an app update
    const url = `${app.entry_url}?v=${encodeURIComponent(app.updated_at)}`
    return {
      id: app.id,
      name: app.name,
      icon: app.icon || 'Puzzle',
      builtin: false,
      load: () => import(/* @vite-ignore */ url)
    }
  }

  // Disabled built-ins disappear everywhere defs is consumed: sidebar,
  // command palette, and app mounting (getDef misses). Installed apps were
  // an explicit install, they are always on.
  const auth = useAuthStore()
  const defs = computed<AppDef[]>(() => [
    ...enabledBuiltins(auth.user?.enabled_apps),
    ...installed.value.map(toDef)
  ])

  function getDef(id: string): AppDef | undefined {
    return defs.value.find(a => a.id === id)
  }

  async function load(force = false) {
    if (loaded.value && !force) return
    const res = await apiJson<{ data: InstalledApp[] }>('GET', '/api/apps')
    installed.value = res.data.filter(a => !a.built_in)
    loaded.value = true
  }

  async function install(repoUrl: string) {
    await apiJson('POST', '/api/apps', { body: { repo_url: repoUrl } })
    await load(true)
  }

  async function update(id: string) {
    await apiJson('POST', `/api/apps/${id}/update`)
    await load(true)
  }

  async function uninstall(id: string) {
    await apiJson('DELETE', `/api/apps/${id}`)
    installed.value = installed.value.filter(a => a.id !== id)
  }

  return { installed, loaded, defs, getDef, load, install, update, uninstall }
})
