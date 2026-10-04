import { createApp } from 'vue'

import pinia from './stores'
import router from './router'
import App from './App.vue'

import { useAuthStore } from './stores/auth'
import { applyTheme, storedTheme } from './lib/theme'
import { vAutofocus } from './lib/autofocus'
import { reportClientError, messageOf } from './lib/reportError'
import { vClickKey } from './lib/clickKey'

import '@fontsource/maple-mono/index.css'
import './style.css'

// Paint immediately with the last known theme. Then /auth/me syncs it again.
applyTheme(storedTheme())

const app = createApp(App)
app.use(pinia)
app.use(router)
app.directive('click-key', vClickKey)
app.directive('autofocus', vAutofocus)

// Send to the Audit error log the client failures that would stay silent.
app.config.errorHandler = (err, _instance, info) => {
  console.error(err)
  reportClientError(`vue:${info}`, messageOf(err))
}
window.addEventListener('unhandledrejection', e => {
  reportClientError('unhandledrejection', messageOf(e.reason))
})

// Restore the current user from the persisted token before the app mounts, or
// while it mounts.
useAuthStore(pinia).hydrate()

app.mount('#app')
