import { createApp, type App } from 'vue'
import type { AppModule } from '../types'
import PhotosApp from './PhotosApp.vue'

// Thin adapter: keep the AppModule contract but render a real Vue component.
let instance: App | null = null

const photosApp: AppModule = {
  mount(el, ctx) {
    instance = createApp(PhotosApp, { ctx })
    instance.mount(el)
  },
  unmount() {
    instance?.unmount()
    instance = null
  }
}

export default photosApp
