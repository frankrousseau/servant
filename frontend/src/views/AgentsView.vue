<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import MarkdownIt from 'markdown-it'
import ComboBox from '../components/ComboBox.vue'
import { useApi } from '../composables/useApi'
import { useConfirm } from '../composables/useConfirm'
import { useAppsStore } from '../stores/apps'
import { formatDate } from '../lib/datetime'
import { Wrench, Play, Pencil, Trash2, Undo2, Plus } from 'lucide-vue-next'
import type { Agent, AgentRun, AiConfig, Entry } from '../types'

const api = useApi()
const { ask } = useConfirm()
const apps = useAppsStore()
const route = useRoute()
const router = useRouter()

// ----- Shared: config banner + tabs -----

const aiConfig = ref<AiConfig | null>(null)

const tab = computed(() =>
  route.query.tab === 'builder' ? 'builder' : 'recurrents'
)

function setTab(t: string) {
  router.replace({ query: { ...route.query, tab: t } })
}

const serverHost = computed(() => {
  try {
    return new URL(aiConfig.value?.base_url || '').hostname
  } catch {
    return ''
  }
})

const localServer = computed(() =>
  ['localhost', '127.0.0.1', '[::1]', '::1'].includes(serverHost.value)
)

async function loadConfig() {
  try {
    aiConfig.value = (await api.get<{ data: AiConfig }>('/api/ai_config')).data
  } catch {
    aiConfig.value = null
  }
}

// ----- Recurring agents -----

const agents = ref<Agent[]>([])
const recurrentRuns = ref<AgentRun[]>([])
const reports = ref<Entry[]>([])
const agentError = ref('')
const runningId = ref('')
const expandedReport = ref('')

// form state (create or edit)
const editingId = ref('')
const formOpen = ref(false)
const fName = ref('')
const fPrompt = ref('')
const fKinds = ref('')
const fLookback = ref(7)
const fSchedule = ref('every_day')
const fSaving = ref(false)

const SCHEDULE_OPTIONS = [
  { value: 'every_hour', label: 'Every hour' },
  { value: 'every_day', label: 'Every day' },
  { value: 'every_week', label: 'Every week' }
]

async function loadAgents() {
  agents.value = (await api.get<{ data: Agent[] }>('/api/agents')).data
}

async function loadRecurrentRuns() {
  recurrentRuns.value = (
    await api.get<{ data: AgentRun[] }>('/api/agents/runs', {
      type: 'recurrent'
    })
  ).data
}

async function loadReports() {
  const res = await api.get<{ data: Entry[] }>('/api/entries', {
    kind: 'ai_report',
    per_page: '200'
  })
  reports.value = res.data
}

function reportsOf(agentId: string) {
  return reports.value.filter(r => r.metadata?.agent_id === agentId)
}

function reportContent(r: Entry): string {
  return typeof r.data.content === 'string' ? r.data.content : ''
}

// html: false (the default) escapes any HTML the model emits, so v-html below
// only ever injects markup produced by markdown-it itself.
const md = new MarkdownIt({ breaks: true, linkify: true })
const rawReport = ref(false)

function reportHtml(r: Entry): string {
  return md.render(reportContent(r))
}

function lastRunOf(agentId: string) {
  return recurrentRuns.value.find(r => r.agent_id === agentId) || null
}

function agentName(agentId: string | null) {
  return agents.value.find(a => a.id === agentId)?.name || '-'
}

function scheduleLabel(schedule: string) {
  return SCHEDULE_OPTIONS.find(o => o.value === schedule)?.label || schedule
}

function openCreate() {
  editingId.value = ''
  fName.value = ''
  fPrompt.value = ''
  fKinds.value = ''
  fLookback.value = 7
  fSchedule.value = 'every_day'
  formOpen.value = true
}

