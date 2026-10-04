import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

import type { AppDef } from '../apps/types'
import type { InstalledApp } from '../types'
import { apiJson } from '../composables/apiClient'
import { enabledBuiltins } from '../apps/registry'
import { useAuthStore } from './auth'

// The builtin apps, merged with the git-installed apps of the user. An
// installed app loads at runtime: the store imports its pre-built ES module
// from /files. The cookie authenticates the request, as for all files.
export const useAppsStore = defineStore('apps', () => {
  const auth = useAuthStore()

  // ----- state -----

  const installed = ref<InstalledApp[]>([])
  const loaded = ref(false)

  // ----- what the sidebar, the palette and AppView read -----

  function toDef(app: InstalledApp): AppDef {
    // updated_at invalidates the ES-module cache of the browser after an app
    // update.
    const url = `${app.entry_url}?v=${encodeURIComponent(app.updated_at)}`
    return {
      id: app.id,
      name: app.name,
      icon: app.icon || 'Puzzle',
      builtin: false,
      load: () => import(/* @vite-ignore */ url)
    }
  }

  // The disabled built-ins go away from all the consumers of defs: the
  // sidebar, the command palette, and the mount of apps (getDef finds
  // nothing). The user installed the installed apps explicitly, so they are
  // always on.
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

  // ----- installing from git -----

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

  // ----- the builder (an app written by the model) -----

  async function generate(name: string, description: string) {
    const res = await apiJson<{ data: { id: string } }>(
      'POST',
      '/api/apps/generate',
      { body: { name, description } }
    )
    return res.data.id
  }

  async function modify(id: string, instruction: string) {
    const res = await apiJson<{ data: { id: string } }>(
      'POST',
      `/api/apps/${id}/modify`,
      { body: { instruction } }
    )
    return res.data.id
  }

  async function restore(id: string) {
    await apiJson('POST', `/api/apps/${id}/restore`)
    await load(true)
  }

  return {
    installed,
    loaded,
    defs,
    getDef,
    load,
    install,
    update,
    uninstall,
    generate,
    modify,
    restore
  }
})
