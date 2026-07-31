<script setup lang="ts">
import { computed, ref, onMounted, watch } from 'vue'
import ComboBox from '../components/ComboBox.vue'
import { useAuthStore } from '../stores/auth'
import { useAppsStore } from '../stores/apps'
import { useApi } from '../composables/useApi'
import { formatDate } from '../lib/datetime'
import { useConfirm } from '../composables/useConfirm'
import {
  Download,
  TerminalSquare,
  Copy,
  Trash2,
  Puzzle,
  RefreshCw,
  Palette,
  Wrench
} from 'lucide-vue-next'
import { THEMES, applyTheme, storedTheme, type ThemeId } from '../lib/theme'
import { BUILTIN_APPS, DEFAULT_ENABLED_APPS } from '../apps/registry'
import type { ApiToken, AiConfig } from '../types'
import {
  SCOPE_DOMAINS,
  buildScopes,
  type AccessLevel
} from '../lib/apiTokenScopes'

const auth = useAuthStore()
const apps = useAppsStore()
const api = useApi()
const { ask } = useConfirm()

const buildCommit = __BUILD_COMMIT__
const buildDate = __BUILD_DATE__
const apiVersion = ref<{ commit: string; built_at: string } | null>(null)

async function loadApiVersion() {
  try {
    apiVersion.value = await api.get<{ commit: string; built_at: string }>(
      '/api/version'
    )
  } catch {
    // old backend without the endpoint: show the UI build alone
  }
}

// ----- Built-in app toggles -----

// Mirrors the user's preference; null on the account means the default set.
const enabledApps = ref<string[]>([...DEFAULT_ENABLED_APPS])

// Agents keeps its own /agents route but toggles like a built-in app.
const toggleableApps = [{ id: 'agents', name: 'Agents' }, ...BUILTIN_APPS]

watch(
  () => auth.user?.enabled_apps,
  ids => {
    enabledApps.value = [...(ids ?? DEFAULT_ENABLED_APPS)]
  },
  { immediate: true }
)

// Saves on every toggle (sidebar and palette follow live); rolled back if
// the save fails.
async function toggleApp(id: string) {
  const previous = [...enabledApps.value]
  enabledApps.value = enabledApps.value.includes(id)
    ? enabledApps.value.filter(x => x !== id)
    : [...enabledApps.value, id]
  try {
    await api.put('/api/auth/profile', { enabled_apps: enabledApps.value })
    if (auth.user) auth.user.enabled_apps = [...enabledApps.value]
  } catch {
    enabledApps.value = previous
  }
}

// ----- Appearance -----

const currentTheme = ref<ThemeId>(storedTheme())

// Applies instantly, then persists; rolled back if the save fails.
async function selectTheme(id: ThemeId) {
  if (currentTheme.value === id) return
  const previous = currentTheme.value
  currentTheme.value = id
  applyTheme(id)
  try {
    await api.put('/api/auth/profile', { theme: id })
    if (auth.user) auth.user.theme = id
  } catch {
    currentTheme.value = previous
    applyTheme(previous)
  }
}

// Installed apps (git-installed only; generated apps live in the Agents
// section's Builder tab)
const gitApps = computed(() => apps.installed.filter(a => !a.generated))
const appRepoUrl = ref('')
const appInstalling = ref(false)
const appError = ref('')

async function installApp() {
  const url = appRepoUrl.value.trim()
  if (!url) return

  const ok = await ask({
    title: 'Install app',
    message:
      'This app will run with the same access to your data as the built-in ' +
      'apps. Only install repositories you trust.',
    confirmLabel: 'Install'
  })
  if (!ok) return

  appError.value = ''
  appInstalling.value = true
  try {
    await apps.install(url)
    appRepoUrl.value = ''
  } catch (e) {
    appError.value = e instanceof Error ? e.message : 'Install failed'
  } finally {
    appInstalling.value = false
  }
}

