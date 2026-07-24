<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { Paperclip } from 'lucide-vue-next'
import type { AppContext, Entry } from '../types'
import { utcToZonedParts } from '../../lib/datetime'
import { entryRoute } from '../../lib/entryRoute'
import { safeUrl } from '../../lib/url'
import AutocompleteInput from '../../components/AutocompleteInput.vue'
import ComboBox from '../../components/ComboBox.vue'
import { formatAmount } from './finance'

const props = defineProps<{ ctx: AppContext; txs: Entry[] }>()
const emit = defineEmits<{ updated: [tx: Entry]; deleted: [id: string] }>()

const PAGE = 50
const shown = ref(PAGE)

const ALL_ACCOUNTS = 'All accounts'
const ALL_CATEGORIES = 'All categories'
const UNCATEGORIZED = 'Uncategorized'
const ALL_FLOWS = 'In and out'
const FLOW_OPTIONS = [ALL_FLOWS, 'Incoming', 'Outgoing']

const accountFilter = ref(ALL_ACCOUNTS)
const categoryFilter = ref(ALL_CATEGORIES)
const flowFilter = ref(ALL_FLOWS)

const categoryOf = (t: Entry) => ((t.data.category as string) || '').trim()
const accountOf = (t: Entry) => ((t.data.account as string) || '').trim()
const labelOf = (t: Entry) =>
  ((t.data.description as string) || t.title || '').trim()
const dateOf = (t: Entry) =>
  t.occurred_at ? utcToZonedParts(t.occurred_at).date : ''

const accountOptions = computed(() => [
  ALL_ACCOUNTS,
  ...[...new Set(props.txs.map(accountOf))].filter(Boolean).sort()
])

const categories = computed(() =>
  [...new Set(props.txs.map(categoryOf))].filter(Boolean).sort()
)
const categoryOptions = computed(() => [
  ALL_CATEGORIES,
  UNCATEGORIZED,
  ...categories.value
])

const filtered = computed(() => {
  let list = props.txs
  if (accountFilter.value !== ALL_ACCOUNTS)
    list = list.filter(t => accountOf(t) === accountFilter.value)
  if (categoryFilter.value === UNCATEGORIZED)
    list = list.filter(t => !categoryOf(t))
  else if (categoryFilter.value !== ALL_CATEGORIES)
    list = list.filter(t => categoryOf(t) === categoryFilter.value)
  if (flowFilter.value === 'Incoming')
    list = list.filter(t => ((t.data.amount as number) || 0) > 0)
  else if (flowFilter.value === 'Outgoing')
    list = list.filter(t => ((t.data.amount as number) || 0) < 0)
  return [...list].sort((a, b) =>
    (b.occurred_at || '').localeCompare(a.occurred_at || '')
  )
})

watch([accountFilter, categoryFilter, flowFilter], () => {
  shown.value = PAGE
})

const visible = computed(() => filtered.value.slice(0, shown.value))

// Month groups over the visible slice, newest first.
const groups = computed(() => {
  const out: { month: string; txs: Entry[] }[] = []
  for (const t of visible.value) {
    const month = dateOf(t).slice(0, 7)
    const last = out[out.length - 1]
    if (last && last.month === month) last.txs.push(t)
    else out.push({ month, txs: [t] })
  }
  return out
})

// ----- category editing (immediate save) -----

const editingId = ref<string | null>(null)
const draft = ref('')
const saving = ref(false)

function startEdit(t: Entry) {
  editingId.value = t.id
  draft.value = categoryOf(t)
  void nextTick(() => {
    document.querySelector<HTMLInputElement>('.ftx-cat-edit input')?.focus()
  })
}

async function saveCategory(t: Entry, value: string) {
  if (saving.value) return
  const category = value.trim()
  if (category === categoryOf(t)) {
    editingId.value = null
    return
  }
  saving.value = true
  try {
    const updated = await props.ctx.api.entries.update(t.id, {
      data: { ...t.data, category: category || null }
    })
    emit('updated', updated)
    editingId.value = null
  } catch {
    // keep the editor open
  } finally {
    saving.value = false
  }
}

// ----- linked document (invoice or file) -----

const linkedTitle = (t: Entry) =>
  ((t.data.linked_entry_title as string) || '').trim()

const linkingId = ref<string | null>(null)
// Candidates load once, on the first link attempt.
const docOptions = ref<{ value: string; label: string }[] | null>(null)

