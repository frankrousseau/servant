<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'

import ComboBox from '../components/ComboBox.vue'

import {
  connectorSchedules,
  createConnector,
  listConnectors
} from '../api/connectors'
import type { ConnectorConfig, Schedule } from '../types'
import { relativeTime } from '../lib/datetime'
import { SCHEDULE_LABELS } from '../lib/connectors'
import { CONNECTOR_DEFS, getConnectorDef } from '../connectors'
import type { ConnectorDef } from '../connectors'

const router = useRouter()

const connectors = ref<ConnectorConfig[]>([])
const loading = ref(true)

// Setup modal
const setupDef = ref<ConnectorDef | null>(null)
const setupName = ref('')
const setupSchedule = ref<Schedule>('every_hour')
const supportedSchedules = ref<Schedule[]>([])
const setupConfig = ref<Record<string, string>>({})

const scheduleOptions = computed(() =>
  supportedSchedules.value.map(s => ({ value: s, label: SCHEDULE_LABELS[s] }))
)

function onSetupScheduleChange(v: string) {
  setupSchedule.value = v as Schedule
}
const saving = ref(false)

// Catalog search, grouped by category (alphabetical, connectors within too)
const catalogSearch = ref('')
const catalogGroups = computed(() => {
  const q = catalogSearch.value.toLowerCase().trim()
  const defs = [...CONNECTOR_DEFS]
    .sort((a, b) => a.name.localeCompare(b.name))
    .filter(
      d =>
        !q ||
        d.name.toLowerCase().includes(q) ||
        d.category.toLowerCase().includes(q)
    )

  const groups = new Map<string, ConnectorDef[]>()
  for (const def of defs) {
    const group = groups.get(def.category)
    if (group) group.push(def)
    else groups.set(def.category, [def])
  }
  return [...groups.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([category, items]) => ({ category, items }))
})

async function fetchConnectors() {
  loading.value = true
  try {
    connectors.value = await listConnectors()
  } catch {
    connectors.value = []
  } finally {
    loading.value = false
  }
}

function openSetup(def: ConnectorDef) {
  setupDef.value = def
  setupName.value = ''
  setupConfig.value = {}
  def.configFields.forEach(f => {
    if (f.type === 'select' && f.options?.length) {
      setupConfig.value[f.key] = f.options[0].value
    } else {
      setupConfig.value[f.key] = ''
    }
  })
  // Load supported schedules
  loadSchedules(def.id)
}

function closeSetup() {
  setupDef.value = null
}

async function loadSchedules(type: string) {
  try {
    const data = await connectorSchedules(type)
    supportedSchedules.value = data.schedules
    setupSchedule.value = data.default
  } catch {
    supportedSchedules.value = Object.keys(SCHEDULE_LABELS) as Schedule[]
    setupSchedule.value = 'every_hour'
  }
}

async function submitSetup() {
  if (!setupDef.value) return
  saving.value = true
  try {
    // Build config from hint + form fields
    const config: Record<string, unknown> = {
      ...setupDef.value.configHint
    }
    setupDef.value.configFields.forEach(f => {
      const val = setupConfig.value[f.key]?.trim()
      if (val) {
        config[f.key] = f.type === 'number' ? Number(val) : val
      }
    })

    await createConnector({
      connector_type: setupDef.value.id,
      name: setupName.value || null,
      config,
      schedule: setupSchedule.value,
      enabled: true
    })
    closeSetup()
    await fetchConnectors()
  } catch {
    // handle error
  } finally {
    saving.value = false
  }
}

onMounted(fetchConnectors)
</script>

