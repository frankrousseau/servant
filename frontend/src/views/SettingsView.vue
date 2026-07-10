<script setup lang="ts">
import { ref, onMounted } from 'vue'
import ComboBox from '../components/ComboBox.vue'
import { useAuthStore } from '../stores/auth'
import { useApi } from '../composables/useApi'
import { formatDate } from '../lib/datetime'
import { useConfirm } from '../composables/useConfirm'
import { Download, TerminalSquare, Copy, Trash2 } from 'lucide-vue-next'
import type { ApiToken } from '../types'
import {
  SCOPE_DOMAINS,
  buildScopes,
  type AccessLevel
} from '../lib/apiTokenScopes'

const auth = useAuthStore()
const api = useApi()
const { ask } = useConfirm()

// API tokens
const apiTokens = ref<ApiToken[]>([])
const tokenName = ref('')
const tokenExpiry = ref('') // yyyy-mm-dd from <input type="date">, optional
const tokenLevels = ref<Record<string, AccessLevel>>({})
const tokenReadBinary = ref(false)
const createdToken = ref<string | null>(null)
const tokenError = ref('')
const tokenCreating = ref(false)

const ACCESS_OPTIONS = [
  { value: 'none', label: 'No access' },
  { value: 'read', label: 'Read' },
  { value: 'write', label: 'Read + write' }
]

async function loadTokens() {
  try {
    apiTokens.value = (await api.get<{ data: ApiToken[] }>('/api/tokens')).data
  } catch {
    // section shows empty; not fatal for the rest of settings
  }
}

async function createToken() {
  tokenError.value = ''
  const scopes = buildScopes(tokenLevels.value, tokenReadBinary.value)
  if (!tokenName.value.trim() || !scopes.length) {
    tokenError.value = 'Name and at least one scope are required'
    return
  }
  tokenCreating.value = true
  try {
    const body: Record<string, unknown> = {
      name: tokenName.value.trim(),
      scopes
    }
    if (tokenExpiry.value) body.expires_at = `${tokenExpiry.value}T23:59:59Z`
    const res = await api.post<{ data: ApiToken }>('/api/tokens', body)
    createdToken.value = res.data.token ?? null
    tokenName.value = ''
    tokenExpiry.value = ''
    tokenLevels.value = {}
    tokenReadBinary.value = false
    await loadTokens()
  } catch (e) {
    tokenError.value = e instanceof Error ? e.message : 'Creation failed'
  } finally {
    tokenCreating.value = false
  }
}

async function revokeToken(t: ApiToken) {
  const ok = await ask({
    title: 'Revoke token',
    message: `Revoke "${t.name}"? Scripts using it will stop working.`
  })
  if (!ok) return
  await api.del(`/api/tokens/${t.id}`)
  await loadTokens()
}

async function copyCreatedToken() {
  if (createdToken.value)
    await navigator.clipboard.writeText(createdToken.value)
}

// Export
const exportingEntries = ref(false)

async function downloadFile(
  url: string,
  fallbackName: string,
  loadingRef: typeof exportingEntries
) {
  loadingRef.value = true
  try {
    const res = await fetch(url, {
      headers: auth.token ? { Authorization: `Bearer ${auth.token}` } : {}
    })
    if (!res.ok) throw new Error('Download failed')
    const blob = await res.blob()
    const blobUrl = URL.createObjectURL(blob)
    const a = document.createElement('a')
    const disposition = res.headers.get('content-disposition') || ''
    const match = disposition.match(/filename="(.+)"/)
    a.href = blobUrl
    a.download = match?.[1] || fallbackName
    a.click()
    URL.revokeObjectURL(blobUrl)
  } catch (e: any) {
    alert(e.message || 'Failed to download')
  } finally {
    loadingRef.value = false
  }
}

function downloadEntries() {
  downloadFile('/api/export/entries', 'servant_entries.json', exportingEntries)
}

onMounted(loadTokens)
</script>

