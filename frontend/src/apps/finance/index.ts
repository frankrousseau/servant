import { createApp, type App } from 'vue'
import type { AppModule } from '../types'
import FinanceApp from './FinanceApp.vue'

// Thin adapter: keep the AppModule contract but render a real Vue component.
let instance: App | null = null

const financeApp: AppModule = {
  mount(el, ctx) {
    instance = createApp(FinanceApp, { ctx })
    instance.mount(el)
  },
  unmount() {
    instance?.unmount()
    instance = null
  }
}

export default financeApp
