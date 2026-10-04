<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { Paperclip } from 'lucide-vue-next'

import AutocompleteInput from '../../components/AutocompleteInput.vue'
import ComboBox from '../../components/ComboBox.vue'

import { utcToZonedParts } from '../../lib/datetime'
import { entryRoute } from '../../lib/entryRoute'
import { safeUrl } from '../../lib/url'
import { categoryColor, daysBetween, formatAmount } from './finance'
import type { AppContext, Entry } from '../types'

const props = defineProps<{
  ctx: AppContext
  txs: Entry[]
  // The Accounts tab sets this to open this section filtered on one account.
  focusAccount?: string | null
}>()
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

const categoryOf = (tx: Entry) => ((tx.data.category as string) || '').trim()
const accountOf = (tx: Entry) => ((tx.data.account as string) || '').trim()
const labelOf = (tx: Entry) =>
  ((tx.data.description as string) || tx.title || '').trim()
const dateOf = (tx: Entry) =>
  tx.occurred_at ? utcToZonedParts(tx.occurred_at).date : ''

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
    list = list.filter(tx => accountOf(tx) === accountFilter.value)
  if (categoryFilter.value === UNCATEGORIZED)
    list = list.filter(tx => !categoryOf(tx))
  else if (categoryFilter.value !== ALL_CATEGORIES)
    list = list.filter(tx => categoryOf(tx) === categoryFilter.value)
  if (flowFilter.value === 'Incoming')
    list = list.filter(tx => ((tx.data.amount as number) || 0) > 0)
  else if (flowFilter.value === 'Outgoing')
    list = list.filter(tx => ((tx.data.amount as number) || 0) < 0)
  return [...list].sort((a, b) =>
    (b.occurred_at || '').localeCompare(a.occurred_at || '')
  )
})

watch([accountFilter, categoryFilter, flowFilter], () => {
  shown.value = PAGE
})

// Case-insensitive: it is possible that the identifier of an account does
// not match the imported casing exactly.
watch(
  () => props.focusAccount,
  value => {
    if (!value) return
    const key = value.trim().toLowerCase()
    const match = accountOptions.value.find(
      option => option !== ALL_ACCOUNTS && option.trim().toLowerCase() === key
    )
    accountFilter.value = match || ALL_ACCOUNTS
  },
  { immediate: true }
)

const visible = computed(() => filtered.value.slice(0, shown.value))

// Month groups over the visible slice, newest first.
const groups = computed(() => {
  const out: { month: string; txs: Entry[] }[] = []
  for (const tx of visible.value) {
    const month = dateOf(tx).slice(0, 7)
    const last = out[out.length - 1]
    if (last && last.month === month) last.txs.push(tx)
    else out.push({ month, txs: [tx] })
  }
  return out
})

// ----- category editing (immediate save) -----

const editingId = ref<string | null>(null)
const draft = ref('')
const saving = ref(false)

function startEdit(tx: Entry) {
  editingId.value = tx.id
  draft.value = categoryOf(tx)
  void nextTick(() => {
    document.querySelector<HTMLInputElement>('.ftx-cat-edit input')?.focus()
  })
}

async function saveCategory(tx: Entry, value: string) {
  if (saving.value) return
  const category = value.trim()
  if (category === categoryOf(tx)) {
    editingId.value = null
    return
  }
  saving.value = true
  try {
    const updated = await props.ctx.api.entries.update(tx.id, {
      data: { ...tx.data, category: category || null }
    })
    emit('updated', updated)
    editingId.value = null
  } catch {
    // Keep the editor open.
  } finally {
    saving.value = false
  }
}

// ----- linked document (invoice or file) -----

const linkedTitle = (tx: Entry) =>
  ((tx.data.linked_entry_title as string) || '').trim()

const linkingId = ref<string | null>(null)
// Candidates load once, on the first link attempt.
const docOptions = ref<{ value: string; label: string }[] | null>(null)

