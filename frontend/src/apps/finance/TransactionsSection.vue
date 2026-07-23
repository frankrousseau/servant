<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import type { AppContext, Entry } from '../types'
import { utcToZonedParts } from '../../lib/datetime'
import AutocompleteInput from '../../components/AutocompleteInput.vue'
import ComboBox from '../../components/ComboBox.vue'
import { formatAmount } from './finance'

const props = defineProps<{ ctx: AppContext; txs: Entry[] }>()
const emit = defineEmits<{ updated: [tx: Entry] }>()

const PAGE = 50
const shown = ref(PAGE)

const ALL_ACCOUNTS = 'All accounts'
const ALL_CATEGORIES = 'All categories'
const UNCATEGORIZED = 'Uncategorized'

const accountFilter = ref(ALL_ACCOUNTS)
const categoryFilter = ref(ALL_CATEGORIES)

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
  return [...list].sort((a, b) =>
    (b.occurred_at || '').localeCompare(a.occurred_at || '')
  )
})

watch([accountFilter, categoryFilter], () => {
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
</script>

<template>
  <section class="ftx">
    <div class="ftx-head">
      <h2 class="ftx-title">Transactions</h2>
      <span class="ftx-count">{{ filtered.length }}</span>
      <span class="ftx-spacer"></span>
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
.ftx-cat {
  margin-left: auto;
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
  margin-left: auto;
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
