import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import type { User } from '../types'
import { apiErrorMessage } from '../composables/apiClient'

// Only a non-sensitive "are we logged in?" flag is persisted. The actual auth
// token lives in an HttpOnly cookie (unreadable by JS) plus an in-memory copy
// used to open the realtime socket, never in localStorage (FE-SEC-3).
const LOGGED_IN_KEY = 'servant_logged_in'

export const useAuthStore = defineStore('auth', () => {
  // Drop any token left by the pre-cookie version.
  localStorage.removeItem('auth_token')

  const token = ref<string | null>(null)
  const user = ref<User | null>(null)
  const loggedIn = ref(localStorage.getItem(LOGGED_IN_KEY) === '1')

  const isAuthenticated = computed(() => loggedIn.value || !!user.value)

  function setAuth(newToken: string, newUser: User) {
    token.value = newToken
    user.value = newUser
    loggedIn.value = true
    localStorage.setItem(LOGGED_IN_KEY, '1')
  }

  function clearAuth() {
    token.value = null
    user.value = null
    loggedIn.value = false
    localStorage.removeItem(LOGGED_IN_KEY)
  }

  async function login(username: string, password: string) {
    const res = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password })
    })

    if (!res.ok) {
      const err = await res.json().catch(() => ({}))
      throw new Error(apiErrorMessage(err) || 'Login failed')
    }

    const data = await res.json()
    setAuth(data.token, data.user)
  }

  async function register(
    username: string,
    password: string,
    display_name: string
  ) {
    const res = await fetch('/api/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password, display_name })
    })

    if (!res.ok) {
      const err = await res.json().catch(() => ({}))
      // Uses the shared parser so changeset-style {errors:{field:[...]}} bodies
      // surface the real field message instead of a generic "Registration failed".
      throw new Error(apiErrorMessage(err) || 'Registration failed')
    }

    const data = await res.json()
    setAuth(data.token, data.user)
  }

  function logout() {
    // Clear the HttpOnly cookie server-side, then local state.
    fetch('/api/auth/logout', { method: 'POST' }).catch(() => {})
    clearAuth()
  }

  // On boot, if the flag says we were logged in, confirm via /auth/me; the
  // HttpOnly cookie authenticates the request. Populates the user and an
  // in-memory token (for the socket); clears state if the cookie is gone/expired.
  async function hydrate() {
    if (user.value || !loggedIn.value) return

    try {
      const res = await fetch('/api/auth/me')
      if (res.ok) {
        const body = await res.json()
        user.value = body.data
        token.value = body.token ?? null
      } else if (res.status === 401) {
        clearAuth()
      }
    } catch {
      // Network error: keep the flag and retry on the next boot.
    }
  }

  return { token, user, isAuthenticated, login, register, logout, hydrate }
})
