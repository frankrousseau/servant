<script setup lang="ts">
import { ref, onMounted } from "vue";
import { useRouter } from "vue-router";
import { useAuthStore } from "../stores/auth";
import { fetchRegistrationEnabled } from "../composables/authConfig";

const auth = useAuthStore();
const router = useRouter();

const username = ref("");
const password = ref("");
const error = ref("");
const loading = ref(false);
const registrationEnabled = ref(true);

onMounted(async () => {
  registrationEnabled.value = await fetchRegistrationEnabled();
});

async function handleLogin() {
  error.value = "";
  loading.value = true;
  try {
    await auth.login(username.value, password.value);
    router.push("/");
  } catch (e: any) {
    error.value = e.message || "Login failed";
  } finally {
    loading.value = false;
  }
}
</script>

<template>
  <div class="auth-page">
    <div class="auth-card">
      <svg class="auth-logo" viewBox="50 2 120 130" width="72" role="img" aria-label="Servant logo" fill="none" stroke="currentColor" stroke-width="3.5" stroke-linejoin="miter" stroke-linecap="square">
        <path d="M 58 76 L 60 10 L 92 26 L 128 26 L 160 10 L 162 76 L 130 98 L 90 98 Z"/>
        <circle cx="88" cy="56" r="15"/>
        <circle cx="132" cy="56" r="15"/>
        <path d="M 104 74 L 116 74 L 110 87 Z"/>
        <path d="M 107 114 L 88 104 L 88 124 Z"/>
        <path d="M 113 114 L 132 104 L 132 124 Z"/>
      </svg>
      <h1>Servant</h1>
      <form @submit.prevent="handleLogin">
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
          <label for="password">Password</label>
          <input
            id="password"
            v-model="password"
            type="password"
            required
            autocomplete="current-password"
          />
        </div>
        <p v-if="error" class="error">{{ error }}</p>
        <button type="submit" :disabled="loading">
          {{ loading ? "Signing in..." : "Sign In" }}
        </button>
      </form>
      <p v-if="registrationEnabled" class="alt-link">
        Don't have an account?
        <router-link to="/register">Register</router-link>
      </p>
    </div>
  </div>
</template>
