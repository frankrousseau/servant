<script setup lang="ts">
import { ref, computed, reactive, nextTick, onMounted, onUnmounted } from "vue";
import type { AppContext, Entry } from "../types";
import { formatDate } from "../../lib/datetime";
import { contactField, contactName, contactInitials } from "../../lib/contact";

const props = defineProps<{ ctx: AppContext }>();

interface Labeled {
  value: string;
  type: string;
}

const allContacts = ref<Entry[]>([]);
const searchQuery = ref("");
const selectedId = ref<string | null>(
  new URLSearchParams(window.location.search).get("selected"),
);
const loading = ref(true);
const loadError = ref("");

const modalOpen = ref(false);
const creating = ref(false);
const modalError = ref("");
const nameInput = ref<HTMLInputElement | null>(null);
const form = reactive({
  display_name: "",
  org: "",
  title: "",
  email: "",
  email_type: "",
  phone: "",
  phone_type: "",
  address: "",
  birthday: "",
  url: "",
  note: "",
});

const fld = contactField;
const getInitials = contactInitials;
const isUnnamed = (c: Entry) => contactName(c) === "(unnamed)";
const getEmails = (e: Entry) => (e.data.emails as Labeled[]) || [];
const getPhones = (e: Entry) => (e.data.phones as Labeled[]) || [];

// Only allow safe schemes for a vCard URL rendered into an href (blocks
// `javascript:` stored XSS).
function safeUrl(url: string): string | null {
  try {
    const scheme = new URL(url, window.location.origin).protocol;
    return ["http:", "https:", "mailto:", "tel:"].includes(scheme) ? url : null;
  } catch {
    return null;
  }
}

function sortContacts(list: Entry[]): Entry[] {
  return [...list].sort((a, b) => {
    const aUn = isUnnamed(a);
    const bUn = isUnnamed(b);
    if (aUn !== bUn) return aUn ? 1 : -1;
    return contactName(a).toLowerCase().localeCompare(contactName(b).toLowerCase());
  });
}

const filtered = computed(() => {
  if (!searchQuery.value) return allContacts.value;
  const q = searchQuery.value.toLowerCase();
  return allContacts.value.filter((c) => {
    const name = contactName(c).toLowerCase();
    const org = fld(c, "org").toLowerCase();
    const email = getEmails(c).map((e) => e.value.toLowerCase()).join(" ");
    const phone = getPhones(c).map((p) => p.value).join(" ");
    return name.includes(q) || org.includes(q) || email.includes(q) || phone.includes(q);
  });
});

const selected = computed(
  () => allContacts.value.find((c) => c.id === selectedId.value) || null,
);

const websiteHref = computed(() => (selected.value ? safeUrl(fld(selected.value, "url")) : null));

function selectContact(id: string) {
  selectedId.value = id;
  history.replaceState(null, "", "/apps/contacts?selected=" + id);
}

function onSearch() {
  selectedId.value = null;
  history.replaceState(null, "", "/apps/contacts");
}

function openCreate() {
  modalError.value = "";
  Object.keys(form).forEach((k) => ((form as Record<string, string>)[k] = ""));
  modalOpen.value = true;
  nextTick(() => nameInput.value?.focus());
}

function closeCreate() {
  modalOpen.value = false;
}

async function submitCreate() {
  const displayName = form.display_name.trim();
  if (!displayName) return;

  creating.value = true;
  modalError.value = "";

  const emails: Labeled[] = [];
  if (form.email.trim()) emails.push({ value: form.email.trim(), type: form.email_type.trim() });
  const phones: Labeled[] = [];
  if (form.phone.trim()) phones.push({ value: form.phone.trim(), type: form.phone_type.trim() });

  const titleParts = [displayName, form.org.trim(), form.title.trim(), form.email.trim()].filter(
    Boolean,
  );

  try {
    const created = await props.ctx.api.entries.create({
      kind: "contact",
      source: "manual",
      title: titleParts.join(" — "),
      data: {
        display_name: displayName,
        org: form.org.trim() || null,
        title: form.title.trim() || null,
        emails,
        phones,
        address: form.address.trim() || null,
        birthday: form.birthday.trim() || null,
        url: form.url.trim() || null,
        note: form.note.trim() || null,
      },
    });
    allContacts.value = sortContacts([...allContacts.value, created]);
    selectContact(created.id);
    modalOpen.value = false;
  } catch (err) {
    modalError.value = err instanceof Error ? err.message : "Failed to create contact";
  } finally {
    creating.value = false;
  }
}

