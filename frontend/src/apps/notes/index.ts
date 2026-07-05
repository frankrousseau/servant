import { createApp, type App } from 'vue'
import type { AppModule } from '../types'
import NotesApp from './NotesApp.vue'

// Thin adapter: keep the AppModule contract but render a real Vue component.
let instance: App | null = null

const notesApp: AppModule = {
  mount(el, ctx) {
    instance = createApp(NotesApp, { ctx })
    instance.mount(el)
  },
  unmount() {
    instance?.unmount()
    instance = null
  }
}

export default notesApp
