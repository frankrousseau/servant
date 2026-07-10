<script setup lang="ts">
import { ref, onMounted } from 'vue'
import ComboBox from '../components/ComboBox.vue'
import { useAuthStore } from '../stores/auth'
import { useApi } from '../composables/useApi'
import { formatDate } from '../lib/datetime'
import { useConfirm } from '../composables/useConfirm'
import QRCode from 'qrcode'
import {
  User as UserIcon,
  KeyRound,
  Info,
  Download,
  Camera,
  ShieldCheck,
  TerminalSquare,
  Copy,
  Trash2
} from 'lucide-vue-next'
import type { ApiToken } from '../types'
import {
  SCOPE_DOMAINS,
  buildScopes,
  type AccessLevel
} from '../lib/apiTokenScopes'

const auth = useAuthStore()
const api = useApi()
const { ask } = useConfirm()

// Profile
const displayName = ref('')
const email = ref('')
const timezone = ref('UTC')

// Available IANA timezones for the picker. `supportedValuesOf` is widely
// supported; fall back to a small common set (plus the browser's) otherwise.
const timezones: string[] = (() => {
  try {
    const supported = (
      Intl as unknown as {
        supportedValuesOf?: (k: string) => string[]
      }
    ).supportedValuesOf
    if (supported) return supported('timeZone')
  } catch {
    // fall through
  }
  const browser = Intl.DateTimeFormat().resolvedOptions().timeZone
  return Array.from(
    new Set([
      'UTC',
      browser,
      'Europe/Paris',
      'Europe/London',
      'America/New_York',
      'America/Los_Angeles',
      'Asia/Tokyo'
    ])
  )
})()
const avatarUrl = ref<string | null>(null)
const avatarUploading = ref(false)
const profileSaving = ref(false)
const profileSuccess = ref(false)
const profileError = ref('')

// Password
const currentPassword = ref('')
const newPassword = ref('')
const confirmPassword = ref('')
const passwordSaving = ref(false)
const passwordSuccess = ref(false)
const passwordError = ref('')

// Two-factor authentication (TOTP)
const totpEnabled = ref(false)
const totpSetup = ref<{ payload: string; secret: string } | null>(null)
const totpQr = ref('')
const totpCode = ref('')
const totpDisableCode = ref('')
const totpError = ref('')
const totpBusy = ref(false)

async function startTotpSetup() {
  totpError.value = ''
  totpBusy.value = true
  try {
    const res = await api.post<{
      secret: string
      otpauth_url: string
      payload: string
    }>('/api/auth/totp/setup')
    totpSetup.value = { payload: res.payload, secret: res.secret }
    totpQr.value = await QRCode.toDataURL(res.otpauth_url, {
      margin: 1,
      width: 220
    })
    totpCode.value = ''
  } catch (e: any) {
    totpError.value = e.message || 'Setup failed'
  } finally {
    totpBusy.value = false
  }
}

async function confirmTotp() {
  if (!totpSetup.value) return
  totpError.value = ''
  totpBusy.value = true
  try {
    await api.post('/api/auth/totp/confirm', {
      payload: totpSetup.value.payload,
      code: totpCode.value.trim()
    })
    totpEnabled.value = true
    totpSetup.value = null
    totpQr.value = ''
    totpCode.value = ''
  } catch (e: any) {
    totpError.value = e.message || 'Invalid code'
  } finally {
    totpBusy.value = false
  }
}

async function disableTotp() {
  totpError.value = ''
  totpBusy.value = true
  try {
    await api.del('/api/auth/totp', { code: totpDisableCode.value.trim() })
    totpEnabled.value = false
    totpDisableCode.value = ''
  } catch (e: any) {
    totpError.value = e.message || 'Invalid code'
  } finally {
    totpBusy.value = false
  }
}

// API tokens
const apiTokens = ref<ApiToken[]>([])
const tokenName = ref('')
const tokenExpiry = ref('') // yyyy-mm-dd from <input type="date">, optional
const tokenLevels = ref<Record<string, AccessLevel>>({})
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
  const scopes = buildScopes(tokenLevels.value)
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

// Account info
const memberSince = ref('')

onMounted(async () => {
  try {
    const res = await api.get<{
      data: {
        display_name: string
        email: string | null
        avatar_path: string | null
        timezone: string | null
        totp_enabled: boolean
        inserted_at: string
      }
    }>('/api/auth/me')
    displayName.value = res.data.display_name || ''
    email.value = res.data.email || ''
    totpEnabled.value = res.data.totp_enabled === true
    timezone.value = res.data.timezone || 'UTC'
    avatarUrl.value = res.data.avatar_path
    memberSince.value = formatDate(res.data.inserted_at)
  } catch {
    displayName.value = auth.user?.display_name || ''
  }
  await loadTokens()
})

