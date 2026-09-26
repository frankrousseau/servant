import { ref, computed } from 'vue'
import { defineStore } from 'pinia'

import type { User } from '../types'
import * as authApi from '../api/auth'
import type { Session } from '../api/auth'
import { applyTheme } from '../lib/theme'
import { messageOf, reportClientError } from '../lib/reportError'

// Only a non-sensitive "are we logged in?" flag is persisted. The actual auth
// token lives in an HttpOnly cookie (unreadable by JS) plus an in-memory copy
// used to open the realtime socket, never in localStorage.
const LOGGED_IN_KEY = 'servant_logged_in'

export const useAuthStore = defineStore('auth', () => {
  // Drop any token left by the pre-cookie version.
  localStorage.removeItem('auth_token')

  // ----- state -----

  const token = ref<string | null>(null)
  const user = ref<User | null>(null)
  const loggedIn = ref(localStorage.getItem(LOGGED_IN_KEY) === '1')

  const isAuthenticated = computed(() => loggedIn.value || !!user.value)

  function setAuth(session: Session) {
    token.value = session.token
    user.value = session.user
    loggedIn.value = true
    localStorage.setItem(LOGGED_IN_KEY, '1')
    if (session.user.theme) applyTheme(session.user.theme)
    // The login/register answer carries a partial user; /auth/me completes it
    // (preferences, enabled apps, formats) without waiting for a reload.
    authApi
      .fetchMe()
      .then(me => {
        if (me) user.value = me.user
      })
      .catch(() => {})
  }

  function clearAuth() {
    token.value = null
    user.value = null
    loggedIn.value = false
    localStorage.removeItem(LOGGED_IN_KEY)
  }

  // ----- entering a session -----

  // Resolves to a pending-TOTP marker when the account has 2FA: the caller
  // must then call verifyTotp with the short-lived ticket and a code.
  async function login(
    username: string,
    password: string
  ): Promise<{ requiresTotp: boolean; ticket?: string }> {
    const data = await authApi.login(username, password)

    if ('requires_totp' in data) {
      return { requiresTotp: true, ticket: data.ticket }
    }
    setAuth(data)
    return { requiresTotp: false }
  }

  async function verifyTotp(ticket: string, code: string) {
    setAuth(await authApi.verifyTotp(ticket, code))
  }

  async function register(
    username: string,
    password: string,
    display_name: string
  ) {
    setAuth(await authApi.register(username, password, display_name))
  }

  function logout() {
    authApi.logout()
    clearAuth()
  }

  // ----- preferences -----

  // Applied locally at once, then saved one key at a time. Saves are chained
  // so two quick changes reach the server in order and never overtake.
  let preferenceSaves = Promise.resolve()

  function setPreference(key: string, value: unknown) {
    if (!user.value) return
    user.value.preferences = { ...user.value.preferences, [key]: value }
    preferenceSaves = preferenceSaves
      .then(() => authApi.updateProfile({ preferences: { [key]: value } }))
      .then(() => {})
      .catch(err => reportClientError('preferences', messageOf(err)))
  }

  // ----- boot -----

  // On boot, if the flag says we were logged in, confirm via /auth/me; the
  // HttpOnly cookie authenticates the request. Populates the user and an
  // in-memory token (for the socket); clears state if the cookie is gone/expired.
  async function hydrate() {
    if (user.value || !loggedIn.value) return

    try {
      const session = await authApi.fetchMe()
      if (!session) {
        clearAuth()
        return
      }
      user.value = session.user
      token.value = session.token
      if (session.user.theme) applyTheme(session.user.theme)
    } catch {
      // Network error: keep the flag and retry on the next boot.
    }
  }

  return {
    token,
    user,
    isAuthenticated,
    login,
    verifyTotp,
    register,
    logout,
    setPreference,
    hydrate
  }
})