async function startLink(tx: Entry) {
  linkingId.value = tx.id
  if (docOptions.value) return
  try {
    const [invoices, files] = await Promise.all([
      props.ctx.api.entries.list({ kind: 'invoice' }),
      props.ctx.api.entries.list({ kind: 'file' })
    ])
    docOptions.value = [
      ...invoices.map(entry => ({
        value: entry.id,
        label: `${entry.title || '(untitled)'} - invoice`
      })),
      ...files
        .filter(entry => !entry.data.is_folder)
        .map(entry => ({
          value: entry.id,
          label: `${(entry.data.filename as string) || entry.title || '(unnamed)'} - file`
        }))
    ].sort((a, b) => a.label.toLowerCase().localeCompare(b.label.toLowerCase()))
  } catch {
    docOptions.value = []
  }
}

async function saveLink(tx: Entry, id: string, title: string | null) {
  try {
    const updated = await props.ctx.api.entries.update(tx.id, {
      data: {
        ...tx.data,
        linked_entry_id: id || null,
        linked_entry_title: title
      }
    })
    emit('updated', updated)
  } catch {
    // Ignore the error.
  }
  linkingId.value = null
}

function pickDoc(tx: Entry, id: string) {
  const opt = docOptions.value?.find(option => option.value === id)
  if (!opt) return
  // Strip the " - invoice" / " - file" disambiguation suffix.
  void saveLink(tx, id, opt.label.replace(/ - (invoice|file)$/, ''))
}

// ----- bulk selection -----

const selected = ref<Set<string>>(new Set())

function toggleSelect(id: string) {
  if (selected.value.has(id)) selected.value.delete(id)
  else selected.value.add(id)
  selected.value = new Set(selected.value)
}

function selectAllFiltered() {
  selected.value = new Set(filtered.value.map(tx => tx.id))
}

const bulkDraft = ref('')
const bulkApplying = ref(false)

async function applyBulkCategory(value: string) {
  const category = value.trim()
  if (!category || bulkApplying.value) return
  bulkApplying.value = true
  try {
    for (const id of selected.value) {
      const tx = props.txs.find(item => item.id === id)
      if (!tx || categoryOf(tx) === category) continue
      try {
        const updated = await props.ctx.api.entries.update(tx.id, {
          data: { ...tx.data, category }
        })
        emit('updated', updated)
      } catch {
        // Continue.
      }
    }
    selected.value = new Set()
    bulkDraft.value = ''
  } finally {
    bulkApplying.value = false
  }
}

// ----- auto-categorize: guess from already-categorized labels -----

// Digits and punctuation change between occurrences of the same merchant
// ("CB CARREFOUR 12/07"). The letters are the stable part.
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
  // The most frequent category for each label key, learned from the
  // categorized txs.
  const counts = new Map<string, Map<string, number>>()
  for (const tx of props.txs) {
    const category = categoryOf(tx)
    const key = guessKey(labelOf(tx))
    if (!category || !key) continue
    const perCategory = counts.get(key) || new Map<string, number>()
    perCategory.set(category, (perCategory.get(category) || 0) + 1)
    counts.set(key, perCategory)
  }
  const best = new Map<string, string>()
  for (const [key, perCategory] of counts) {
    best.set(key, [...perCategory.entries()].sort((a, b) => b[1] - a[1])[0][0])
  }

  const byCat = new Map<string, Entry[]>()
  for (const tx of props.txs) {
    if (categoryOf(tx)) continue
    const category = best.get(guessKey(labelOf(tx)))
    if (!category) continue
    byCat.set(category, [...(byCat.get(category) || []), tx])
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
    for (const group of autoGroups.value) {
      if (!group.checked) continue
      for (const tx of group.txs) {
        try {
          const updated = await props.ctx.api.entries.update(tx.id, {
            data: { ...tx.data, category: group.category }
          })
          emit('updated', updated)
        } catch {
          // Continue.
        }
      }
    }
    autoOpen.value = false
  } finally {
    autoApplying.value = false
  }
}