async function uninstallApp(id: string, name: string) {
  const ok = await ask({
    title: 'Uninstall app',
    message: `Uninstall "${name}"? Its files will be removed.`,
    danger: true
  })
  if (!ok) return
  await apps.uninstall(id)
}

const appUpdating = ref('')

async function updateApp(id: string) {
  appError.value = ''
  appUpdating.value = id
  try {
    await apps.update(id)
  } catch (e) {
    appError.value = e instanceof Error ? e.message : 'Update failed'
  } finally {
    appUpdating.value = ''
  }
}

// ----- Agents (model server config) -----

const aiConfig = ref<AiConfig>({
  enabled: false,
  base_url: '',
  model: '',
  api_key: null
})
const aiSaving = ref(false)
const aiError = ref('')

async function loadAiConfig() {
  try {
    aiConfig.value = (await api.get<{ data: AiConfig }>('/api/ai_config')).data
  } catch {
    // section shows defaults; not fatal for the rest of settings
  }
}

async function saveAiConfig(overrides: Partial<AiConfig> = {}) {
  aiError.value = ''
  aiSaving.value = true
  try {
    const body = { ...aiConfig.value, ...overrides }
    aiConfig.value = (
      await api.put<{ data: AiConfig }>('/api/ai_config', body)
    ).data
  } catch (e) {
    aiError.value = e instanceof Error ? e.message : 'Save failed'
  } finally {
    aiSaving.value = false
  }
}

// The checkbox is an uncontrolled `:checked` bound to aiConfig.value.enabled;
// when the confirm dialog is cancelled or the save fails, aiConfig.value.enabled
// does not change, so resetting the DOM checkbox to it at the end of every
// path (success or not) keeps the two in sync.
async function toggleAgents(event: Event) {
  if (!aiConfig.value.enabled) {
    const ok = await ask({
      title: 'Enable agents',
      message:
        'App generation requests will be sent to the model server configured ' +
        'below. Only your app descriptions are sent, never your data. ' +
        'Generated code can be incorrect: review an app before trusting it.',
      confirmLabel: 'Enable'
    })
    if (ok) await saveAiConfig({ enabled: true })
  } else {
    await saveAiConfig({ enabled: false })
  }
  const target = event.target as HTMLInputElement
  target.checked = aiConfig.value.enabled
}

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

const copiedToken = ref(false)
let copiedTimer: ReturnType<typeof setTimeout> | undefined

