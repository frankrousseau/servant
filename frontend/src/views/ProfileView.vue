<script setup lang="ts">
import { ref, onMounted } from 'vue'
import ComboBox from '../components/ComboBox.vue'
import { useAuthStore } from '../stores/auth'
import { useApi } from '../composables/useApi'
import { formatDate } from '../lib/datetime'
import QRCode from 'qrcode'
import {
  User as UserIcon,
  KeyRound,
  Info,
  Camera,
  ShieldCheck
} from 'lucide-vue-next'

const auth = useAuthStore()
const api = useApi()

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
    <h1>Profile</h1>

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
          <p class="card-desc">
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
          <p class="card-desc">
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
          <p class="card-desc">
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

    <!-- About -->
    <section class="card">
      <div class="card-header">
        <Info :size="20" class="card-icon" />
        <h2>About</h2>
      </div>

      <div class="card-body">
        <div class="info-row">
          <span class="info-label">Servant created on</span>
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

.card-desc {
  color: var(--text-muted);
  font-size: 0.9rem;
  margin: 0 0 0.5rem;
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
</style>