function openEdit(a: Agent) {
  editingId.value = a.id
  fName.value = a.name
  fPrompt.value = a.prompt
  fKinds.value = a.kinds.join(', ')
  fLookback.value = a.lookback_days
  fSchedule.value = a.schedule
  formOpen.value = true
}

async function saveAgent() {
  agentError.value = ''
  fSaving.value = true
  const body = {
    name: fName.value.trim(),
    prompt: fPrompt.value.trim(),
    kinds: fKinds.value
      .split(',')
      .map(k => k.trim())
      .filter(Boolean),
    lookback_days: fLookback.value,
    schedule: fSchedule.value
  }
  try {
    if (editingId.value) await api.put(`/api/agents/${editingId.value}`, body)
    else await api.post('/api/agents', body)
    formOpen.value = false
    await loadAgents()
  } catch (e) {
    agentError.value = e instanceof Error ? e.message : 'Save failed'
  } finally {
    fSaving.value = false
  }
}

async function toggleAgent(a: Agent) {
  try {
    await api.put(`/api/agents/${a.id}`, { enabled: !a.enabled })
    await loadAgents()
  } catch (e) {
    agentError.value = e instanceof Error ? e.message : 'Save failed'
  }
}

async function deleteAgent(a: Agent) {
  const ok = await ask({
    title: 'Delete agent',
    message: `Delete "${a.name}"? Its past reports are kept (visible in the Data browser).`,
    danger: true
  })
  if (!ok) return
  await api.del(`/api/agents/${a.id}`)
  await loadAgents()
}

async function runNow(a: Agent) {
  agentError.value = ''
  runningId.value = a.id
  try {
    const res = await api.post<{ data: AgentRun }>(`/api/agents/${a.id}/run`)
    const run = await pollRun(res.data.id)
    if (run.status === 'error') agentError.value = run.error || 'Run failed'
    await Promise.all([loadAgents(), loadRecurrentRuns(), loadReports()])
  } catch (e) {
    agentError.value = e instanceof Error ? e.message : 'Run failed'
  } finally {
    runningId.value = ''
  }
}

// ----- Shared polling (builder + recurring) -----

async function pollRun(id: string): Promise<AgentRun> {
  for (;;) {
    const run = (await api.get<{ data: AgentRun }>(`/api/agents/runs/${id}`))
      .data
    if (run.status !== 'running') return run
    await new Promise(resolve => setTimeout(resolve, 2000))
  }
}

// ----- Builder tab (moved from SettingsView) -----

const genName = ref('')
const genDescription = ref('')
const genBusy = ref(false)
const genError = ref('')
const modifyingId = ref('')
const modifyInstruction = ref('')
const restoringId = ref('')

const builderRuns = ref<AgentRun[]>([])
const generatedApps = computed(() => apps.installed.filter(a => a.generated))

async function loadBuilderRuns() {
  builderRuns.value = (
    await api.get<{ data: AgentRun[] }>('/api/agents/runs', { type: 'builder' })
  ).data
}

async function generateApp() {
  genError.value = ''
  genBusy.value = true
  try {
    const runId = await apps.generate(
      genName.value.trim(),
      genDescription.value.trim()
    )
    const run = await pollRun(runId)
    if (run.status === 'ok') {
      genName.value = ''
      genDescription.value = ''
      await apps.load(true)
    } else {
      genError.value = run.error || 'Generation failed'
    }
    await loadBuilderRuns()
  } catch (e) {
    genError.value = e instanceof Error ? e.message : 'Generation failed'
  } finally {
    genBusy.value = false
  }
}

async function modifyApp(id: string) {
  genError.value = ''
  genBusy.value = true
  try {
    const runId = await apps.modify(id, modifyInstruction.value.trim())
    const run = await pollRun(runId)
    if (run.status === 'ok') {
      modifyingId.value = ''
      modifyInstruction.value = ''
      await apps.load(true)
    } else {
      genError.value = run.error || 'Modification failed'
    }
    await loadBuilderRuns()
  } catch (e) {
    genError.value = e instanceof Error ? e.message : 'Modification failed'
  } finally {
    genBusy.value = false
  }
}

