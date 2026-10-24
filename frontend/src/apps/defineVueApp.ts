import { createApp, type App, type Component } from 'vue'
import { vAutofocus } from '../lib/autofocus'
import { vClickKey } from '../lib/clickKey'
import type { AppModule } from './types'

// Every built-in app is the same thin adapter: mount a Vue component with the
// AppContext as a prop, unmount on teardown. Collapses the eight identical
// index.ts files into one line each.
//
// Each app is a Vue instance of its own, so it does not inherit what main.ts
// registers on the shell: the global directives are registered again here,
// or v-autofocus and v-click-key silently do nothing inside an app.
export function defineVueApp(component: Component): AppModule {
  let instance: App | null = null
  return {
    mount(el, ctx) {
      instance = createApp(component, { ctx })
      instance.directive('autofocus', vAutofocus)
      instance.directive('click-key', vClickKey)
      instance.mount(el)
    },
    unmount() {
      instance?.unmount()
      instance = null
    }
  }
}