async function copyCreatedToken() {
  if (!createdToken.value) return
  await navigator.clipboard.writeText(createdToken.value)
  // Nothing else confirms the copy happened, and the token is shown once.
  copiedToken.value = true
  clearTimeout(copiedTimer)
  copiedTimer = setTimeout(() => (copiedToken.value = false), 2000)
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

onMounted(() => {
  loadTokens()
  loadAiConfig()
  loadApiVersion()
  apps.load().catch(() => {})
})
</script>

<template>
  <div class="view">
    <h1>Settings</h1>

    <!-- Appearance -->
    <section class="card">
      <div class="card-header">
        <Palette :size="20" class="card-icon" />
        <h2>Appearance</h2>
      </div>
      <div class="card-body">
        <div class="theme-grid" role="radiogroup" aria-label="Theme">
          <button
            v-for="t in THEMES"
            :key="t.id"
            type="button"
            class="theme-card"
            :class="{ 'theme-card--active': currentTheme === t.id }"
            :data-theme="t.id"
            role="radio"
            :aria-checked="currentTheme === t.id"
            :title="t.hint"
            @click="selectTheme(t.id)"
          >
            <span class="theme-screen" aria-hidden="true">
              <span class="theme-line theme-line--text"></span>
              <span class="theme-line theme-line--muted"></span>
              <span class="theme-cursor"></span>
            </span>
            <span class="theme-name">{{ t.name }}</span>
          </button>
        </div>
      </div>
    </section>

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
          <div class="tk-created-row">
            <code class="tk-created-value">{{ createdToken }}</code>
            <button type="button" class="tk-copy" @click="copyCreatedToken">
              <Copy :size="14" /> {{ copiedToken ? 'Copied' : 'Copy' }}
            </button>
          </div>
          <button type="button" class="tk-dismiss" @click="createdToken = null">
            Done
          </button>
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

    <!-- Installed apps -->
    <section class="card">
      <div class="card-header">
        <Puzzle :size="20" class="card-icon" />
        <h2>Apps</h2>
      </div>
      <div class="card-body">
        <h3 class="app-subhead">Built-in apps</h3>
        <p class="tk-hint">
          Disabled apps disappear from the sidebar and the command palette;
          their data stays untouched.
        </p>
        <div class="app-toggles">
          <label v-for="a in toggleableApps" :key="a.id" class="toggle">
            <input
              type="checkbox"
              :checked="enabledApps.includes(a.id)"
              @change="toggleApp(a.id)"
            />
            {{ a.name }}
          </label>
        </div>

        <h3 class="app-subhead">Installed apps</h3>
        <p class="tk-hint">
          Install extra apps from a git repository containing a servant-app.json
          manifest and a pre-built entry module. Installed apps run with your
          full session: only install repositories you trust.
        </p>

        <table v-if="gitApps.length" class="tk-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Repository</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="a in gitApps" :key="a.id">
              <td>{{ a.name }}</td>
              <td class="app-repo">{{ a.repo_url }}</td>
              <td class="app-actions">
                <button
                  type="button"
                  class="tk-revoke"
                  title="Update from the repository"
                  :disabled="appUpdating === a.id"
                  @click="updateApp(a.id)"
                >
                  <RefreshCw
                    :size="14"
                    :class="{ spin: appUpdating === a.id }"
                  />
                </button>
                <button
                  type="button"
                  class="tk-revoke"
                  title="Uninstall"
                  @click="uninstallApp(a.id, a.name)"
                >
                  <Trash2 :size="14" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <p v-else class="tk-empty">No installed apps yet.</p>

        <form class="app-form" @submit.prevent="installApp">
          <input
            v-model="appRepoUrl"
            type="url"
            placeholder="https://github.com/you/your-servant-app.git"
          />
          <p v-if="appError" class="msg msg-error">{{ appError }}</p>
          <div class="card-actions">
            <button type="submit" :disabled="appInstalling || !appRepoUrl">
              {{ appInstalling ? 'Installing...' : 'Install app' }}
            </button>
          </div>
        </form>
      </div>
    </section>

    <!-- Agents -->
    <section class="card">
      <div class="card-header">
        <Wrench :size="20" class="card-icon" />
        <h2>Agents</h2>
      </div>
      <div class="card-body">
        <p class="tk-hint">
          Agents call a language model server that you configure (a local Ollama
          by default). Each run records the model used and the tokens consumed.
          Generated code can be incorrect: review an app before trusting it with
          your data.
        </p>

        <label class="tk-binary">
          <span class="tk-domain-label">Enable agents</span>
          <span class="tk-binary-box">
            <input
              type="checkbox"
              :checked="aiConfig.enabled"
              :disabled="aiSaving"
              @change="toggleAgents($event)"
            />
          </span>
        </label>

        <form class="ai-form" @submit.prevent="saveAiConfig()">
          <label class="tk-expiry">
            <span class="tk-domain-label">Base URL</span>
            <input
              v-model="aiConfig.base_url"
              type="text"
              placeholder="http://localhost:11434/v1"
            />
          </label>
          <label class="tk-expiry">
            <span class="tk-domain-label">Model</span>
            <input
              v-model="aiConfig.model"
              type="text"
              placeholder="qwen2.5-coder:14b"
            />
          </label>
          <label class="tk-expiry">
            <span class="tk-domain-label">API key (optional)</span>
            <input
              v-model="aiConfig.api_key"
              type="password"
              placeholder="not needed for local servers"
            />
          </label>
          <div class="card-actions">
            <button type="submit" :disabled="aiSaving">
              {{ aiSaving ? 'Saving...' : 'Save' }}
            </button>
          </div>
        </form>

        <p v-if="aiError" class="msg msg-error">{{ aiError }}</p>

        <p class="tk-hint">
          Agents themselves live in the
          <router-link to="/agents">Agents section</router-link>.
        </p>
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

    <p class="build-info">
      ui {{ buildCommit }} ({{ buildDate }})<template v-if="apiVersion">
        - api {{ apiVersion.commit }} ({{ apiVersion.built_at }})</template
      >
    </p>
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

/* Built-in app toggles */
.app-subhead {
  font-size: 0.85rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-muted);
  margin: 0 0 0.35rem;
}