async function restoreApp(id: string) {
  genError.value = ''
  restoringId.value = id
  try {
    await apps.restore(id)
  } catch (e) {
    genError.value = e instanceof Error ? e.message : 'Restore failed'
  } finally {
    restoringId.value = ''
  }
}

async function uninstallGenerated(id: string, name: string) {
  const ok = await ask({
    title: 'Uninstall app',
    message: `Uninstall "${name}"? Its files will be removed.`,
    danger: true
  })
  if (!ok) return
  await apps.uninstall(id)
}

onMounted(() => {
  loadConfig()
  apps.load().catch(() => {})
  loadAgents().catch(() => {})
  loadRecurrentRuns().catch(() => {})
  loadReports().catch(() => {})
  loadBuilderRuns().catch(() => {})
})
</script>

<template>
  <div class="view">
    <h1><Wrench :size="22" />Agents</h1>

    <p v-if="aiConfig && !aiConfig.enabled" class="agents-disabled">
      Agents are disabled.
      <router-link to="/settings">Enable them in Settings</router-link> and
      configure a model server first.
    </p>

    <template v-else-if="aiConfig">
      <p class="tk-hint">
        Runs on {{ aiConfig.model }} at {{ aiConfig.base_url }}.
        <template v-if="!localServer">
          This server is not local: these agents send the selected entries to
          {{ serverHost }}.
        </template>
        Reports can be wrong or incomplete: check the numbers before acting on
        them.
      </p>

      <div class="tabs" role="tablist">
        <button
          role="tab"
          :aria-selected="tab === 'recurrents'"
          :class="{ active: tab === 'recurrents' }"
          @click="setTab('recurrents')"
        >
          Recurring
        </button>
        <button
          role="tab"
          :aria-selected="tab === 'builder'"
          :class="{ active: tab === 'builder' }"
          @click="setTab('builder')"
        >
          Builder
        </button>
      </div>

      <!-- Recurring tab -->
      <template v-if="tab === 'recurrents'">
        <section class="card">
          <div class="card-body">
            <div class="agents-head">
              <h3 class="app-subhead">Your agents</h3>
              <button type="button" @click="openCreate">
                <Plus :size="14" /> New agent
              </button>
            </div>
            <p class="tk-hint">
              Each agent gathers your entries of the given kinds from the last
              lookback window and asks the model for a report.
            </p>

            <table v-if="agents.length" class="tk-table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Kinds</th>
                  <th>Schedule</th>
                  <th>Enabled</th>
                  <th>Last run</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="a in agents" :key="a.id">
                  <td>{{ a.name }}</td>
                  <td>{{ a.kinds.join(', ') }}</td>
                  <td>{{ scheduleLabel(a.schedule) }}</td>
                  <td>
                    <label class="toggle">
                      <input
                        type="checkbox"
                        :checked="a.enabled"
                        @change="toggleAgent(a)"
                      />
                    </label>
                  </td>
                  <td>
                    <template v-if="lastRunOf(a.id)">
                      {{ formatDate(lastRunOf(a.id)!.inserted_at) }} -
                      {{ lastRunOf(a.id)!.status }}
                    </template>
                    <template v-else-if="a.last_run_at">
                      {{ formatDate(a.last_run_at) }}
                    </template>
                    <template v-else>never</template>
                  </td>
                  <td class="app-actions">
                    <button
                      type="button"
                      class="tk-revoke"
                      title="Run now"
                      :disabled="runningId === a.id"
                      @click="runNow(a)"
                    >
                      <Play :size="14" />
                    </button>
                    <button
                      type="button"
                      class="tk-revoke"
                      title="Edit"
                      @click="openEdit(a)"
                    >
                      <Pencil :size="14" />
                    </button>
                    <button
                      type="button"
                      class="tk-revoke"
                      title="Delete"
                      @click="deleteAgent(a)"
                    >
                      <Trash2 :size="14" />
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
            <p v-else class="tk-empty">No agents yet.</p>

            <form v-if="formOpen" class="app-form" @submit.prevent="saveAgent">
              <input v-model="fName" type="text" placeholder="Agent name" />
              <textarea
                v-model="fPrompt"
                rows="3"
                placeholder="What should the agent look for or summarize?"
              ></textarea>
              <input
                v-model="fKinds"
                type="text"
                placeholder="bank_tx, transaction"
              />
              <p class="tk-hint">Comma-separated entry kinds, e.g. bank_tx</p>
              <label class="tk-expiry">
                <span class="tk-domain-label">Lookback (days)</span>
                <input
                  v-model.number="fLookback"
                  type="number"
                  min="1"
                  max="365"
                />
              </label>
              <label class="tk-expiry">
                <span class="tk-domain-label">Schedule</span>
                <ComboBox
                  class="tk-domain-select"
                  :model-value="fSchedule"
                  :options="SCHEDULE_OPTIONS"
                  @update:model-value="v => (fSchedule = v)"
                />
              </label>
              <p v-if="agentError" class="msg msg-error">{{ agentError }}</p>
              <div class="card-actions">
                <button
                  type="submit"
                  :disabled="
                    fSaving ||
                    !fName.trim() ||
                    !fPrompt.trim() ||
                    !fKinds.trim()
                  "
                >
                  {{ fSaving ? 'Saving...' : 'Save' }}
                </button>
                <button type="button" @click="formOpen = false">Cancel</button>
              </div>
            </form>
          </div>
        </section>

        <section v-if="agents.length" class="card">
          <div class="card-body">
            <h3 class="app-subhead">Reports</h3>
            <template v-for="a in agents" :key="a.id">
              <template v-if="reportsOf(a.id).length">
                <p class="report-agent-name">{{ a.name }}</p>
                <div
                  v-for="r in reportsOf(a.id)"
                  :key="r.id"
                  class="report-item"
                >
                  <button
                    type="button"
                    class="report-toggle"
                    @click="
                      expandedReport = expandedReport === r.id ? '' : r.id
                    "
                  >
                    {{ r.title || 'Report' }} -
                    {{ formatDate(r.occurred_at || r.inserted_at) }}
                  </button>
                  <template v-if="expandedReport === r.id">
                    <div class="report-view-tabs">
                      <button
                        type="button"
                        :class="{ active: !rawReport }"
                        @click="rawReport = false"
                      >
                        Rendered
                      </button>
                      <button
                        type="button"
                        :class="{ active: rawReport }"
                        @click="rawReport = true"
                      >
                        Markdown
                      </button>
                    </div>
                    <pre v-if="rawReport" class="report-content">{{
                      reportContent(r)
                    }}</pre>
                    <div
                      v-else
                      class="report-content report-rendered"
                      v-html="reportHtml(r)"
                    ></div>
                  </template>
                </div>
              </template>
            </template>
            <p
              v-if="!agents.some(a => reportsOf(a.id).length)"
              class="tk-empty"
            >
              No reports yet.
            </p>
          </div>
        </section>

        <section class="card">
          <div class="card-body">
            <h3 class="app-subhead">Recent runs</h3>
            <table v-if="recurrentRuns.length" class="tk-table">
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Agent</th>
                  <th>Model</th>
                  <th>Tokens</th>
                  <th>Duration</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="r in recurrentRuns" :key="r.id">
                  <td>{{ formatDate(r.inserted_at) }}</td>
                  <td>{{ agentName(r.agent_id) }}</td>
                  <td>{{ r.model }}</td>
                  <td>
                    {{
                      r.input_tokens != null
                        ? `${r.input_tokens} in / ${r.output_tokens} out`
                        : '-'
                    }}
                  </td>
                  <td>
                    {{
                      r.duration_ms != null
                        ? `${Math.round(r.duration_ms / 1000)}s`
                        : '-'
                    }}
                  </td>
                  <td>
                    {{ r.status }}
                    <div v-if="r.error" class="run-error" :title="r.error">
                      {{ r.error }}
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
            <p v-else class="tk-empty">No runs yet.</p>
          </div>
        </section>
      </template>

      <!-- Builder tab -->
      <template v-else>
        <section class="card">
          <div class="card-body">
            <h3 class="app-subhead">Generate an app</h3>
            <p class="tk-hint">
              Describe the app; the configured model writes it and it installs
              like any other app. Review it before trusting it with your data.
            </p>
            <form class="app-form" @submit.prevent="generateApp">
              <input v-model="genName" type="text" placeholder="App name" />
              <textarea
                v-model="genDescription"
                rows="3"
                placeholder="What should the app do?"
              ></textarea>
              <p v-if="genError" class="msg msg-error">{{ genError }}</p>
              <div class="card-actions">
                <button
                  type="submit"
                  :disabled="
                    genBusy || !genName.trim() || !genDescription.trim()
                  "
                >
                  {{
                    genBusy
                      ? `Generating with ${aiConfig.model}...`
                      : `Generate (runs on ${aiConfig.model})`
                  }}
                </button>
              </div>
            </form>
          </div>
        </section>

        <section class="card">
          <div class="card-body">
            <h3 class="app-subhead">Generated apps</h3>

            <table v-if="generatedApps.length" class="tk-table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <template v-for="a in generatedApps" :key="a.id">
                  <tr>
                    <td>{{ a.name }}</td>
                    <td class="app-actions">
                      <button
                        type="button"
                        class="tk-revoke"
                        title="Modify with the configured model"
                        :disabled="genBusy"
                        @click="modifyingId = modifyingId === a.id ? '' : a.id"
                      >
                        <Pencil :size="14" />
                      </button>
                      <button
                        v-if="a.has_previous"
                        type="button"
                        class="tk-revoke"
                        title="Restore the previous version"
                        :disabled="restoringId === a.id"
                        @click="restoreApp(a.id)"
                      >
                        <Undo2 :size="14" />
                      </button>
                      <button
                        type="button"
                        class="tk-revoke"
                        title="Uninstall"
                        @click="uninstallGenerated(a.id, a.name)"
                      >
                        <Trash2 :size="14" />
                      </button>
                    </td>
                  </tr>
                  <tr v-if="modifyingId === a.id">
                    <td colspan="2">
                      <form class="app-form" @submit.prevent="modifyApp(a.id)">
                        <textarea
                          v-model="modifyInstruction"
                          rows="3"
                          placeholder="Describe the change"
                        ></textarea>
                        <div class="card-actions">
                          <button
                            type="submit"
                            :disabled="genBusy || !modifyInstruction.trim()"
                          >
                            {{
                              genBusy
                                ? `Running on ${aiConfig.model}...`
                                : `Modify (runs on ${aiConfig.model})`
                            }}
                          </button>
                        </div>
                      </form>
                    </td>
                  </tr>
                </template>
              </tbody>
            </table>
            <p v-else class="tk-empty">No generated apps yet.</p>
          </div>
        </section>

        <section class="card">
          <div class="card-body">
            <h3 class="app-subhead">Recent runs</h3>
            <table v-if="builderRuns.length" class="tk-table">
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Action</th>
                  <th>App</th>
                  <th>Model</th>
                  <th>Tokens</th>
                  <th>Duration</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="r in builderRuns" :key="r.id">
                  <td>{{ formatDate(r.inserted_at) }}</td>
                  <td>{{ r.action }}</td>
                  <td>{{ r.app_id || '-' }}</td>
                  <td>{{ r.model }}</td>
                  <td>
                    {{
                      r.input_tokens != null
                        ? `${r.input_tokens} in / ${r.output_tokens} out`
                        : '-'
                    }}
                  </td>
                  <td>
                    {{
                      r.duration_ms != null
                        ? `${Math.round(r.duration_ms / 1000)}s`
                        : '-'
                    }}
                  </td>
                  <td>
                    {{ r.status }}
                    <div v-if="r.error" class="run-error" :title="r.error">
                      {{ r.error }}
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
            <p v-else class="tk-empty">No runs yet.</p>
          </div>
        </section>
      </template>
    </template>
  </div>
