<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { Pencil, Play, Plus, Trash2, Undo2, Wrench } from 'lucide-vue-next'

import ComboBox from '../components/ComboBox.vue'

import { listEntriesPage } from '../api/entries'
import { useApi } from '../composables/useApi'
import { useConfirm } from '../composables/useConfirm'
import { formatDate } from '../lib/datetime'
import { renderMarkdown } from '../lib/markdown'
import { useAppsStore } from '../stores/apps'
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

function setTab(next: string) {
  router.replace({ query: { ...route.query, tab: next } })
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
const fModel = ref('')
const fHour = ref<number | ''>('')
const fSaving = ref(false)
const fMode = ref<'prompt' | 'recipe'>('prompt')
const fDescription = ref('')
const fRecipeJson = ref('')
const drafting = ref(false)

const SCHEDULE_OPTIONS = [
  { value: 'every_hour', label: 'Every hour' },
  { value: 'every_day', label: 'Every day' },
  { value: 'every_week', label: 'Every week' }
]

const MODE_OPTIONS = [
  { value: 'prompt', label: 'Prompt (the model writes the report)' },
  { value: 'recipe', label: 'Recipe (deterministic, no model at run time)' }
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

const REPORTS_PER_PAGE = 20
const reportQuery = ref('')
const reportPage = ref(1)
const reportTotal = ref(0)
let reportSearchTimer: ReturnType<typeof setTimeout> | undefined

// The two report kinds (ai_report from a prompt agent, report from a recipe
// agent) carry source "agent". As a result, one paginated query covers them,
// newest first.
async function loadReports(opts: { append?: boolean } = {}) {
  // A plain reload (after a run, on mount) starts again at the first page.
  // As a result, the list cannot show page 3 alone.
  if (!opts.append) reportPage.value = 1

  const params: Record<string, string> = {
    source: 'agent',
    page: String(reportPage.value),
    per_page: String(REPORTS_PER_PAGE)
  }
  const needle = reportQuery.value.trim()
  if (needle) params.q = needle

  const res = await listEntriesPage(params)
  reportTotal.value = res.meta.total
  reports.value = opts.append ? [...reports.value, ...res.data] : res.data
}

// A search starts again at the first page. A request must not fire for each
// key that the user types.
function onReportSearch() {
  clearTimeout(reportSearchTimer)
  reportSearchTimer = setTimeout(() => void loadReports(), 300)
}

async function loadMoreReports() {
  reportPage.value += 1
  await loadReports({ append: true })
}

function reportsOf(agentId: string) {
  return reports.value.filter(report => report.metadata?.agent_id === agentId)
}

function reportContent(report: Entry): string {
  return typeof report.data.content === 'string' ? report.data.content : ''
}

const rawReport = ref(false)

// The renderer escapes the HTML of the model. As a result, v-html below only
// injects markup that markdown-it produced itself (see lib/markdown.ts).
function reportHtml(report: Entry): string {
  return renderMarkdown(reportContent(report))
}

function lastRunOf(agentId: string) {
  return recurrentRuns.value.find(run => run.agent_id === agentId) || null
}

function agentName(agentId: string | null) {
  return agents.value.find(agent => agent.id === agentId)?.name || '-'
}

function scheduleLabel(schedule: string) {
  return (
    SCHEDULE_OPTIONS.find(option => option.value === schedule)?.label ||
    schedule
  )
}

function openCreate() {
  editingId.value = ''
  fName.value = ''
  fPrompt.value = ''
  fKinds.value = ''
  fLookback.value = 7
  fSchedule.value = 'every_day'
  fModel.value = ''
  fHour.value = ''
  fMode.value = 'prompt'
  fDescription.value = ''
  fRecipeJson.value = ''
  formOpen.value = true
}

function openEdit(agent: Agent) {
  editingId.value = agent.id
  fName.value = agent.name
  fPrompt.value = agent.prompt || ''
  fKinds.value = agent.kinds.join(', ')
  fLookback.value = agent.lookback_days
  fSchedule.value = agent.schedule
  fModel.value = agent.model || ''
  fHour.value = agent.run_at_hour ?? ''
  fMode.value = agent.mode
  fDescription.value = ''
  fRecipeJson.value =
    agent.mode === 'recipe' && agent.recipe
      ? JSON.stringify(agent.recipe, null, 2)
      : ''
  formOpen.value = true
}

async function saveAgent() {
  agentError.value = ''
  fSaving.value = true
  const body: Record<string, unknown> = {
    name: fName.value.trim(),
    mode: fMode.value,
    kinds: fKinds.value
      .split(',')
      .map(kind => kind.trim())
      .filter(Boolean),
    lookback_days: fLookback.value,
    schedule: fSchedule.value,
    // An empty value (or an hourly schedule, where it means nothing) leaves
    // the agent on the interval-since-last-run rule.
    run_at_hour:
      fHour.value === '' || fSchedule.value === 'every_hour'
        ? null
        : Number(fHour.value)
  }
  if (fMode.value === 'recipe') {
    try {
      body.recipe = JSON.parse(fRecipeJson.value)
    } catch {
      agentError.value = 'Recipe is not valid JSON'
      fSaving.value = false
      return
    }
  } else {
    body.prompt = fPrompt.value.trim()
    // An empty value means "the model from Settings": the backend sets it to nil.
    body.model = fModel.value.trim()
  }
  try {
    if (editingId.value) await api.put(`/api/agents/${editingId.value}`, body)
    else await api.post('/api/agents', body)
    formOpen.value = false
    await loadAgents()
  } catch (err) {
    agentError.value = err instanceof Error ? err.message : 'Save failed'
  } finally {
    fSaving.value = false
  }
}

async function draftRecipe() {
  agentError.value = ''
  drafting.value = true
  try {
    const res = await api.post<{
      data: { recipe: Record<string, unknown>; run_id: string }
    }>('/api/agents/draft_recipe', {
      description: fDescription.value.trim(),
      kinds: fKinds.value
        .split(',')
        .map(kind => kind.trim())
        .filter(Boolean)
    })
    fRecipeJson.value = JSON.stringify(res.data.recipe, null, 2)
    await loadRecurrentRuns()
  } catch (err) {
    agentError.value = err instanceof Error ? err.message : 'Draft failed'
  } finally {
    drafting.value = false
  }
}

async function toggleAgent(agent: Agent) {
  try {
    await api.put(`/api/agents/${agent.id}`, { enabled: !agent.enabled })
    await loadAgents()
  } catch (err) {
    agentError.value = err instanceof Error ? err.message : 'Save failed'
  }
}

async function deleteAgent(agent: Agent) {
  const ok = await ask({
    title: 'Delete agent',
    message: `Delete "${agent.name}"? Its past reports are kept (visible in the Data browser).`,
    danger: true
  })
  if (!ok) return
  await api.del(`/api/agents/${agent.id}`)
  await loadAgents()
}

async function runNow(agent: Agent) {
  agentError.value = ''
  runningId.value = agent.id
  try {
    const res = await api.post<{ data: AgentRun }>(
      `/api/agents/${agent.id}/run`
    )
    const run = await pollRun(res.data.id)
    if (run.status === 'error') agentError.value = run.error || 'Run failed'
    await Promise.all([loadAgents(), loadRecurrentRuns(), loadReports()])
  } catch (err) {
    agentError.value = err instanceof Error ? err.message : 'Run failed'
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
const generatedApps = computed(() =>
  apps.installed.filter(app => app.generated)
)

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
  } catch (err) {
    genError.value = err instanceof Error ? err.message : 'Generation failed'
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
  } catch (err) {
    genError.value = err instanceof Error ? err.message : 'Modification failed'
  } finally {
    genBusy.value = false
  }
}

async function restoreApp(id: string) {
  genError.value = ''
  restoringId.value = id
  try {
    await apps.restore(id)
  } catch (err) {
    genError.value = err instanceof Error ? err.message : 'Restore failed'
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
      <router-link to="/settings?tab=apps">Enable them in Settings</router-link>
      and configure a model server first.
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
          v-autofocus
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
                <tr v-for="agent in agents" :key="agent.id">
                  <td>
                    {{ agent.name }}
                    <span class="mode-badge">{{ agent.mode }}</span>
                  </td>
                  <td>{{ agent.kinds.join(', ') }}</td>
                  <td>{{ scheduleLabel(agent.schedule) }}</td>
                  <td>
                    <label class="toggle">
                      <input
                        type="checkbox"
                        :checked="agent.enabled"
                        @change="toggleAgent(agent)"
                      />
                    </label>
                  </td>
                  <td>
                    <template v-if="lastRunOf(agent.id)">
                      {{ formatDate(lastRunOf(agent.id)!.inserted_at) }} -
                      {{ lastRunOf(agent.id)!.status }}
                    </template>
                    <template v-else-if="agent.last_run_at">
                      {{ formatDate(agent.last_run_at) }}
                    </template>
                    <template v-else>never</template>
                  </td>
                  <td class="app-actions">
                    <button
                      type="button"
                      class="tk-revoke"
                      title="Run now"
                      :disabled="runningId === agent.id"
                      @click="runNow(agent)"
                    >
                      <Play :size="14" />
                    </button>
                    <button
                      type="button"
                      class="tk-revoke"
                      title="Edit"
                      @click="openEdit(agent)"
                    >
                      <Pencil :size="14" />
                    </button>
                    <button
                      type="button"
                      class="tk-revoke"
                      title="Delete"
                      @click="deleteAgent(agent)"
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
              <label class="tk-expiry">
                <span class="tk-domain-label">Mode</span>
                <ComboBox
                  class="tk-domain-select"
                  :model-value="fMode"
                  :options="MODE_OPTIONS"
                  @update:model-value="
                    value => (fMode = value as 'prompt' | 'recipe')
                  "
                />
              </label>
              <textarea
                v-if="fMode === 'prompt'"
                v-model="fPrompt"
                rows="3"
                placeholder="What should the agent look for or summarize?"
              ></textarea>
              <template v-if="fMode === 'recipe'">
                <textarea
                  v-model="fDescription"
                  rows="2"
                  placeholder="Describe the script, e.g. sum bank_tx amounts by category each week"
                ></textarea>
                <div class="card-actions">
                  <button
                    type="button"
                    :disabled="
                      drafting || !fDescription.trim() || !fKinds.trim()
                    "
                    @click="draftRecipe"
                  >
                    {{ drafting ? 'Drafting...' : 'Generate recipe' }}
                  </button>
                </div>
                <textarea
                  v-model="fRecipeJson"
                  rows="8"
                  class="recipe-json"
                  placeholder='{"aggregate": {"op": "count"}}'
                ></textarea>
                <p class="tk-hint">
                  The recipe runs deterministically on schedule; the model is
                  only used here, to draft it. Edit it freely before saving.
                </p>
              </template>
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
              <template v-if="fSchedule !== 'every_hour'">
                <label class="tk-expiry">
                  <span class="tk-domain-label">At hour</span>
                  <input
                    v-model="fHour"
                    type="number"
                    min="0"
                    max="23"
                    placeholder="any"
                  />
                </label>
                <p class="tk-hint">
                  Hour of the day in your timezone. Leave empty to run once the
                  interval has elapsed, wherever the previous run landed.
                </p>
              </template>
              <template v-if="fMode === 'prompt'">
                <label class="tk-expiry">
                  <span class="tk-domain-label">Model</span>
                  <input
                    v-model="fModel"
                    type="text"
                    :placeholder="aiConfig?.model || 'model from Settings'"
                  />
                </label>
                <p class="tk-hint">
                  Leave empty to use the model from Settings. A per-agent value
                  lets a daily digest run on a cheap model and a weekly analysis
                  on a stronger one.
                </p>
              </template>
              <p v-if="agentError" class="msg msg-error">{{ agentError }}</p>
              <div class="card-actions">
                <button
                  type="submit"
                  :disabled="
                    fSaving ||
                    !fName.trim() ||
                    !fKinds.trim() ||
                    (fMode === 'prompt' ? !fPrompt.trim() : !fRecipeJson.trim())
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
            <input
              v-model="reportQuery"
              class="report-search"
              type="search"
              placeholder="Search reports..."
              aria-label="Search reports"
              @input="onReportSearch"
            />
            <template v-for="agent in agents" :key="agent.id">
              <template v-if="reportsOf(agent.id).length">
                <p class="report-agent-name">{{ agent.name }}</p>
                <div
                  v-for="report in reportsOf(agent.id)"
                  :key="report.id"
                  class="report-item"
                >
                  <button
                    type="button"
                    class="report-toggle"
                    @click="
                      expandedReport =
                        expandedReport === report.id ? '' : report.id
                    "
                  >
                    {{ report.title || 'Report' }} -
                    {{ formatDate(report.occurred_at || report.inserted_at) }}
                  </button>
                  <template v-if="expandedReport === report.id">
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
                      reportContent(report)
                    }}</pre>
                    <div
                      v-else
                      class="report-content report-rendered"
                      v-html="reportHtml(report)"
                    ></div>
                  </template>
                </div>
              </template>
            </template>
            <p
              v-if="!agents.some(agent => reportsOf(agent.id).length)"
              class="tk-empty"
            >
              {{ reportQuery ? 'No report matches.' : 'No reports yet.' }}
            </p>
            <div v-if="reports.length < reportTotal" class="report-more">
              <button type="button" @click="loadMoreReports">
                Load more ({{ reports.length }} of {{ reportTotal }})
              </button>
            </div>
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
                <tr v-for="run in recurrentRuns" :key="run.id">
                  <td>{{ formatDate(run.inserted_at) }}</td>
                  <td>{{ agentName(run.agent_id) }}</td>
                  <td>{{ run.model || '-' }}</td>
                  <td>
                    {{
                      run.input_tokens != null
                        ? `${run.input_tokens} in / ${run.output_tokens} out`
                        : '-'
                    }}
                  </td>
                  <td>
                    {{
                      run.duration_ms != null
                        ? `${Math.round(run.duration_ms / 1000)}s`
                        : '-'
                    }}
                  </td>
                  <td>
                    {{ run.status }}
                    <div v-if="run.error" class="run-error" :title="run.error">
                      {{ run.error }}
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
                <template v-for="app in generatedApps" :key="app.id">
                  <tr>
                    <td>{{ app.name }}</td>
                    <td class="app-actions">
                      <button
                        type="button"
                        class="tk-revoke"
                        title="Modify with the configured model"
                        :disabled="genBusy"
                        @click="
                          modifyingId = modifyingId === app.id ? '' : app.id
                        "
                      >
                        <Pencil :size="14" />
                      </button>
                      <button
                        v-if="app.has_previous"
                        type="button"
                        class="tk-revoke"
                        title="Restore the previous version"
                        :disabled="restoringId === app.id"
                        @click="restoreApp(app.id)"
                      >
                        <Undo2 :size="14" />
                      </button>
                      <button
                        type="button"
                        class="tk-revoke"
                        title="Uninstall"
                        @click="uninstallGenerated(app.id, app.name)"
                      >
                        <Trash2 :size="14" />
                      </button>
                    </td>
                  </tr>
                  <tr v-if="modifyingId === app.id">
                    <td colspan="2">
                      <form
                        class="app-form"
                        @submit.prevent="modifyApp(app.id)"
                      >
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
                <tr v-for="run in builderRuns" :key="run.id">
                  <td>{{ formatDate(run.inserted_at) }}</td>
                  <td>{{ run.action }}</td>
                  <td>{{ run.app_id || '-' }}</td>
                  <td>{{ run.model || '-' }}</td>
                  <td>
                    {{
                      run.input_tokens != null
                        ? `${run.input_tokens} in / ${run.output_tokens} out`
                        : '-'
                    }}
                  </td>
                  <td>
                    {{
                      run.duration_ms != null
                        ? `${Math.round(run.duration_ms / 1000)}s`
                        : '-'
                    }}
                  </td>
                  <td>
                    {{ run.status }}
                    <div v-if="run.error" class="run-error" :title="run.error">
                      {{ run.error }}
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
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
  background: color-mix(in srgb, var(--danger) 8%, transparent);
}

.msg {
  font-size: 0.9rem;
  margin-bottom: 0.5rem;
  padding: 0.4rem 0.6rem;
  border-radius: var(--radius);
}
.msg-error {
  color: var(--danger);
  background: color-mix(in srgb, var(--danger) 10%, transparent);
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

.report-search {
  width: 100%;
  margin-bottom: 0.5rem;
}
.report-more {
  margin-top: 0.75rem;
  text-align: center;
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
.tabs button:hover {
  background: var(--bg-hover);
  color: var(--text);
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
.report-view-tabs button:hover {
  background: var(--bg-hover);
  color: var(--text);
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
.report-rendered :deep(.md-table-wrap) {
  overflow-x: auto;
  margin: 0.5rem 0;
}
.report-rendered :deep(table) {
  border-collapse: collapse;
}
.report-rendered :deep(th),
.report-rendered :deep(td) {
  border: 1px solid var(--border);
  padding: 0.25rem 0.5rem;
  white-space: nowrap;
}
.report-rendered :deep(th) {
  background: var(--bg);
  text-align: left;
}
.report-rendered :deep(code) {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 4px;
  font-size: 0.85em;
  padding: 0.05em 0.3em;
}
.report-rendered :deep(pre) {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  overflow-x: auto;
  padding: 0.6rem 0.8rem;
}
/* A block already has the frame: the inner code tag must not add a second. */
.report-rendered :deep(pre code) {
  background: none;
  border: none;
  padding: 0;
}
.report-rendered :deep(blockquote) {
  border-left: 3px solid var(--border);
  color: var(--text-muted);
  margin: 0.5rem 0;
  padding: 0.1rem 0 0.1rem 0.75rem;
}
.report-rendered :deep(hr) {
  border: none;
  border-top: 1px solid var(--border);
  margin: 0.75rem 0;
}
.report-rendered :deep(li.md-task) {
  list-style: none;
  margin-left: -1rem;
}
.report-rendered :deep(li.md-task input) {
  margin-right: 0.4rem;
}
.report-rendered :deep(a) {
  color: var(--primary);
}
.mode-badge {
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-muted);
  font-size: 0.7rem;
  margin-left: 0.35rem;
  padding: 0.05rem 0.4rem;
}
.recipe-json {
  font-family: var(--font-mono);
  font-size: 0.85rem;
}
</style>
