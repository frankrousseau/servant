import { createApp, type App } from 'vue'
import type { AppModule } from '../types'
import TrackersApp from './TrackersApp.vue'

// Thin adapter: keep the AppModule contract but render a real Vue component.
let instance: App | null = null

const trackersApp: AppModule = {
  mount(el, ctx) {
    instance = createApp(TrackersApp, { ctx })
    instance.mount(el)
  },
  unmount() {
    instance?.unmount()
    instance = null
  }
}

export default trackersApp