// ----- duplicates -----

// The same movement imported twice (CSVs that overlap, CSV + bank API)
// rarely matches exactly. Each source words the label differently, and the
// booking date can shift by a day or two. Candidates: same amount, civil
// dates at most 2 days apart. The app shows the account, but the account is
// not part of the key. The reason: each source gives a different name to
// the same real account.
const DUP_DAYS = 2
const dedupOpen = ref(false)
const dupSelected = ref<Set<string>>(new Set())

const dupGroups = computed(() => {
  const byAmount = new Map<number, Entry[]>()
  for (const tx of props.txs) {
    const amount = tx.data.amount
    if (typeof amount !== 'number' || !tx.occurred_at) continue
    byAmount.set(amount, [...(byAmount.get(amount) || []), tx])
  }
  const groups: Entry[][] = []
  for (const list of byAmount.values()) {
    if (list.length < 2) continue
    list.sort((a, b) => dateOf(a).localeCompare(dateOf(b)))
    let cluster = [list[0]]
    for (const tx of list.slice(1)) {
      if (
        daysBetween(dateOf(cluster[cluster.length - 1]), dateOf(tx)) <= DUP_DAYS
      ) {
        cluster.push(tx)
      } else {
        if (cluster.length > 1) groups.push(cluster)
        cluster = [tx]
      }
    }
    if (cluster.length > 1) groups.push(cluster)
  }
  return groups.map(group =>
    [...group].sort((a, b) => a.inserted_at.localeCompare(b.inserted_at))
  )
})

// Finds the twins to preselect: labels that share a word, or two different
// sources that report the same movement. Same-source rows with unrelated
// labels stay unchecked, because they are probably two real purchases.
function likelyDup(txA: Entry, txB: Entry): boolean {
  if (txA.source !== txB.source) return true
  const words = new Set(guessKey(labelOf(txA)).split(' ').filter(Boolean))
  return guessKey(labelOf(txB))
    .split(' ')
    .filter(Boolean)
    .some(word => words.has(word))
}

// Keep one tx for each group. Prefer a tx that has a balance (it feeds the
// curve). If there is none, keep the oldest import. Preselect the likely
// twins for deletion.
function openDedup() {
  const selected = new Set<string>()
  for (const group of dupGroups.value) {
    const keep =
      group.find(tx => typeof tx.data.balance === 'number') || group[0]
    for (const tx of group)
      if (tx.id !== keep.id && likelyDup(tx, keep)) selected.add(tx.id)
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
      // Continue. A leftover shows on the next scan.
    }
  }
  dedupOpen.value = false
}

async function deleteTx(tx: Entry) {
  const ok = await props.ctx.confirm.ask({
    message: `Delete "${labelOf(tx)}"?`,
    danger: true
  })
  if (!ok) return
  try {
    await props.ctx.api.entries.delete(tx.id)
    emit('deleted', tx.id)
  } catch {
    // Ignore the error.
  }
}