<template>
  <div class="sources-layout">
    <p v-if="loading" class="text-muted" style="padding: 2rem">Loading...</p>

    <template v-else>
      <!-- Left: Active connectors -->
      <div class="sources-col">
        <h2 class="section-title">Active</h2>
        <div v-if="connectors.length" class="active-grid">
          <div
            v-for="c in connectors"
            :key="c.id"
            class="active-card"
            :class="{ 'has-error': c.error }"
            @click="router.push(`/connectors/${c.id}`)"
            v-click-key
            role="button"
            tabindex="0"
          >
            <div
              class="active-logo"
              v-html="getConnectorDef(c.connector_type)?.logo || ''"
            ></div>
            <div class="active-body">
              <div class="active-name-row">
                <span class="active-name">
                  {{
                    c.name ||
                    getConnectorDef(c.connector_type)?.name ||
                    c.connector_type
                  }}
                </span>
                <span
                  class="status-dot"
                  :class="{
                    active: c.enabled && !c.error,
                    error: !!c.error
                  }"
                ></span>
              </div>
              <span class="active-meta">
                {{ SCHEDULE_LABELS[c.schedule] }}
                <template v-if="c.last_synced_at">
                  &middot; {{ relativeTime(c.last_synced_at) }}
                </template>
              </span>
              <span v-if="c.error" class="active-error">{{ c.error }}</span>
            </div>
            <span class="active-arrow">&rsaquo;</span>
          </div>
        </div>
        <p v-else class="text-muted">No active sources yet.</p>
      </div>

      <!-- Right: Add a source -->
      <div class="sources-col">
        <h2 class="section-title">Add a Source</h2>
        <input
          v-model="catalogSearch"
          type="text"
          class="catalog-search"
          placeholder="Search sources..."
        />
        <div
          v-for="group in catalogGroups"
          :key="group.category"
          class="catalog-group"
        >
          <h3 class="catalog-group-title">{{ group.category }}</h3>
          <div class="catalog-grid">
            <div
              v-for="def in group.items"
              :key="def.id"
              class="catalog-card"
              @click="openSetup(def)"
              v-click-key
              role="button"
              tabindex="0"
            >
              <div class="catalog-logo" v-html="def.logo"></div>
              <div class="catalog-body">
                <span class="catalog-name">{{ def.name }}</span>
                <span class="catalog-desc">{{ def.description }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </template>

    <!-- Setup modal -->
    <div v-if="setupDef" class="modal-overlay" @click.self="closeSetup">
      <div class="setup-modal">
        <div class="setup-header">
          <div class="setup-logo" v-html="setupDef.logo"></div>
          <div>
            <h2>{{ setupDef.name }}</h2>
            <p class="setup-desc">{{ setupDef.description }}</p>
          </div>
        </div>

        <form @submit.prevent="submitSetup">
          <div class="field">
            <label>
              Name
              <span class="field-optional">optional</span>
            </label>
            <input
              v-model="setupName"
              type="text"
              :placeholder="setupDef.name"
            />
          </div>
          <div
            v-for="field in setupDef.configFields"
            :key="field.key"
            class="field"
          >
            <label>
              {{ field.label }}
              <span v-if="!field.required" class="field-optional"
                >optional</span
              >
            </label>
            <ComboBox
              v-if="field.type === 'select' && field.options"
              v-model="setupConfig[field.key]"
              :options="field.options"
            />
            <textarea
              v-else-if="field.type === 'textarea'"
              v-model="setupConfig[field.key]"
              class="field-textarea"
              rows="5"
              :placeholder="field.placeholder"
              :required="field.required"
              spellcheck="false"
            ></textarea>
            <input
              v-else
              v-model="setupConfig[field.key]"
              :type="field.type"
              :placeholder="field.placeholder"
              :required="field.required"
            />
          </div>

          <div class="field">
            <label>Sync frequency</label>
            <ComboBox
              :model-value="setupSchedule"
              :options="scheduleOptions"
              @update:model-value="onSetupScheduleChange"
            />
          </div>

          <div class="setup-actions">
            <button type="button" class="btn-secondary" @click="closeSetup">
              Cancel
            </button>
            <button type="submit" :disabled="saving">
              {{ saving ? 'Adding...' : 'Add Source' }}
            </button>
          </div>
        </form>
      </div>
    </div>
  </div>
</template>

<style scoped>
.sources-layout {
  display: flex;
  gap: 1.5rem;
  height: calc(100vh - 4rem);
}

.sources-col {
  flex: 1;
  min-width: 0;
  overflow-y: auto;
  padding-right: 0.5rem;
}

.section-title {
  font-size: 0.9rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.06em;
  margin: 0 0 0.75rem;
  position: sticky;
  top: 0;
  background: var(--bg);
  padding: 0.5rem 0;
  z-index: 1;
}

/* Active connectors */
.active-grid {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.active-card {
  display: flex;
  align-items: center;
  gap: 1rem;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 0.85rem 1rem;
  cursor: pointer;
  transition:
    border-color 0.15s,
    box-shadow 0.15s;
}

.active-card:hover {
  border-color: var(--primary);
  box-shadow: 0 0 0 1px var(--primary);
}

.active-card.has-error {
  border-color: var(--danger);
}

.active-logo {
  width: 40px;
  height: 40px;
  flex-shrink: 0;
  border-radius: 8px;
  overflow: hidden;
  background: #000;
}

.active-logo :deep(svg),
.active-logo :deep(img) {
  width: 100%;
  height: 100%;
  display: block;
}

.active-body {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
}

.active-name-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.active-name {
  font-weight: 600;
}

.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--text-muted);
  flex-shrink: 0;
}

