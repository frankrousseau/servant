<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { Paperclip } from 'lucide-vue-next'
import type { AppContext, Entry } from '../types'
import { utcToZonedParts } from '../../lib/datetime'
import { entryRoute } from '../../lib/entryRoute'
import { safeUrl } from '../../lib/url'
import AutocompleteInput from '../../components/AutocompleteInput.vue'
import ComboBox from '../../components/ComboBox.vue'
import { categoryColor, daysBetween, formatAmount } from './finance'

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

// ----- bulk selection -----

const selected = ref<Set<string>>(new Set())

function toggleSelect(id: string) {
  if (selected.value.has(id)) selected.value.delete(id)
  else selected.value.add(id)
  selected.value = new Set(selected.value)
}

function selectAllFiltered() {
  selected.value = new Set(filtered.value.map(t => t.id))
}

const bulkDraft = ref('')
const bulkApplying = ref(false)

async function applyBulkCategory(value: string) {
  const category = value.trim()
  if (!category || bulkApplying.value) return
  bulkApplying.value = true
  try {
    for (const id of selected.value) {
      const t = props.txs.find(x => x.id === id)
      if (!t || categoryOf(t) === category) continue
      try {
        const updated = await props.ctx.api.entries.update(t.id, {
          data: { ...t.data, category }
        })
        emit('updated', updated)
      } catch {
        // keep going
      }
    }
    selected.value = new Set()
    bulkDraft.value = ''
  } finally {
    bulkApplying.value = false
  }
}

// ----- auto-categorize: guess from already-categorized labels -----