async function startLink(t: Entry) {
  linkingId.value = t.id
  if (docOptions.value) return
  try {
    const [invoices, files] = await Promise.all([
      props.ctx.api.entries.list({ kind: 'invoice' }),
      props.ctx.api.entries.list({ kind: 'file' })
    ])
    docOptions.value = [
      ...invoices.map(e => ({
        value: e.id,
        label: `${e.title || '(untitled)'} - invoice`
      })),
      ...files
        .filter(e => !e.data.is_folder)
        .map(e => ({
          value: e.id,
          label: `${(e.data.filename as string) || e.title || '(unnamed)'} - file`
        }))
    ].sort((a, b) => a.label.toLowerCase().localeCompare(b.label.toLowerCase()))
  } catch {
    docOptions.value = []
  }
}

async function saveLink(t: Entry, id: string, title: string | null) {
  try {
    const updated = await props.ctx.api.entries.update(t.id, {
      data: {
        ...t.data,
        linked_entry_id: id || null,
        linked_entry_title: title
      }
    })
    emit('updated', updated)
  } catch {
    // ignore
  }
  linkingId.value = null
}

function pickDoc(t: Entry, id: string) {
  const opt = docOptions.value?.find(o => o.value === id)
  if (!opt) return
  // Strip the " - invoice" / " - file" disambiguation suffix.
  void saveLink(t, id, opt.label.replace(/ - (invoice|file)$/, ''))
}

async function deleteTx(t: Entry) {
  const ok = await props.ctx.confirm.ask({
    message: `Delete "${labelOf(t)}"?`,
    danger: true
  })
  if (!ok) return
  try {
    await props.ctx.api.entries.delete(t.id)
    emit('deleted', t.id)
  } catch {
    // ignore
  }
}

// Invoices open their provider URL when they have one; everything else
// lands on its app surface.
async function openLinked(t: Entry) {
  const id = t.data.linked_entry_id as string
  if (!id) return
  try {
    const doc = await props.ctx.api.entries.get(id)
    const url = safeUrl((doc.data.url as string) || '')
    if (doc.kind === 'invoice' && url) window.open(url, '_blank', 'noopener')
    else props.ctx.navigate(entryRoute(doc))
  } catch {
    // linked document gone; keep the chip, the title still informs
  }
}
</script>

<template>
  <section class="ftx">
    <div class="ftx-head">
      <h2 class="ftx-title">Transactions</h2>
      <span class="ftx-count">{{ filtered.length }}</span>
      <span class="ftx-spacer"></span>
      <ComboBox
        v-model="flowFilter"
        class="ftx-filter ftx-filter--flow"
        :options="FLOW_OPTIONS"
      />
      <ComboBox
        v-if="accountOptions.length > 2"
        v-model="accountFilter"
        class="ftx-filter"
        :options="accountOptions"
      />
      <ComboBox
        v-model="categoryFilter"
        class="ftx-filter"
        :options="categoryOptions"
      />
    </div>

    <p v-if="!filtered.length" class="ftx-empty">No matching transactions.</p>

    <template v-for="g in groups" :key="g.month">
      <div class="ftx-month">{{ g.month }}</div>
      <div v-for="t in g.txs" :key="t.id" class="ftx-row">
        <span class="ftx-date">{{ dateOf(t).slice(8) }}</span>
        <span class="ftx-label" :title="labelOf(t)">{{ labelOf(t) }}</span>
        <span class="ftx-right">
          <template v-if="linkingId === t.id">
            <ComboBox
              class="ftx-doc-pick"
              model-value=""
              :options="docOptions || []"
              placeholder="Invoice or file..."
              @update:model-value="v => pickDoc(t, v)"
            />
            <button
              class="ftx-doc-clear"
              title="Cancel"
              @click="linkingId = null"
            >
              ×
            </button>
          </template>
          <span
            v-else-if="linkedTitle(t)"
            class="ftx-doc"
            :title="linkedTitle(t)"
          >
            <Paperclip :size="11" />
            <span class="ftx-doc-name" role="button" @click="openLinked(t)">{{
              linkedTitle(t)
            }}</span>
            <button
              class="ftx-doc-clear"
              title="Unlink"
              @click="saveLink(t, '', null)"
            >
              ×
            </button>
          </span>
          <button
            v-else
            class="ftx-linkbtn"
            title="Link an invoice or file"
            @click="startLink(t)"
          >
            <Paperclip :size="12" />
          </button>
          <span
            v-if="editingId !== t.id"
            class="ftx-cat"
            :class="{ 'ftx-cat--empty': !categoryOf(t) }"
            role="button"
            @click="startEdit(t)"
            >{{ categoryOf(t) || '+ category' }}</span
          >
          <AutocompleteInput
            v-else
            v-model="draft"
            class="ftx-cat-edit"
            :options="categories"
            placeholder="category"
            @select="v => saveCategory(t, v)"
            @keydown.escape="editingId = null"
          />
          <span
            class="ftx-amount"
            :class="{ 'ftx-amount--in': ((t.data.amount as number) || 0) > 0 }"
            >{{
              formatAmount(
                (t.data.amount as number) || 0,
                (t.data.currency as string) || 'EUR'
              )
            }}</span
          >
          <button
            class="ftx-del"
            title="Delete transaction"
            @click="deleteTx(t)"
          >
            ×
          </button>
        </span>
      </div>
    </template>

    <button
      v-if="filtered.length > shown"
      class="ftx-more"
      @click="shown += PAGE"
    >
      Show more ({{ filtered.length - shown }} left)
    </button>
  </section>