<template>
  <div class="view">
    <h1>Settings</h1>

    <!-- API Tokens -->
    <section class="card">
      <div class="card-header">
        <TerminalSquare :size="20" class="card-icon" />
        <h2>API Tokens</h2>
      </div>
      <div class="card-body">
        <p class="tk-hint">
          Scoped tokens let agents and scripts use the API with limited
          permissions. Send them as "Authorization: Bearer &lt;token&gt;". Docs:
          <a href="/api/docs" target="_blank" rel="noopener">/api/docs</a>
        </p>

        <div v-if="createdToken" class="tk-created">
          <p class="tk-created-warning">
            Copy this token now: it will not be shown again.
          </p>
          <code class="tk-created-value">{{ createdToken }}</code>
          <div class="card-actions">
            <button type="button" @click="copyCreatedToken">
              <Copy :size="14" /> Copy
            </button>
            <button type="button" @click="createdToken = null">Done</button>
          </div>
        </div>

        <table v-if="apiTokens.length" class="tk-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Scopes</th>
              <th>Last used</th>
              <th>Expires</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="t in apiTokens" :key="t.id">
              <td>
                {{ t.name }} <span class="tk-prefix">{{ t.prefix }}…</span>
              </td>
              <td>
                <span v-for="s in t.scopes" :key="s" class="tk-scope">{{
                  s
                }}</span>
              </td>
              <td>
                {{ t.last_used_at ? formatDate(t.last_used_at) : 'never' }}
              </td>
              <td>{{ t.expires_at ? formatDate(t.expires_at) : '-' }}</td>
              <td>
                <button
                  type="button"
                  class="tk-revoke"
                  title="Revoke"
                  @click="revokeToken(t)"
                >
                  <Trash2 :size="14" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <p v-else class="tk-empty">No API tokens yet.</p>

        <form class="tk-form" @submit.prevent="createToken">
          <input
            v-model="tokenName"
            type="text"
            placeholder="Token name (e.g. tracker bot)"
          />
          <div class="tk-domains">
            <div v-for="d in SCOPE_DOMAINS" :key="d.id" class="tk-domain">
              <span class="tk-domain-label">{{ d.label }}</span>
              <ComboBox
                class="tk-domain-select"
                :model-value="tokenLevels[d.id] ?? 'none'"
                :options="ACCESS_OPTIONS"
                @update:model-value="
                  v => (tokenLevels[d.id] = v as AccessLevel)
                "
              />
            </div>
          </div>
          <label class="tk-binary">
            <span class="tk-domain-label">
              Download file contents (/files) - never implied by read/write
            </span>
            <span class="tk-binary-box">
              <input v-model="tokenReadBinary" type="checkbox" />
            </span>
          </label>
          <label class="tk-expiry">
            <span class="tk-domain-label">Expires (optional)</span>
            <input v-model="tokenExpiry" type="date" />
          </label>
          <p v-if="tokenError" class="msg msg-error">{{ tokenError }}</p>
          <div class="card-actions">
            <button type="submit" :disabled="tokenCreating">
              {{ tokenCreating ? 'Creating...' : 'Create token' }}
            </button>
          </div>
        </form>
      </div>
    </section>

    <!-- Export -->
    <section class="card">
      <div class="card-header">
        <Download :size="20" class="card-icon" />
        <h2>Export</h2>
      </div>

      <div class="card-body">
        <p class="export-desc">Download your data for backup or migration.</p>
        <div class="card-actions export-actions">
          <button @click="downloadEntries" :disabled="exportingEntries">
            {{ exportingEntries ? 'Downloading...' : 'Entries (JSON)' }}
          </button>
        </div>
      </div>
    </section>
  </div>
</template>

<style scoped>
.card {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  margin-bottom: 1rem;
  overflow: hidden;
}

.card-header {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  padding: 1rem 1.25rem;
  border-bottom: 1px solid var(--border);
}

.card-header h2 {
  margin: 0;
  font-size: 1.1rem;
}

.card-icon {
  color: var(--text-muted);
  flex-shrink: 0;
}

.card-body {
  padding: 1.25rem;
}

.card-actions {
  padding-top: 0.5rem;
}

/* Messages */
.msg {
  font-size: 0.9rem;
  margin-bottom: 0.5rem;
  padding: 0.4rem 0.6rem;
  border-radius: var(--radius);
}

