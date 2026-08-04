<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'

import { fetchRegistrationEnabled } from '../composables/authConfig'
import { useAuthStore } from '../stores/auth'

const auth = useAuthStore()
const router = useRouter()

// Closed instance (REGISTRATION_ENABLED=false): this page has no reason to
// exist, so bounce to sign-in. The server refuses the POST regardless.
onMounted(async () => {
  if (!(await fetchRegistrationEnabled())) router.replace('/login')
})

const username = ref('')
const password = ref('')
const displayName = ref('')
const error = ref('')
const loading = ref(false)

async function handleRegister() {
  error.value = ''
  loading.value = true
  try {
    await auth.register(username.value, password.value, displayName.value)
    router.push('/')
  } catch (err: any) {
    error.value = err.message || 'Registration failed'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="auth-page">
    <div class="auth-card">
      <svg
        class="auth-logo"
        viewBox="50 2 120 130"
        width="72"
        role="img"
        aria-label="Servant logo"
        fill="none"
        stroke="currentColor"
        stroke-width="3.5"
        stroke-linejoin="miter"
        stroke-linecap="square"
      >
        <path
          d="M 58 76 L 60 10 L 92 26 L 128 26 L 160 10 L 162 76 L 130 98 L 90 98 Z"
        />
        <circle cx="88" cy="56" r="15" />
        <circle cx="132" cy="56" r="15" />
        <path d="M 104 74 L 116 74 L 110 87 Z" />
        <path d="M 107 114 L 88 104 L 88 124 Z" />
        <path d="M 113 114 L 132 104 L 132 124 Z" />
      </svg>
      <h1>Servant</h1>
      <form @submit.prevent="handleRegister">
        <div class="field">
          <label for="username">Username</label>
          <input
            id="username"
            v-model="username"
            type="text"
            required
            autocomplete="username"
          />
        </div>
        <div class="field">
          <label for="display-name">Display Name</label>
          <input id="display-name" v-model="displayName" type="text" required />
        </div>
        <div class="field">
          <label for="password">Password</label>
          <input
            id="password"
            v-model="password"
            type="password"
            required
            autocomplete="new-password"
          />
        </div>
        <p v-if="error" class="error">{{ error }}</p>
        <button type="submit" :disabled="loading">
          {{ loading ? 'Creating account...' : 'Register' }}
        </button>
      </form>
      <p class="alt-link">
        Already have an account?
        <router-link to="/login">Sign in</router-link>
      </p>
    </div>
  </div>
</template>