async function saveProfile() {
  profileSaving.value = true
  profileSuccess.value = false
  profileError.value = ''
  try {
    const res = await api.put<{
      data: {
        id: string
        username: string
        display_name: string
        email: string | null
        avatar_path: string | null
        timezone: string | null
      }
    }>('/api/auth/profile', {
      display_name: displayName.value,
      email: email.value || null,
      timezone: timezone.value
    })
    if (auth.user) {
      auth.user.display_name = res.data.display_name
      auth.user.email = res.data.email
      auth.user.timezone = res.data.timezone
    }
    profileSuccess.value = true
    setTimeout(() => (profileSuccess.value = false), 3000)
  } catch (e: any) {
    profileError.value = e.message || 'Failed to update profile'
  } finally {
    profileSaving.value = false
  }
}

async function uploadAvatar(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return

  avatarUploading.value = true
  const formData = new FormData()
  formData.append('avatar', file)

  try {
    const res = await fetch('/api/auth/avatar', {
      method: 'POST',
      headers: auth.token ? { Authorization: `Bearer ${auth.token}` } : {},
      body: formData
    })
    const data = await res.json()
    if (res.ok) {
      avatarUrl.value = data.data.avatar_path + '?t=' + Date.now()
      if (auth.user) auth.user.avatar_path = data.data.avatar_path
    }
  } catch {
    // ignore
  } finally {
    avatarUploading.value = false
    input.value = ''
  }
}

async function changePassword() {
  passwordSuccess.value = false
  passwordError.value = ''

  if (newPassword.value !== confirmPassword.value) {
    passwordError.value = 'New passwords do not match'
    return
  }
  if (newPassword.value.length < 8) {
    passwordError.value = 'Password must be at least 8 characters'
    return
  }

  passwordSaving.value = true
  try {
    await api.put('/api/auth/password', {
      current_password: currentPassword.value,
      new_password: newPassword.value
    })
    currentPassword.value = ''
    newPassword.value = ''
    confirmPassword.value = ''
    passwordSuccess.value = true
    setTimeout(() => (passwordSuccess.value = false), 3000)
  } catch (e: any) {
    passwordError.value = e.message || 'Failed to change password'
  } finally {
    passwordSaving.value = false
  }
}
</script>

<template>
  <div class="view">
    <h1>Settings</h1>

    <!-- Profile -->
    <section class="card">
      <div class="card-header">
        <UserIcon :size="20" class="card-icon" />
        <h2>Profile</h2>
      </div>

      <div class="card-body">
        <!-- Avatar -->
        <div class="avatar-section">
          <label class="avatar-wrapper" :class="{ uploading: avatarUploading }">
            <img
              v-if="avatarUrl"
              :src="avatarUrl"
              alt="Avatar"
              class="avatar-img"
            />
            <span v-else class="avatar-placeholder">
              {{ (displayName || auth.user?.username || '?')[0].toUpperCase() }}
            </span>
            <span class="avatar-overlay">
              <Camera :size="18" />
            </span>
            <input
              type="file"
              accept="image/png,image/jpeg,image/gif,image/webp"
              class="avatar-input"
              @change="uploadAvatar"
            />
          </label>
        </div>

        <form @submit.prevent="saveProfile">
          <div class="field">
            <label for="display-name">Display name</label>
            <input
              id="display-name"
              v-model="displayName"
              type="text"
              required
            />
          </div>

          <div class="field">
            <label for="email">Email</label>
            <input
              id="email"
              v-model="email"
              type="email"
              placeholder="your@email.com"
            />
          </div>

          <div class="field">
            <label for="timezone">Timezone</label>
            <ComboBox v-model="timezone" :options="timezones" />
            <p class="field-hint">
              Dates and times are shown in this timezone.
            </p>
          </div>

          <p v-if="profileError" class="msg msg-error">{{ profileError }}</p>
          <p v-if="profileSuccess" class="msg msg-success">Profile updated.</p>

          <div class="card-actions">
            <button type="submit" :disabled="profileSaving">
              {{ profileSaving ? 'Saving...' : 'Save' }}
            </button>
          </div>
        </form>
      </div>
    </section>

    <!-- Password -->
    <section class="card">
      <div class="card-header">
        <KeyRound :size="20" class="card-icon" />
        <h2>Change Password</h2>
      </div>

      <form @submit.prevent="changePassword" class="card-body">
        <div class="field">
          <label for="current-pw">Current password</label>
          <input
            id="current-pw"
            v-model="currentPassword"
            type="password"
            required
            autocomplete="current-password"
          />
        </div>
        <div class="field">
          <label for="new-pw">New password</label>
          <input
            id="new-pw"
            v-model="newPassword"
            type="password"
            required
            autocomplete="new-password"
            minlength="8"
          />
        </div>
        <div class="field">
          <label for="confirm-pw">Confirm new password</label>
          <input
            id="confirm-pw"
            v-model="confirmPassword"
            type="password"
            required
            autocomplete="new-password"
          />
        </div>

        <p v-if="passwordError" class="msg msg-error">{{ passwordError }}</p>
        <p v-if="passwordSuccess" class="msg msg-success">
          Password changed successfully.
        </p>

        <div class="card-actions">
          <button type="submit" :disabled="passwordSaving">
            {{ passwordSaving ? 'Changing...' : 'Change Password' }}
          </button>
        </div>
      </form>
    </section>

    <!-- Two-factor authentication -->
    <section class="card">
      <div class="card-header">
        <ShieldCheck :size="20" class="card-icon" />
        <h2>Two-Factor Authentication</h2>
      </div>

      <div class="card-body">
        <template v-if="totpEnabled">
          <p class="export-desc">
            2FA is on: signing in asks for a code from your authenticator app.
            Enter a current code to turn it off.
          </p>
          <div class="totp-row">
            <input
              v-model="totpDisableCode"
              class="totp-code"
              inputmode="numeric"
              maxlength="6"
              placeholder="123456"
            />
            <button
              :disabled="totpBusy || totpDisableCode.trim().length < 6"
              @click="disableTotp"
            >
              Disable 2FA
            </button>
          </div>
        </template>

        <template v-else-if="totpSetup">
          <p class="export-desc">
            Scan the QR code with your authenticator app (Aegis, Google
            Authenticator…), then confirm with the 6-digit code it shows.
          </p>
          <img v-if="totpQr" :src="totpQr" class="totp-qr" alt="TOTP QR code" />
          <p class="totp-secret">{{ totpSetup.secret }}</p>
          <div class="totp-row">
            <input
              v-model="totpCode"
              class="totp-code"
              inputmode="numeric"
              maxlength="6"
              placeholder="123456"
            />
            <button
              :disabled="totpBusy || totpCode.trim().length < 6"
              @click="confirmTotp"
            >
              Confirm
            </button>
            <button class="btn-secondary" @click="totpSetup = null">
              Cancel
            </button>
          </div>
        </template>

        <template v-else>
          <p class="export-desc">
            Protect sign-in with one-time codes from an authenticator app
            (TOTP). Recovery on this self-hosted instance is operator-side:
            clear <code>users.totp_secret</code> in the database if the device
            is lost.
          </p>
          <div class="card-actions">
            <button :disabled="totpBusy" @click="startTotpSetup">
              Enable 2FA
            </button>
          </div>
        </template>

        <p v-if="totpError" class="msg msg-error">{{ totpError }}</p>
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
                :model-value="tokenLevels[d.id] ?? 'none'"
                :options="ACCESS_OPTIONS"
                @update:model-value="
                  v => (tokenLevels[d.id] = v as AccessLevel)
                "
              />
            </div>
          </div>
          <label class="tk-expiry">
            Expires (optional)
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

    <!-- About -->
    <section class="card">
      <div class="card-header">
        <Info :size="20" class="card-icon" />
        <h2>About</h2>
      </div>

      <div class="card-body">
        <div class="info-row">
          <span class="info-label">Member since</span>
          <span class="info-value">{{ memberSince || '-' }}</span>
        </div>
        <div class="info-row">
          <span class="info-label">User ID</span>
          <span class="info-value mono">{{ auth.user?.id || '-' }}</span>
        </div>
      </div>
    </section>
  </div>