.status-dot.active {
  background: var(--success);
}

.status-dot.error {
  background: var(--danger);
}

.active-meta {
  font-size: 0.9rem;
  color: var(--text-muted);
}

.active-error {
  font-size: 0.9rem;
  color: var(--danger);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.active-arrow {
  font-size: 1.5rem;
  color: var(--text-muted);
  flex-shrink: 0;
  line-height: 1;
}

.catalog-search {
  margin-bottom: 0.75rem;
}

/* Catalog (available), grouped by category */
.catalog-group {
  margin-bottom: 1.25rem;
}

.catalog-group-title {
  font-size: 0.8rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  margin: 0 0 0.5rem;
}

.catalog-grid {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.catalog-card {
  display: flex;
  align-items: flex-start;
  gap: 0.85rem;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 1rem;
  cursor: pointer;
  transition:
    border-color 0.15s,
    box-shadow 0.15s;
  position: relative;
}

.catalog-card:hover {
  border-color: var(--primary);
  box-shadow: 0 0 0 1px var(--primary);
}

.catalog-logo {
  width: 44px;
  height: 44px;
  flex-shrink: 0;
  border-radius: 10px;
  overflow: hidden;
  background: #000;
}

.catalog-logo :deep(svg),
.catalog-logo :deep(img) {
  width: 100%;
  height: 100%;
  display: block;
}

.catalog-body {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.catalog-name {
  font-weight: 600;
}

.catalog-desc {
  font-size: 0.9rem;
  color: var(--text-muted);
  line-height: 1.35;
}

/* Setup modal */
.setup-modal {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 1.5rem;
  width: 100%;
  max-width: 460px;
}

.setup-header {
  display: flex;
  gap: 1rem;
  align-items: flex-start;
  margin-bottom: 1.25rem;
}

.setup-header h2 {
  margin: 0;
}

.setup-logo {
  width: 48px;
  height: 48px;
  flex-shrink: 0;
  border-radius: 10px;
  overflow: hidden;
  background: #000;
}

.setup-logo :deep(svg),
.setup-logo :deep(img) {
  width: 100%;
  height: 100%;
  display: block;
}

.setup-desc {
  font-size: 0.9rem;
  color: var(--text-muted);
  margin: 0.25rem 0 0;
}

.field-optional {
  font-size: 0.8rem;
  color: var(--text-muted);
  font-weight: 400;
  margin-left: 0.35rem;
}

/* PEM keys and other multiline secrets */
.field-textarea {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.8rem;
  resize: vertical;
}

.setup-actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
  margin-top: 1.25rem;
}

.btn-secondary {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text);
}

.btn-secondary:hover {
  border-color: var(--text-muted);
}

.text-muted {
  color: var(--text-muted);
}
</style>
