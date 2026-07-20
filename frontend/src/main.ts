import { createApp } from 'vue'
import pinia from './stores'
import router from './router'
import App from './App.vue'
import { useAuthStore } from './stores/auth'
import { applyTheme, storedTheme } from './lib/theme'
import { reportClientError, messageOf } from './lib/reportError'
import { vClickKey } from './lib/clickKey'
import '@fontsource/maple-mono/index.css'
import './style.css'

// Paint with the last known theme immediately; /auth/me re-syncs it after.
applyTheme(storedTheme())

const app = createApp(App)
app.use(pinia)
app.use(router)
app.directive('click-key', vClickKey)

// Surface otherwise-silent client failures in the Audit error log. Vue routes
// errors from async event handlers here, so most swallowed rejections land too.
app.config.errorHandler = (err, _instance, info) => {
  console.error(err)
  reportClientError(`vue:${info}`, messageOf(err))
}
window.addEventListener('unhandledrejection', e => {
  reportClientError('unhandledrejection', messageOf(e.reason))
})

// Restore the current user from the persisted token before/while the app mounts
// (token survives reloads, the user object doesn't); see FE-ARCH-2.
useAuthStore(pinia).hydrate()

app.mount('#app')