.msg-error {
  color: var(--danger);
  background: rgba(240, 108, 108, 0.1);
}

.export-desc {
  color: var(--text-muted);
  font-size: 0.9rem;
  margin: 0 0 0.5rem;
}

.export-actions {
  display: flex;
  gap: 0.5rem;
}

/* API tokens */
.tk-hint {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.8rem;
  color: var(--text-muted);
  margin: 0 0 1rem;
}
.tk-hint a {
  color: var(--primary);
}
.tk-created {
  background: rgba(var(--primary-rgb), 0.08);
  border: 1px solid var(--primary);
  border-radius: var(--radius);
  padding: 0.75rem 1rem;
  margin-bottom: 1rem;
}
.tk-created-warning {
  color: var(--primary);
  font-size: 0.85rem;
  margin: 0 0 0.5rem;
}
.tk-created-value {
  display: block;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
  word-break: break-all;
}
.tk-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.85rem;
  margin-bottom: 1rem;
}
.tk-table th {
  text-align: left;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--text-muted);
  font-weight: 500;
  padding: 0.3rem 0.5rem;
  border-bottom: 1px solid var(--border);
}
.tk-table td {
  padding: 0.4rem 0.5rem;
  border-bottom: 1px solid var(--border);
  vertical-align: top;
}
.tk-prefix {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.78rem;
  color: var(--text-muted);
}
.tk-scope {
  display: inline-block;
  background: rgba(var(--primary-rgb), 0.15);
  color: var(--primary);
  border-radius: 6px;
  padding: 0 0.4em;
  font-size: 0.78rem;
  margin: 0 0.25rem 0.25rem 0;
}
.tk-empty {
  color: var(--text-muted);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
  margin: 0 0 1rem;
}
.tk-revoke {
  background: transparent;
  border: 1px solid var(--border);
  border-radius: 6px;
  color: var(--text-muted);
  padding: 0.3rem;
  display: inline-flex;
  cursor: pointer;
  transition:
    color 0.15s,
    border-color 0.15s,
    background 0.15s;
}
.tk-revoke:hover {
  color: var(--danger);
  border-color: var(--danger);
  background: rgba(240, 108, 108, 0.08);
}
.tk-form input[type='text'] {
  width: 100%;
  margin-bottom: 0.75rem;
}
.tk-domains {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  margin-bottom: 0.75rem;
  max-width: 420px;
}
.tk-domain {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
}
.tk-domain-label {
  font-size: 0.8rem;
  color: var(--text-muted);
}
.tk-domain-select {
  width: 150px;
  flex-shrink: 0;
}
.tk-expiry {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  max-width: 420px;
  margin-bottom: 0.75rem;
}
.tk-expiry input {
  width: 150px;
  flex-shrink: 0;
}
/* Same row shape as .tk-domain: label left, control in the 150px column */
.tk-binary {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  max-width: 420px;
  margin-bottom: 0.75rem;
  cursor: pointer;
}
.tk-binary-box {
  width: 150px;
  flex-shrink: 0;
  display: flex;
  justify-content: center;
}
/* Terminal checkbox, same language as the checklists app: square cell,
   phosphor fill + dark check when on (the global stylesheet gives inputs
   width:100% + heavy padding; undo it). */
.tk-binary input[type='checkbox'] {
  appearance: none;
  -webkit-appearance: none;
  width: 16px;
  height: 16px;
  padding: 0;
  margin: 0;
  flex-shrink: 0;
  border: 1.5px solid var(--border);
  border-radius: 4px;
  background: var(--bg);
  cursor: pointer;
  transition:
    border-color 0.12s,
    background 0.12s,
    box-shadow 0.12s;
}
.tk-binary input[type='checkbox']:hover {
  border-color: var(--primary);
}
.tk-binary input[type='checkbox']:checked {
  border-color: var(--primary);
  background-color: var(--primary);
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath fill='none' stroke='%2305070f' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round' d='M3.5 8.5l3 3 6-7'/%3E%3C/svg%3E");
  background-size: 12px;
  background-position: center;
  background-repeat: no-repeat;
  box-shadow: 0 0 8px rgba(var(--primary-rgb), 0.4);
}
</style>