// Digits and punctuation vary between occurrences of the same merchant
// ("CB CARREFOUR 12/07"); the letters are the stable part.
function guessKey(label: string): string {
  return label
    .toLowerCase()
    .replace(/[^\p{L}]+/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

const autoOpen = ref(false)
const autoGroups = ref<{ category: string; txs: Entry[]; checked: boolean }[]>(
  []
)
const autoApplying = ref(false)

function openAutoCat() {
  // Most frequent category per label key, learned from categorized txs.
  const counts = new Map<string, Map<string, number>>()
  for (const t of props.txs) {
    const category = categoryOf(t)
    const key = guessKey(labelOf(t))
    if (!category || !key) continue
    const c = counts.get(key) || new Map<string, number>()
    c.set(category, (c.get(category) || 0) + 1)
    counts.set(key, c)
  }
  const best = new Map<string, string>()
  for (const [key, c] of counts) {
    best.set(key, [...c.entries()].sort((a, b) => b[1] - a[1])[0][0])
  }

  const byCat = new Map<string, Entry[]>()
  for (const t of props.txs) {
    if (categoryOf(t)) continue
    const category = best.get(guessKey(labelOf(t)))
    if (!category) continue
    byCat.set(category, [...(byCat.get(category) || []), t])
  }
  autoGroups.value = [...byCat.entries()]
    .map(([category, txs]) => ({ category, txs, checked: true }))
    .sort((a, b) => b.txs.length - a.txs.length)
  autoOpen.value = true
}

function autoExamples(txs: Entry[]): string {
  const labels = [...new Set(txs.map(labelOf))]
  const shownLabels = labels.slice(0, 3).join(', ')
  return labels.length > 3 ? `${shownLabels}, ...` : shownLabels
}

async function applyAutoCat() {
  if (autoApplying.value) return
  autoApplying.value = true
  try {
    for (const g of autoGroups.value) {
      if (!g.checked) continue
      for (const t of g.txs) {
        try {
          const updated = await props.ctx.api.entries.update(t.id, {
            data: { ...t.data, category: g.category }
          })
          emit('updated', updated)
        } catch {
          // keep going
        }
      }
    }
    autoOpen.value = false
  } finally {
    autoApplying.value = false
  }
}

// ----- duplicates -----

// The same movement imported twice (overlapping CSVs, CSV + bank API)
// rarely matches exactly: each source words the label its own way and the
// booking date can shift by a day or two. Candidates: same amount, civil
// dates at most 2 days apart. The account is shown but not part of the
// key, the same real account is named differently per source.
const DUP_DAYS = 2
const dedupOpen = ref(false)
const dupSelected = ref<Set<string>>(new Set())

const dupGroups = computed(() => {
  const byAmount = new Map<number, Entry[]>()
  for (const t of props.txs) {
    const amount = t.data.amount
    if (typeof amount !== 'number' || !t.occurred_at) continue
    byAmount.set(amount, [...(byAmount.get(amount) || []), t])
  }
  const groups: Entry[][] = []
  for (const list of byAmount.values()) {
    if (list.length < 2) continue
    list.sort((a, b) => dateOf(a).localeCompare(dateOf(b)))
    let cluster = [list[0]]
    for (const t of list.slice(1)) {
      if (
        daysBetween(dateOf(cluster[cluster.length - 1]), dateOf(t)) <= DUP_DAYS
      ) {
        cluster.push(t)
      } else {
        if (cluster.length > 1) groups.push(cluster)
        cluster = [t]
      }
    }
    if (cluster.length > 1) groups.push(cluster)
  }
  return groups.map(g =>
    [...g].sort((a, b) => a.inserted_at.localeCompare(b.inserted_at))
  )
})

// Twins worth preselecting: labels sharing a word, or two different sources
// reporting the same movement. Same-source rows with unrelated labels stay
// unchecked, those are probably two real purchases.
function likelyDup(a: Entry, b: Entry): boolean {
  if (a.source !== b.source) return true
  const words = new Set(guessKey(labelOf(a)).split(' ').filter(Boolean))
  return guessKey(labelOf(b))
    .split(' ')
    .filter(Boolean)
    .some(w => words.has(w))
}

// Keep one per group: prefer a tx carrying a balance (it feeds the curve),
// else the oldest import; preselect the likely twins for deletion.
function openDedup() {
  const selected = new Set<string>()
  for (const g of dupGroups.value) {
    const keep = g.find(t => typeof t.data.balance === 'number') || g[0]
    for (const t of g)
      if (t.id !== keep.id && likelyDup(t, keep)) selected.add(t.id)
  }
  dupSelected.value = selected
  dedupOpen.value = true
}

function toggleDup(id: string) {
  if (dupSelected.value.has(id)) dupSelected.value.delete(id)
  else dupSelected.value.add(id)
  dupSelected.value = new Set(dupSelected.value)
}

async function deleteDuplicates() {
  const ids = [...dupSelected.value]
  if (!ids.length) return
  const ok = await props.ctx.confirm.ask({
    message: `Delete ${ids.length} duplicate transaction(s)?`,
    danger: true
  })
  if (!ok) return
  for (const id of ids) {
    try {
      await props.ctx.api.entries.delete(id)
      emit('deleted', id)
    } catch {
      // keep going; a leftover shows up on the next scan
    }
  }
  dedupOpen.value = false
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
      <button
        class="ftx-dedup-btn"
        :class="{ 'ftx-dedup-btn--active': autoOpen }"
        @click="autoOpen ? (autoOpen = false) : openAutoCat()"
      >
        Auto-categorize
      </button>
      <button
        class="ftx-dedup-btn"
        :class="{ 'ftx-dedup-btn--active': dedupOpen }"
        @click="dedupOpen ? (dedupOpen = false) : openDedup()"
      >
        Duplicates
      </button>
    </div>

    <div v-if="autoOpen" class="ftx-dedup">
      <p v-if="!autoGroups.length" class="ftx-empty">
        No suggestions: categorize a few transactions by hand first, similar
        labels then follow.
      </p>
      <template v-else>
        <p class="ftx-dedup-hint">
          Uncategorized transactions whose label matches one you already
          categorized.
        </p>
        <label v-for="g in autoGroups" :key="g.category" class="ftx-auto-row">
          <input v-model="g.checked" type="checkbox" />
          <span
            class="ftx-auto-dot"
            :style="{ background: categoryColor(g.category) }"
          ></span>
          <span class="ftx-auto-cat">{{ g.category }}</span>
          <span class="ftx-auto-count">{{ g.txs.length }} tx</span>
          <span class="ftx-auto-examples">{{ autoExamples(g.txs) }}</span>
        </label>
        <button
          class="ftx-dedup-btn ftx-auto-apply"
          :disabled="autoApplying || autoGroups.every(g => !g.checked)"
          @click="applyAutoCat"
        >
          {{ autoApplying ? 'Applying...' : 'Apply' }}
        </button>
      </template>
    </div>

    <div v-if="selected.size" class="ftx-bulk">
      <span class="ftx-bulk-count">{{ selected.size }} selected</span>
      <button
        v-if="selected.size < filtered.length"
        class="ftx-dedup-btn"
        @click="selectAllFiltered"
      >
        Select all {{ filtered.length }} filtered
      </button>
      <AutocompleteInput
        v-model="bulkDraft"
        class="ftx-bulk-cat"
        :options="categories"
        placeholder="Set category..."
        @select="applyBulkCategory"
      />
      <button class="ftx-dedup-btn" @click="selected = new Set()">Clear</button>
    </div>

    <div v-if="dedupOpen" class="ftx-dedup">
      <p v-if="!dupGroups.length" class="ftx-empty">No duplicates found.</p>
      <template v-else>
        <p class="ftx-dedup-hint">
          Same amount, dates at most 2 days apart; labels can differ between
          imports. Checked rows will be deleted; one per group is kept (the one
          carrying a balance when possible).
        </p>
        <div v-for="(g, gi) in dupGroups" :key="gi" class="ftx-dedup-group">
          <label v-for="t in g" :key="t.id" class="ftx-dedup-row">
            <input
              type="checkbox"
              :checked="dupSelected.has(t.id)"
              @change="toggleDup(t.id)"
            />
            <span class="ftx-date">{{ dateOf(t) }}</span>
            <span class="ftx-label">{{ labelOf(t) }}</span>
            <span class="ftx-dedup-meta"
              >{{ accountOf(t) }} - {{ t.source
              }}{{
                typeof t.data.balance === 'number' ? ' - balance' : ''
              }}</span
            >
            <span class="ftx-amount">{{
              formatAmount(
                (t.data.amount as number) || 0,
                (t.data.currency as string) || 'EUR'
              )
            }}</span>
          </label>
        </div>
        <button
          class="ftx-dedup-delete"
          :disabled="!dupSelected.size"
          @click="deleteDuplicates"
        >
          Delete {{ dupSelected.size }} selected
        </button>
      </template>
    </div>

    <p v-if="!filtered.length" class="ftx-empty">No matching transactions.</p>

    <template v-for="g in groups" :key="g.month">
      <div class="ftx-month">{{ g.month }}</div>
      <div v-for="t in g.txs" :key="t.id" class="ftx-row">
        <input
          type="checkbox"
          class="ftx-check"
          :checked="selected.has(t.id)"
          @change="toggleSelect(t.id)"
        />
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
.ftx-check {
  width: 13px;
  height: 13px;
  margin: 0;
  accent-color: var(--primary);
  flex-shrink: 0;
  opacity: 0.5;
}
.ftx-check:checked,
.ftx-row:hover .ftx-check {
  opacity: 1;
}
.ftx-bulk {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  border: 1px dashed var(--border);
  border-radius: 8px;
  padding: 0.45rem 0.8rem;
  margin-top: 0.75rem;
}
.ftx-bulk-count {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.78rem;
  color: var(--text-muted);
}
.ftx-bulk-cat {
  width: 200px;
}
.ftx-bulk-cat :deep(input) {
  width: 100%;
  font-size: 0.82rem;
  padding: 0.25rem 0.5rem;
}
.ftx-auto-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.2rem 0;
  font-size: 0.85rem;
  cursor: pointer;
  border-top: 1px solid var(--border);
}
.ftx-auto-row input {
  width: 14px;
  height: 14px;
  margin: 0;
  accent-color: var(--primary);
  flex-shrink: 0;
}
.ftx-auto-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  flex-shrink: 0;
}
.ftx-auto-cat {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.8rem;
}
.ftx-auto-count {
  color: var(--text-muted);
  font-size: 0.75rem;
  flex-shrink: 0;
}
.ftx-auto-examples {
  color: var(--text-muted);
  font-size: 0.75rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.ftx-auto-apply {
  margin-top: 0.6rem;
}
.ftx-dedup-btn {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  border-radius: 8px;
  padding: 0.3rem 0.7rem;
  font-size: 0.8rem;
  cursor: pointer;
  white-space: nowrap;
}
.ftx-dedup-btn:hover,
.ftx-dedup-btn--active {
  border-color: var(--primary);
  color: var(--primary);
}
.ftx-dedup {
  border: 1px dashed var(--border);
  border-radius: 8px;
  padding: 0.6rem 0.8rem;
  margin-top: 0.75rem;
}
.ftx-dedup-hint {
  color: var(--text-muted);
  font-size: 0.78rem;
  margin: 0 0 0.5rem;
}
.ftx-dedup-group {
  border-top: 1px solid var(--border);
  padding: 0.3rem 0;
}
.ftx-dedup-row {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  padding: 0.15rem 0;
  font-size: 0.85rem;
  cursor: pointer;
}
.ftx-dedup-row input {
  width: 14px;
  height: 14px;
  margin: 0;
  accent-color: var(--danger);
  flex-shrink: 0;
}
.ftx-dedup-row .ftx-date {
  width: auto;
}
.ftx-dedup-meta {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  color: var(--text-muted);
  flex-shrink: 0;
}
.ftx-dedup-row .ftx-amount {
  margin-left: auto;
}
.ftx-dedup-delete {
  margin-top: 0.6rem;
  border: 1px solid var(--danger);
  background: transparent;
  color: var(--danger);
  border-radius: 8px;
  padding: 0.3rem 0.8rem;
  font-size: 0.82rem;
  cursor: pointer;
}
.ftx-dedup-delete:disabled {
  opacity: 0.5;
  cursor: default;
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
