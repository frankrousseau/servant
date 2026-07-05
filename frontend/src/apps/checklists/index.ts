import { createApp, type App } from 'vue'
import type { AppModule } from '../types'
import ChecklistsApp from './ChecklistsApp.vue'

// Thin adapter: keep the AppModule contract but render a real Vue component.
let instance: App | null = null

const checklistsApp: AppModule = {
  mount(el, ctx) {
    instance = createApp(ChecklistsApp, { ctx })
    instance.mount(el)
  },
  unmount() {
    instance?.unmount()
    instance = null
  }
}

export default checklistsApp
