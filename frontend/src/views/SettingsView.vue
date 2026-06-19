<script setup lang="ts">
import { ref, onMounted } from "vue";
import { useAuthStore } from "../stores/auth";
import { useApi } from "../composables/useApi";
import { User as UserIcon, KeyRound, Info, Download, Camera } from "lucide-vue-next";

const auth = useAuthStore();
const api = useApi();

// Profile
const displayName = ref("");
const email = ref("");
const avatarUrl = ref<string | null>(null);
const avatarUploading = ref(false);
const profileSaving = ref(false);
const profileSuccess = ref(false);
const profileError = ref("");

// Password
const currentPassword = ref("");
const newPassword = ref("");
const confirmPassword = ref("");
const passwordSaving = ref(false);
const passwordSuccess = ref(false);
const passwordError = ref("");

// Export
const exporting = ref(false);
const exportingEntries = ref(false);

async function downloadFile(url: string, fallbackName: string, loadingRef: typeof exporting) {
  loadingRef.value = true;
  try {
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${auth.token}` },
    });
    if (!res.ok) throw new Error("Download failed");
    const blob = await res.blob();
    const blobUrl = URL.createObjectURL(blob);
    const a = document.createElement("a");
    const disposition = res.headers.get("content-disposition") || "";
    const match = disposition.match(/filename="(.+)"/);
    a.href = blobUrl;
    a.download = match?.[1] || fallbackName;
    a.click();
    URL.revokeObjectURL(blobUrl);
  } catch (e: any) {
    alert(e.message || "Failed to download");
  } finally {
    loadingRef.value = false;
  }
}

function downloadDatabase() { downloadFile("/api/export/database", "servant.db", exporting); }
function downloadEntries() { downloadFile("/api/export/entries", "servant_entries.json", exportingEntries); }

// Account info
const memberSince = ref("");

onMounted(async () => {
  try {
    const res = await api.get<{
      data: { display_name: string; email: string | null; avatar_path: string | null; inserted_at: string };
    }>("/api/auth/me");
    displayName.value = res.data.display_name || "";
    email.value = res.data.email || "";
    avatarUrl.value = res.data.avatar_path;
    memberSince.value = new Date(res.data.inserted_at).toLocaleDateString();
  } catch {
    displayName.value = auth.user?.display_name || "";
  }
});

async function saveProfile() {
  profileSaving.value = true;
  profileSuccess.value = false;
  profileError.value = "";
  try {
    const res = await api.put<{
      data: { id: string; username: string; display_name: string; email: string | null; avatar_path: string | null };
    }>("/api/auth/profile", {
      display_name: displayName.value,
      email: email.value || null,
    });
    if (auth.user) {
      auth.user.display_name = res.data.display_name;
      auth.user.email = res.data.email;
    }
    profileSuccess.value = true;
    setTimeout(() => (profileSuccess.value = false), 3000);
  } catch (e: any) {
    profileError.value = e.message || "Failed to update profile";
  } finally {
    profileSaving.value = false;
  }
}

async function uploadAvatar(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  if (!file) return;

  avatarUploading.value = true;
  const formData = new FormData();
  formData.append("avatar", file);

  try {
    const res = await fetch("/api/auth/avatar", {
      method: "POST",
      headers: { Authorization: `Bearer ${auth.token}` },
      body: formData,
    });
    const data = await res.json();
    if (res.ok) {
      avatarUrl.value = data.data.avatar_path + "?t=" + Date.now();
      if (auth.user) auth.user.avatar_path = data.data.avatar_path;
    }
  } catch {
    // ignore
  } finally {
    avatarUploading.value = false;
    input.value = "";
  }
}

async function changePassword() {
  passwordSuccess.value = false;
  passwordError.value = "";

  if (newPassword.value !== confirmPassword.value) {
    passwordError.value = "New passwords do not match";
    return;
  }
  if (newPassword.value.length < 8) {
    passwordError.value = "Password must be at least 8 characters";
    return;
  }

  passwordSaving.value = true;
  try {
    await api.put("/api/auth/password", {
      current_password: currentPassword.value,
      new_password: newPassword.value,
    });
    currentPassword.value = "";
    newPassword.value = "";
    confirmPassword.value = "";
    passwordSuccess.value = true;
    setTimeout(() => (passwordSuccess.value = false), 3000);
  } catch (e: any) {
    passwordError.value = e.message || "Failed to change password";
  } finally {
    passwordSaving.value = false;
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
              {{ (displayName || auth.user?.username || "?")[0].toUpperCase() }}
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

        <p v-if="profileError" class="msg msg-error">{{ profileError }}</p>
        <p v-if="profileSuccess" class="msg msg-success">Profile updated.</p>

          <div class="card-actions">
            <button type="submit" :disabled="profileSaving">
              {{ profileSaving ? "Saving..." : "Save" }}
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
            {{ passwordSaving ? "Changing..." : "Change Password" }}
          </button>
        </div>
      </form>
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
            {{ exportingEntries ? "Downloading..." : "Entries (JSON)" }}
          </button>
          <button @click="downloadDatabase" :disabled="exporting">
            {{ exporting ? "Downloading..." : "Database (SQLite)" }}
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
          <span class="info-value">{{ memberSince || "—" }}</span>
        </div>
        <div class="info-row">
          <span class="info-label">User ID</span>
          <span class="info-value mono">{{ auth.user?.id || "—" }}</span>
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
</style>
