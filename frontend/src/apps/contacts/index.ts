import { createApp, type App } from 'vue'
import type { AppModule } from '../types'
import ContactsApp from './ContactsApp.vue'

// Thin adapter: keep the AppModule contract but render a real Vue component.
let instance: App | null = null

const contactApp: AppModule = {
  mount(el, ctx) {
    instance = createApp(ContactsApp, { ctx })
    instance.mount(el)
  },
  unmount() {
    instance?.unmount()
    instance = null
  }
}

export default contactApp