// Invoices open their provider URL when they have one. All other documents
// open on their app surface.
async function openLinked(tx: Entry) {
  const id = tx.data.linked_entry_id as string
  if (!id) return
  try {
    const doc = await props.ctx.api.entries.get(id)
    const url = safeUrl((doc.data.url as string) || '')
    if (doc.kind === 'invoice' && url) window.open(url, '_blank', 'noopener')
    else props.ctx.navigate(entryRoute(doc))
  } catch {
    // The linked document is gone. Keep the chip, because the title still
    // gives information.
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
        <label
          v-for="group in autoGroups"
          :key="group.category"
          class="ftx-auto-row"
        >
          <input v-model="group.checked" type="checkbox" />
          <span
            class="ftx-auto-dot"
            :style="{ background: categoryColor(group.category) }"
          ></span>
          <span class="ftx-auto-cat">{{ group.category }}</span>
          <span class="ftx-auto-count">{{ group.txs.length }} tx</span>
          <span class="ftx-auto-examples">{{ autoExamples(group.txs) }}</span>
        </label>
        <button
          class="ftx-dedup-btn ftx-auto-apply"
          :disabled="autoApplying || autoGroups.every(group => !group.checked)"
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
        <div
          v-for="(group, groupIndex) in dupGroups"
          :key="groupIndex"
          class="ftx-dedup-group"
        >
          <label v-for="tx in group" :key="tx.id" class="ftx-dedup-row">
            <input
              type="checkbox"
              :checked="dupSelected.has(tx.id)"
              @change="toggleDup(tx.id)"
            />
            <span class="ftx-date">{{ dateOf(tx) }}</span>
            <span class="ftx-label">{{ labelOf(tx) }}</span>
            <span class="ftx-dedup-meta"
              >{{ accountOf(tx) }} - {{ tx.source
              }}{{
                typeof tx.data.balance === 'number' ? ' - balance' : ''
              }}</span
            >
            <span class="ftx-amount">{{
              formatAmount(
                (tx.data.amount as number) || 0,
                (tx.data.currency as string) || 'EUR'
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

    <template v-for="group in groups" :key="group.month">
      <div class="ftx-month">{{ group.month }}</div>
      <div v-for="tx in group.txs" :key="tx.id" class="ftx-row">
        <input
          type="checkbox"
          class="ftx-check"
          :checked="selected.has(tx.id)"
          @change="toggleSelect(tx.id)"
        />
        <span class="ftx-date">{{ dateOf(tx).slice(8) }}</span>
        <span class="ftx-label" :title="labelOf(tx)">{{ labelOf(tx) }}</span>
        <span class="ftx-right">
          <template v-if="linkingId === tx.id">
            <ComboBox
              class="ftx-doc-pick"
              model-value=""
              :options="docOptions || []"
              placeholder="Invoice or file..."
              @update:model-value="value => pickDoc(tx, value)"
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
            v-else-if="linkedTitle(tx)"
            class="ftx-doc"
            :title="linkedTitle(tx)"
          >
            <Paperclip :size="14" />
            <span
              class="ftx-doc-name"
              role="button"
              tabindex="0"
              v-click-key
              @click="openLinked(tx)"
              >{{ linkedTitle(tx) }}</span
            >
            <button
              class="ftx-doc-clear"
              title="Unlink"
              aria-label="Unlink document"
              @click="saveLink(tx, '', null)"
            >
              ×
            </button>
          </span>
          <button
            v-else
            class="ftx-linkbtn"
            title="Link an invoice or file"
            aria-label="Link an invoice or file"
            @click="startLink(tx)"
          >
            <Paperclip :size="14" />
          </button>
          <span
            v-if="editingId !== tx.id"
            class="ftx-cat"
            :class="{ 'ftx-cat--empty': !categoryOf(tx) }"
            role="button"
            tabindex="0"
            v-click-key
            @click="startEdit(tx)"
            >{{ categoryOf(tx) || '+ category' }}</span
          >
          <AutocompleteInput
            v-else
            v-model="draft"
            class="ftx-cat-edit"
            :options="categories"
            placeholder="category"
            @select="value => saveCategory(tx, value)"
            @keydown.escape="editingId = null"
          />
          <span
            class="ftx-amount"
            :class="{ 'ftx-amount--in': ((tx.data.amount as number) || 0) > 0 }"
            >{{
              formatAmount(
                (tx.data.amount as number) || 0,
                (tx.data.currency as string) || 'EUR'
              )
            }}</span
          >
          <button
            class="ftx-del"
            title="Delete transaction"
            @click="deleteTx(tx)"
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
/* Mirrors the .fin-universe card look of FinanceApp (scoped styles do not
   cross component boundaries). */
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
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
  font-size: 1.15rem;
}
.ftx-doc-clear:hover {
  color: var(--danger);
}
.ftx-doc-pick {
  width: 240px;
}
.ftx-cat {
  flex-shrink: 0;
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
  font-size: 1.15rem;
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
