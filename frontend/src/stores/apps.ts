import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

import type { AppDef } from '../apps/types'
import type { InstalledApp } from '../types'
import { apiJson } from '../composables/apiClient'
import { enabledBuiltins } from '../apps/registry'
import {
  movePinnedApp,
  pinApp,
  pinnedApps,
  placePinnedApp,
  readSidebarPreference,
  SIDEBAR_PREFERENCE,
  unpinApp,
  unpinnedApps
} from '../lib/sidebarApps'
import { useAuthStore } from './auth'

// Builtin apps merged with the user's git-installed apps. Installed apps are
// loaded at runtime by importing their pre-built ES module from /files (the
// cookie authenticates the request, same as any file).
export const useAppsStore = defineStore('apps', () => {
  const auth = useAuthStore()

  // ----- state -----

  const installed = ref<InstalledApp[]>([])
  const loaded = ref(false)

  // ----- what the sidebar, the palette and AppView read -----

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
  const defs = computed<AppDef[]>(() => [
    ...enabledBuiltins(auth.user?.enabled_apps),
    ...installed.value.map(toDef)
  ])

  function getDef(id: string): AppDef | undefined {
    return defs.value.find(a => a.id === id)
  }

  // ----- the sidebar's pinned apps (lib/sidebarApps.ts) -----

  const sidebarPreference = computed(() =>
    readSidebarPreference(auth.user?.preferences?.[SIDEBAR_PREFERENCE])
  )
  const pinned = computed(() => pinnedApps(defs.value, sidebarPreference.value))
  const unpinned = computed(() =>
    unpinnedApps(defs.value, sidebarPreference.value)
  )

  function setPinned(id: string, pin: boolean) {
    const change = pin ? pinApp : unpinApp
    auth.setPreference(
      SIDEBAR_PREFERENCE,
      change(defs.value, sidebarPreference.value, id)
    )
  }

  function movePinned(id: string, delta: number) {
    auth.setPreference(
      SIDEBAR_PREFERENCE,
      movePinnedApp(defs.value, sidebarPreference.value, id, delta)
    )
  }

  function placePinned(id: string, toIndex: number) {
    auth.setPreference(
      SIDEBAR_PREFERENCE,
      placePinnedApp(defs.value, sidebarPreference.value, id, toIndex)
    )
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
    pinned,
    unpinned,
    setPinned,
    movePinned,
    placePinned,
    load,
    install,
    update,
    uninstall,
    generate,
    modify,
    restore
  }
})