</template>

<style scoped>
.field-hint {
  margin: 0.35rem 0 0;
  font-size: 0.8rem;
  color: var(--text-muted);
}
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

/* Info rows */
.info-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.5rem 0;
}

.info-row + .info-row {
  border-top: 1px solid var(--border);
}

.info-row + .field {
  margin-top: 0.75rem;
}

.info-label {
  color: var(--text-muted);
  font-size: 0.9rem;
}

.info-value {
  font-weight: 500;
}

.info-value.mono {
  font-family: monospace;
  font-size: 0.9rem;
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

.msg-success {
  color: var(--success);
  background: rgba(92, 201, 138, 0.1);
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

/* Avatar */
.avatar-section {
  display: flex;
  justify-content: center;
  margin-bottom: 1.25rem;
}

.avatar-wrapper {
  position: relative;
  width: 80px;
  height: 80px;
  border-radius: 50%;
  cursor: pointer;
  overflow: hidden;
}

.avatar-wrapper.uploading {
  opacity: 0.5;
}

.avatar-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.avatar-placeholder {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--bg-hover);
  color: var(--text-muted);
  font-size: 2rem;
  font-weight: 600;
}

.avatar-overlay {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.5);
  color: #fff;
  opacity: 0;
  transition: opacity 0.15s;
}

.avatar-wrapper:hover .avatar-overlay {
  opacity: 1;
}

.avatar-input {
  display: none;
}

.totp-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.totp-code {
  width: 120px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  letter-spacing: 0.15em;
}
.totp-qr {
  display: block;
  width: 220px;
  border-radius: 8px;
  margin-bottom: 0.5rem;
  /* white quiet zone so scanners cope with the dark theme */
  background: #fff;
}
.totp-secret {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.8rem;
  color: var(--text-muted);
  word-break: break-all;
  margin: 0 0 0.75rem;
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
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 0.5rem;
  margin-bottom: 0.75rem;
}
.tk-domain {
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
}
.tk-domain-label {
  font-size: 0.8rem;
  color: var(--text-muted);
}
.tk-expiry {
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
  font-size: 0.85rem;
  color: var(--text-muted);
  max-width: 200px;
  margin-bottom: 0.5rem;
}
</style>