</template>

<style scoped>
.view h1 {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.card {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  margin-bottom: 1rem;
  overflow: hidden;
}

.card-body {
  padding: 1.25rem;
}

.card-actions {
  padding-top: 0.5rem;
  display: flex;
  gap: 0.5rem;
}

.app-subhead {
  font-size: 0.85rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-muted);
  margin: 0 0 0.35rem;
}

.agents-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 0.35rem;
}

.app-actions {
  white-space: nowrap;
}
.app-actions .tk-revoke {
  margin-left: 0.35rem;
}

.app-form input[type='text'],
.app-form textarea,
.app-form input[type='number'] {
  width: 100%;
  margin-bottom: 0.75rem;
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
.tk-domain-label {
  font-size: 0.8rem;
  color: var(--text-muted);
}
.tk-domain-select {
  width: 150px;
  flex-shrink: 0;
}

.tk-hint {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.8rem;
  color: var(--text-muted);
  margin: 0 0 1rem;
}
.tk-hint a {
  color: var(--primary);
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

.run-error {
  color: var(--danger);
  font-size: 0.8rem;
  max-width: 26rem;
  white-space: normal;
  word-break: break-word;
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.report-agent-name {
  font-size: 0.85rem;
  color: var(--text);
  margin: 0.75rem 0 0.35rem;
}
.report-agent-name:first-child {
  margin-top: 0;
}
.report-item {
  margin-bottom: 0.5rem;
}
.report-toggle {
  background: transparent;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-muted);
  padding: 0.4rem 0.65rem;
  font-size: 0.85rem;
  cursor: pointer;
  width: 100%;
  text-align: left;
}
.report-toggle:hover {
  border-color: var(--primary);
  color: var(--text);
}

.tabs {
  display: flex;
  gap: 0.5rem;
  margin-bottom: 1rem;
}
.tabs button {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-muted);
  padding: 0.45rem 1rem;
  cursor: pointer;
}
.tabs button.active {
  color: var(--text);
  border-color: var(--primary);
}
.agents-disabled {
  color: var(--text-muted);
}
.report-content {
  white-space: pre-wrap;
  font-size: 0.85rem;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 0.75rem 1rem;
}
.report-view-tabs {
  display: flex;
  gap: 0.25rem;
  margin: 0.35rem 0;
}
.report-view-tabs button {
  background: transparent;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-muted);
  font-size: 0.75rem;
  padding: 0.15rem 0.6rem;
  cursor: pointer;
}
.report-view-tabs button.active {
  color: var(--text);
  border-color: var(--primary);
}
.report-rendered {
  white-space: normal;
  font-size: 0.9rem;
}
.report-rendered :deep(h1),
.report-rendered :deep(h2),
.report-rendered :deep(h3),
.report-rendered :deep(h4) {
  font-size: 1rem;
  margin: 0.75rem 0 0.35rem;
}
.report-rendered :deep(p),
.report-rendered :deep(ul),
.report-rendered :deep(ol) {
  margin: 0.5rem 0;
}
.report-rendered :deep(ul),
.report-rendered :deep(ol) {
  padding-left: 1.25rem;
}
.report-rendered :deep(table) {
  border-collapse: collapse;
  margin: 0.5rem 0;
}
.report-rendered :deep(th),
.report-rendered :deep(td) {
  border: 1px solid var(--border);
  padding: 0.25rem 0.5rem;
}
</style>
