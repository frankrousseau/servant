<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'

import { enableBankingExchange } from '../api/connectors'

const route = useRoute()
const router = useRouter()

const error = ref('')

// The bank redirected here after the consent screen: ?code on success
// (?error if not), and ?state, which carries the id of the connector config.
onMounted(async () => {
  const code = route.query.code as string | undefined
  const configId = route.query.state as string | undefined

  if (route.query.error) {
    error.value =
      (route.query.error_description as string) ||
      `Bank authorization failed (${route.query.error})`
    return
  }
  if (!code || !configId) {
    error.value = 'Missing authorization code in the bank redirect.'
    return
  }

  try {
    await enableBankingExchange(configId, code)
    await router.replace(`/connectors/${configId}`)
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Bank connection failed.'
  }
})
</script>

<template>
  <div class="view">
    <h1>Bank connection</h1>
    <p v-if="!error" class="eb-status">Finalizing the bank connection…</p>
    <template v-else>
      <p class="eb-error">{{ error }}</p>
      <router-link to="/connectors">Back to connectors</router-link>
    </template>
  </div>
</template>

<style scoped>
.eb-status {
  color: var(--text-muted);
}
.eb-error {
  color: var(--danger);
  margin-bottom: 1rem;
}
</style>