.app-subhead + .tk-hint {
  margin-top: 0;
}

.app-toggles {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
  gap: 0.4rem 1rem;
  margin-bottom: 1.5rem;
}

/* Theme picker: each card carries its own data-theme, so the global palette
   blocks in style.css re-resolve the variables inside the preview. */
.theme-grid {
  display: flex;
  gap: 0.9rem;
  flex-wrap: wrap;
}

.theme-card {
  width: 132px;
  padding: 0.6rem;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  background: var(--bg);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 8px;
  cursor: pointer;
  text-align: left;
  transition:
    border-color 0.15s,
    box-shadow 0.15s;
}

.theme-card:hover {
  background: var(--bg);
  border-color: var(--text-muted);
}

.theme-card--active,
.theme-card--active:hover {
  border-color: var(--primary);
  box-shadow: 0 0 12px rgba(var(--primary-rgb), 0.35);
}

.theme-screen {
  display: block;
  position: relative;
  height: 64px;
  padding: 8px;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 4px;
}

.theme-line {
  display: block;
  height: 6px;
  border-radius: 2px;
  margin-bottom: 6px;
}

.theme-line--text {
  width: 72%;
  background: var(--text);
  opacity: 0.85;
}

.theme-line--muted {
  width: 45%;
  background: var(--text-muted);
  opacity: 0.8;
}

.theme-cursor {
  position: absolute;
  left: 8px;
  bottom: 8px;
  width: 10px;
  height: 12px;
  background: var(--primary);
  animation: theme-cursor-blink 1.2s steps(1) infinite;
}

@keyframes theme-cursor-blink {
  50% {
    opacity: 0.15;
  }
}

@media (prefers-reduced-motion: reduce) {
  .theme-cursor {
    animation: none;
  }
}

.theme-name {
  font-family: var(--font-display);
  font-size: 1.05rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
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

.build-info {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  color: var(--text-muted);
  text-align: right;
  margin: 0.5rem 0 1rem;
}

/* Installed apps */
.app-actions {
  white-space: nowrap;
}
.app-actions .tk-revoke {
  margin-left: 0.35rem;
}
.app-actions .spin {
  animation: app-spin 1s linear infinite;
}
@keyframes app-spin {
  to {
    transform: rotate(360deg);
  }
}
.app-repo {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.78rem;
  color: var(--text-muted);
  word-break: break-all;
}
.app-form input[type='url'] {
  width: 100%;
  margin-bottom: 0.75rem;
}
.app-form input[type='text'],
.app-form textarea {
  width: 100%;
  margin-bottom: 0.75rem;
}
.ai-form {
  margin-bottom: 1.5rem;
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
/* The token reads as a field with its action attached, not as loose text
   above two buttons of equal weight. */
.tk-created-row {
  display: flex;
  align-items: stretch;
  gap: 0.5rem;
}
.tk-created-value {
  flex: 1;
  min-width: 0;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 0.5rem 0.65rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
  word-break: break-all;
  user-select: all;
}
.tk-copy {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  flex-shrink: 0;
  padding: 0.4rem 0.85rem;
  font-size: 0.85rem;
}
/* Secondary to the copy: dismissing is not what you came for. */
.tk-dismiss {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  margin-top: 0.6rem;
  padding: 0.3rem 0.75rem;
  font-size: 0.8rem;
}
.tk-dismiss:hover {
  background: var(--bg-hover);
  color: var(--text);
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