function onKeydown(e: KeyboardEvent) {
  if (e.key === "Escape" && modalOpen.value) closeCreate();
}

async function reload() {
  loadError.value = "";
  try {
    const entries = await props.ctx.api.entries.list({ kind: "contact" });
    allContacts.value = sortContacts(entries);
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : "Failed to load contacts";
  } finally {
    loading.value = false;
  }
}

onMounted(() => {
  document.addEventListener("keydown", onKeydown);
  reload();
});
onUnmounted(() => document.removeEventListener("keydown", onKeydown));
</script>

<template>
  <p v-if="loading" class="ct-loading">Loading contacts...</p>
  <p v-else-if="loadError" class="ct-loading">{{ loadError }}</p>
  <div v-else class="ct-layout">
    <div class="ct-list-col">
      <div class="ct-search-wrap">
        <input
          class="ct-search"
          type="text"
          placeholder="Search contacts..."
          v-model="searchQuery"
          @input="onSearch"
        />
        <span class="ct-count">{{ filtered.length }}</span>
        <button class="ct-add-contact-btn" title="New contact" @click="openCreate">
          <svg
            width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
            stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
          >
            <line x1="12" y1="5" x2="12" y2="19" />
            <line x1="5" y1="12" x2="19" y2="12" />
          </svg>
        </button>
      </div>
      <div class="ct-list">
        <div
          v-for="c in filtered"
          :key="c.id"
          class="ct-card"
          :class="{ 'ct-card--active': c.id === selectedId }"
          @click="selectContact(c.id)"
        >
          <span v-if="fld(c, 'photo')" class="ct-avatar ct-avatar--photo">
            <img :src="fld(c, 'photo')" alt="" loading="lazy" />
          </span>
          <span v-else class="ct-avatar">{{ getInitials(contactName(c)) }}</span>
          <div class="ct-card-body">
            <span class="ct-name">{{ contactName(c) }}</span>
            <span class="ct-sub">{{ fld(c, "org") || getEmails(c)[0]?.value || "" }}</span>
          </div>
        </div>
        <p v-if="filtered.length === 0" class="ct-empty">No contacts found.</p>
      </div>
    </div>

    <div class="ct-detail-col">
      <div v-if="selected" class="ct-detail">
        <div class="ct-detail-header">
          <span v-if="fld(selected, 'photo')" class="ct-avatar ct-avatar--lg ct-avatar--photo">
            <img :src="fld(selected, 'photo')" alt="" loading="lazy" />
          </span>
          <span v-else class="ct-avatar ct-avatar--lg">{{ getInitials(contactName(selected)) }}</span>
          <div>
            <h2 class="ct-detail-name">{{ contactName(selected) }}</h2>
            <span
              v-if="fld(selected, 'title') || fld(selected, 'org')"
              class="ct-detail-sub"
            >{{ [fld(selected, "title"), fld(selected, "org")].filter(Boolean).join(" · ") }}</span>
          </div>
        </div>

        <div class="ct-section-card">
          <h3 class="ct-section-title">Contact Info</h3>
          <div v-for="(e, i) in getEmails(selected)" :key="'e' + i" class="ct-info-row">
            <svg
              class="ct-info-icon" width="16" height="16" viewBox="0 0 24 24" fill="none"
              stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
            >
              <rect width="20" height="16" x="2" y="4" rx="2" />
              <path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7" />
            </svg>
            <div class="ct-info-body">
              <a class="ct-link" :href="'mailto:' + e.value">{{ e.value }}</a>
              <span v-if="e.type" class="ct-info-type">{{ e.type }}</span>
            </div>
          </div>
          <div v-for="(p, i) in getPhones(selected)" :key="'p' + i" class="ct-info-row">
            <svg
              class="ct-info-icon" width="16" height="16" viewBox="0 0 24 24" fill="none"
              stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
            >
              <path
                d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"
              />
            </svg>
            <div class="ct-info-body">
              <a class="ct-link" :href="'tel:' + p.value">{{ p.value }}</a>
              <span v-if="p.type" class="ct-info-type">{{ p.type }}</span>
            </div>
          </div>
          <span v-if="!getEmails(selected).length && !getPhones(selected).length" class="ct-muted">
            No contact info
          </span>
        </div>

        <div
          v-if="fld(selected, 'address') || fld(selected, 'birthday') || fld(selected, 'url') || fld(selected, 'note')"
          class="ct-section-card"
        >
          <h3 class="ct-section-title">Details</h3>
          <div class="ct-meta-list">
            <div v-if="fld(selected, 'address')" class="ct-meta-row">
              <span class="ct-meta-key">Address</span><span>{{ fld(selected, "address") }}</span>
            </div>
            <div v-if="fld(selected, 'birthday')" class="ct-meta-row">
              <span class="ct-meta-key">Birthday</span><span>{{ fld(selected, "birthday") }}</span>
            </div>
            <div v-if="fld(selected, 'url')" class="ct-meta-row">
              <span class="ct-meta-key">Website</span>
              <span>
                <a
                  v-if="websiteHref"
                  class="ct-link"
                  :href="websiteHref"
                  target="_blank"
                  rel="noopener"
                >{{ fld(selected, "url") }}</a>
                <template v-else>{{ fld(selected, "url") }}</template>
              </span>
            </div>
            <div v-if="fld(selected, 'note')" class="ct-meta-row">
              <span class="ct-meta-key">Note</span>
              <span class="ct-note">{{ fld(selected, "note") }}</span>
            </div>
          </div>
        </div>

        <div class="ct-section-card ct-section-card--muted">
          <h3 class="ct-section-title">Info</h3>
          <div class="ct-meta-list">
            <div class="ct-meta-row">
              <span class="ct-meta-key">Source</span>
              <span>{{ fld(selected, "source_name") || selected.source }}</span>
            </div>
            <div class="ct-meta-row">
              <span class="ct-meta-key">Added</span>
              <span>{{ formatDate(selected.inserted_at) }}</span>
            </div>
            <div v-if="selected.external_id" class="ct-meta-row">
              <span class="ct-meta-key">ID</span>
              <span class="ct-mono">{{ selected.external_id }}</span>
            </div>
          </div>
        </div>

        <div class="ct-detail-footer">
          <button class="ct-footer-btn" @click="ctx.navigate('/contacts/' + selected.id + '?edit=1')">
            Edit
          </button>
          <button
            class="ct-footer-btn ct-footer-btn--link"
            @click="ctx.navigate('/contacts/' + selected.id)"
          >
            Open full page
          </button>
        </div>
      </div>
      <p v-else class="ct-placeholder">Select a contact to view details</p>
    </div>
  </div>

  <Teleport to="body">
    <div v-if="modalOpen" class="ct-modal-overlay" @click.self="closeCreate">
      <div class="ct-modal">
        <h2 class="ct-modal-title">New Contact</h2>
        <form class="ct-modal-form" @submit.prevent="submitCreate">
          <div class="ct-modal-grid">
            <div class="ct-modal-field">
              <label>Name *</label><input ref="nameInput" v-model="form.display_name" required />
            </div>
            <div class="ct-modal-field"><label>Organization</label><input v-model="form.org" /></div>
            <div class="ct-modal-field">
              <label>Title</label><input v-model="form.title" placeholder="e.g. Software Engineer" />
            </div>
          </div>
          <div class="ct-modal-section-label">Contact</div>
          <div class="ct-modal-row">
            <input v-model="form.email" type="email" placeholder="Email" class="ct-modal-flex" />
            <input v-model="form.email_type" placeholder="Type" class="ct-modal-type" />
          </div>
          <div class="ct-modal-row">
            <input v-model="form.phone" type="tel" placeholder="Phone" class="ct-modal-flex" />
            <input v-model="form.phone_type" placeholder="Type" class="ct-modal-type" />
          </div>
          <div class="ct-modal-section-label">Details</div>
          <div class="ct-modal-field"><label>Address</label><input v-model="form.address" /></div>
          <div class="ct-modal-grid">
            <div class="ct-modal-field">
              <label>Birthday</label><input v-model="form.birthday" type="date" />
            </div>
            <div class="ct-modal-field">
              <label>Website</label><input v-model="form.url" type="url" placeholder="https://..." />
            </div>
          </div>
          <div class="ct-modal-field">
            <label>Note</label><textarea v-model="form.note" rows="2"></textarea>
          </div>
          <p v-if="modalError" class="ct-modal-error">{{ modalError }}</p>
          <div class="ct-modal-actions">
            <button type="button" class="ct-modal-btn ct-modal-btn--cancel" @click="closeCreate">
              Cancel
            </button>
            <button type="submit" class="ct-modal-btn ct-modal-btn--primary" :disabled="creating">
              {{ creating ? "Creating..." : "Create" }}
            </button>
          </div>
        </form>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.ct-loading {
  color: var(--text-muted);
  padding: 2rem;
}
.ct-layout {
  display: flex;
  height: calc(100vh - 4rem);
}
.ct-list-col {
  width: 360px;
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  border-right: 1px solid var(--border);
}
.ct-detail-col {
  flex: 1;
  overflow-y: auto;
  padding: 1.5rem;
}
.ct-search-wrap {
  padding: 0.75rem;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  border-bottom: 1px solid var(--border);
}
.ct-search {
  flex: 1;
}
.ct-count {
  font-size: 0.8rem;
  color: var(--text-muted);
  white-space: nowrap;
}
.ct-list {
  flex: 1;
  overflow-y: auto;
  padding: 0.375rem;
}
.ct-card {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.6rem 0.75rem;
  border-radius: 8px;
  cursor: pointer;
  transition: background 0.1s;
}
.ct-card:hover {
  background: var(--bg-hover);
}
.ct-card--active {
  background: var(--bg-hover);
}
.ct-avatar {
  width: 36px;
  height: 36px;
  border-radius: 50%;
  background: rgba(108, 206, 201, 0.15);
  color: #6ccec9;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 0.8rem;
  font-weight: 600;
  flex-shrink: 0;
}
.ct-avatar--lg {
  width: 56px;
  height: 56px;
  font-size: 1.2rem;
}
.ct-card-body {
  min-width: 0;
  display: flex;
  flex-direction: column;
}
.ct-name {
  font-weight: 500;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.ct-sub {
  font-size: 0.85rem;
  color: var(--text-muted);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.ct-empty,
.ct-placeholder {
  color: var(--text-muted);
  text-align: center;
  padding: 3rem 1rem;
}
.ct-detail-header {
  display: flex;
  align-items: center;
  gap: 1rem;
  margin-bottom: 1.25rem;
}
.ct-detail-name {
  margin: 0;
  font-size: 1.25rem;
}
.ct-detail-sub {
  font-size: 0.9rem;
  color: var(--text-muted);
}
.ct-avatar--photo {
  padding: 0;
  background: none;
}
.ct-avatar--photo img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
  border-radius: 50%;
}
.ct-section-card {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem;
  margin-bottom: 0.75rem;
}
.ct-section-card--muted {
  background: transparent;
  border-color: var(--border);
  opacity: 0.7;
}
.ct-section-title {
  margin: 0 0 0.6rem;
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--text-muted);
}
.ct-info-row {
  display: flex;
  align-items: flex-start;
  gap: 0.6rem;
  padding: 0.45rem 0;
  border-bottom: 1px solid var(--border);
}
.ct-info-row:last-of-type {
  border-bottom: none;
}
.ct-info-icon {
  color: var(--text-muted);
  margin-top: 0.15rem;
  flex-shrink: 0;
}
.ct-info-body {
  display: flex;
  flex-direction: column;
}
.ct-info-type {
  font-size: 0.75rem;
  color: var(--text-muted);
  text-transform: capitalize;
}
.ct-meta-list {
  display: flex;
  flex-direction: column;
}
.ct-meta-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 1rem;
  padding: 0.4rem 0;
  border-bottom: 1px solid var(--border);
  font-size: 0.9rem;
}
.ct-meta-row:last-child {
  border-bottom: none;
}
.ct-meta-key {
  color: var(--text-muted);
  flex-shrink: 0;
}
.ct-link {
  color: var(--primary);
  text-decoration: none;
  word-break: break-all;
}
.ct-link:hover {
  text-decoration: underline;
}
.ct-muted {
  color: var(--text-muted);
  font-size: 0.9rem;
}
.ct-note {
  white-space: pre-wrap;
  font-size: 0.9rem;
  color: var(--text-muted);
}
.ct-mono {
  font-family: monospace;
  font-size: 0.85rem;
}
.ct-detail-footer {
  margin-top: 0.5rem;
  padding-top: 0.75rem;
  border-top: 1px solid var(--border);
  display: flex;
  gap: 1rem;
}
.ct-footer-btn {
  font-size: 0.85rem;
  color: var(--text-muted);
  background: transparent;
  border: 1px solid var(--border);
  padding: 0.4rem 0.75rem;
  border-radius: 8px;
  cursor: pointer;
}
.ct-footer-btn:hover {
  border-color: var(--primary);
  color: var(--text);
}
.ct-footer-btn--link {
  border: none;
  color: var(--primary);
  padding: 0.4rem 0;
}
.ct-footer-btn--link:hover {
  text-decoration: underline;
  background: none;
  color: var(--primary);
}
.ct-add-contact-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 32px;
  height: 32px;
  border-radius: 8px;
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  flex-shrink: 0;
  padding: 0;
}
.ct-add-contact-btn:hover {
  border-color: var(--primary);
  color: var(--primary);
}
.ct-modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.6);
  z-index: 10000;
  display: flex;
  align-items: center;
  justify-content: center;
}
.ct-modal {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 1.5rem;
  width: 100%;
  max-width: 520px;
  max-height: 90vh;
  overflow-y: auto;
}
.ct-modal-title {
  margin: 0 0 1.25rem;
  font-size: 1.15rem;
}
.ct-modal-form {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.ct-modal-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.5rem;
}
.ct-modal-grid:has(:nth-child(3)) {
  grid-template-columns: 1fr 1fr 1fr;
}
.ct-modal-field {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}
.ct-modal-field label {
  font-size: 0.8rem;
  color: var(--text-muted);
}
.ct-modal-section-label {
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--text-muted);
  margin-top: 0.5rem;
}
.ct-modal-row {
  display: flex;
  gap: 0.375rem;
}
.ct-modal-flex {
  flex: 1;
}
.ct-modal-type {
  width: 90px;
}
.ct-modal-error {
  color: var(--danger);
  font-size: 0.85rem;
  margin: 0;
}
.ct-modal-actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
  margin-top: 0.75rem;
}
.ct-modal-btn {
  padding: 0.5rem 1rem;
  border-radius: 8px;
  font-size: 0.9rem;
  font-weight: 500;
  cursor: pointer;
}
.ct-modal-btn--cancel {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text);
}
.ct-modal-btn--cancel:hover {
  border-color: var(--text-muted);
}
.ct-modal-btn--primary {
  background: var(--primary);
  border: 1px solid var(--primary);
  color: #fff;
}
.ct-modal-btn--primary:hover {
  background: var(--primary-hover);
  border-color: var(--primary-hover);
}
.ct-modal-btn--primary:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}
.ct-modal input,
.ct-modal textarea {
  color-scheme: dark;
}
</style>
