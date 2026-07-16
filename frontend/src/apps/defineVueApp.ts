import { createApp, type App, type Component } from 'vue'
import type { AppModule } from './types'

// Every built-in app is the same thin adapter: mount a Vue component with the
// AppContext as a prop, unmount on teardown. Collapses the eight identical
// index.ts files into one line each.
export function defineVueApp(component: Component): AppModule {
  let instance: App | null = null
  return {
    mount(el, ctx) {
      instance = createApp(component, { ctx })
      instance.mount(el)
    },
    unmount() {
      instance?.unmount()
      instance = null
    }
  }
}