</template>

<style scoped>
/* Mirrors FinanceApp's .fin-universe card look (scoped styles don't cross
   component boundaries). */
.ftx {
  margin-bottom: 2rem;
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem 1.15rem;
  background: var(--bg-surface);
}
.ftx-head {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}
.ftx-title {
  margin: 0;
  font-family: var(--font-display);
  font-weight: 400;
  font-size: 1.3rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}
.ftx-count {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.78rem;
  color: var(--text-muted);
}
.ftx-spacer {
  flex: 1;
}
.ftx-filter {
  width: 160px;
}
.ftx-filter--flow {
  width: 130px;
}
.ftx-empty {
  color: var(--text-muted);
  font-size: 0.85rem;
  margin: 0.5rem 0 0;
}
.ftx-month {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
  margin: 0.9rem 0 0.25rem;
}
.ftx-row {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  padding: 0.28rem 0.25rem;
  border-top: 1px solid var(--border);
  font-size: 0.88rem;
}
.ftx-date {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.78rem;
  color: var(--text-muted);
  flex-shrink: 0;
  width: 1.6em;
}
.ftx-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.ftx-right {
  margin-left: auto;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  flex-shrink: 0;
}
.ftx-linkbtn {
  border: none;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  padding: 0 0.15rem;
  display: flex;
  align-items: center;
  opacity: 0;
}
.ftx-row:hover .ftx-linkbtn {
  opacity: 1;
}
.ftx-linkbtn:hover {
  color: var(--primary);
}
.ftx-doc {
  display: flex;
  align-items: center;
  gap: 0.3rem;
  color: var(--text-muted);
  font-size: 0.75rem;
  max-width: 220px;
}
.ftx-doc-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  cursor: pointer;
}
.ftx-doc-name:hover {
  color: var(--primary);
  text-decoration: underline;
}
.ftx-doc-clear {
  border: none;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  padding: 0 0.15rem;
}
.ftx-doc-clear:hover {
  color: var(--danger);
}
.ftx-doc-pick {
  width: 240px;
}
.ftx-cat {
  flex-shrink: 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  border: 1px solid var(--border);
  border-radius: 999px;
  padding: 0.05rem 0.55rem;
  cursor: pointer;
  color: var(--text);
}
.ftx-cat--empty {
  color: var(--text-muted);
  border-style: dashed;
}
.ftx-cat:hover {
  border-color: var(--primary);
  color: var(--primary);
}
.ftx-cat-edit {
  width: 150px;
  flex-shrink: 0;
}
.ftx-cat-edit :deep(input) {
  width: 100%;
  font-size: 0.8rem;
  padding: 0.15rem 0.4rem;
}
.ftx-amount {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
  flex-shrink: 0;
  min-width: 7.5em;
  text-align: right;
}
.ftx-amount--in {
  color: var(--success, #4fd674);
}
.ftx-del {
  border: none;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  padding: 0 0.15rem;
  opacity: 0;
}
.ftx-row:hover .ftx-del {
  opacity: 1;
}
.ftx-del:hover {
  color: var(--danger);
}
.ftx-more {
  margin-top: 0.75rem;
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text);
  padding: 0.35rem 0.8rem;
  border-radius: 8px;
  font-size: 0.85rem;
  cursor: pointer;
}
.ftx-more:hover {
  border-color: var(--primary);
  color: var(--primary);
}
</style>
