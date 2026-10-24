<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { ChevronLeft, ChevronsDownUp, ChevronsUpDown } from 'lucide-vue-next'

import LoadState from '../../components/LoadState.vue'
import SearchField from '../../components/SearchField.vue'
import MemoryTreeNode from './MemoryTreeNode.vue'

import { formatDateTime } from '../../lib/datetime'
import { renderMarkdown } from '../notes/render'
import { splitFrontmatter } from './frontmatter'
import { buildTree } from './tree'
import type { LoadStatus } from '../../components/LoadState.vue'
import type { AppContext } from '../types'
import type { MemoryFile, TreeNode } from './tree'

const props = defineProps<{ ctx: AppContext }>()

const files = ref<MemoryFile[]>([])
const loading = ref(true)
const loadError = ref('')
const actionError = ref('')
const search = ref('')
const selectedPath = ref<string | null>(null)
const editing = ref(false)
const draft = ref('')
const saving = ref(false)
// Expand/collapse all: the tree is re-keyed on each toggle so every <details>
// takes the new default even after a folder was toggled by hand.
const expanded = ref(true)
const treeVersion = ref(0)

function toggleAll() {
  expanded.value = !expanded.value
  treeVersion.value += 1
}

const filteredFiles = computed(() => {
  const needle = search.value.trim().toLowerCase()
  if (!needle) return files.value
  return files.value.filter(memoryFile =>
    memoryFile.path.toLowerCase().includes(needle)
  )
})

const tree = computed(() => buildTree(filteredFiles.value))

const loadState = computed<LoadStatus>(() => {
  if (loading.value) return 'loading'
  return loadError.value ? 'error' : 'ready'
})

const selected = computed(
  () =>
    files.value.find(memoryFile => memoryFile.path === selectedPath.value) ??
    null
)

const split = computed(() => splitFrontmatter(selected.value?.body ?? ''))

const rendered = computed(() =>
  selected.value ? renderMarkdown(split.value.content, () => null) : ''
)

const isDeleted = computed(() => selected.value?.pending === 'deleted')

const selectedMeta = computed(() => {
  if (!selected.value) return ''
  return `${selected.value.tool} · ${selected.value.size} bytes · ${formatDateTime(selected.value.updated_at)}`
})

async function fetchFiles() {
  const res = await props.ctx.api.fetch('/api/agent_memory?include=body')
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  const json = await res.json()
  files.value = json.data
}

async function load() {
  loading.value = true
  loadError.value = ''
  try {
    await fetchFiles()
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : String(err)
  } finally {
    loading.value = false
  }
}

// Live updates: agents push one file per POST, so a seed push is a burst;
// coalesce into one silent refetch (no loading state, the draft being edited
// is kept, the selection follows its path).
let refreshTimer: ReturnType<typeof setTimeout> | null = null
let unsubscribe: (() => void) | null = null

function scheduleRefresh() {
  if (refreshTimer) clearTimeout(refreshTimer)
  refreshTimer = setTimeout(() => {
    refreshTimer = null
    fetchFiles().catch(() => {})
  }, 400)
}

function select(node: TreeNode) {
  if (!node.file) return
  selectedPath.value = node.file.path
  editing.value = false
  actionError.value = ''
}

// Phone layout: back from the file view to the tree.
function backToList() {
  selectedPath.value = null
  actionError.value = ''
}

function startEdit() {
  if (!selected.value) return
  draft.value = selected.value.body ?? ''
  editing.value = true
}

async function save() {
  if (!selected.value) return
  saving.value = true
  actionError.value = ''
  try {
    const res = await props.ctx.api.fetch('/api/agent_memory', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        origin: 'app',
        files: [{ path: selected.value.path, body: draft.value }]
      })
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    const manifest: MemoryFile = json.data[0]
    Object.assign(selected.value, manifest, { body: draft.value })
    editing.value = false
  } catch (err) {
    actionError.value = err instanceof Error ? err.message : String(err)
  } finally {
    saving.value = false
  }
}

// Writing the current body back with origin: app clears the deleted mark.
async function restore() {
  if (!selected.value) return
  actionError.value = ''
  try {
    const res = await props.ctx.api.fetch('/api/agent_memory', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        origin: 'app',
        files: [{ path: selected.value.path, body: selected.value.body ?? '' }]
      })
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    const manifest: MemoryFile = json.data[0]
    Object.assign(selected.value, manifest, { body: selected.value.body })
  } catch (err) {
    actionError.value = err instanceof Error ? err.message : String(err)
  }
}

// Soft delete: the file stays, marked, until every machine has pulled; purge
// then removes it for good.
async function remove() {
  if (!selected.value) return
  const ok = await props.ctx.confirm.ask({
    title: 'Delete file',
    message: `Delete ${selected.value.path}? Agents will remove their copy at their next sync.`,
    confirmLabel: 'Delete',
    danger: true
  })
  if (!ok) return
  await deleteRequest(false)
}

async function purge() {
  if (!selected.value) return
  const ok = await props.ctx.confirm.ask({
    title: 'Purge file',
    message: `Remove ${selected.value.path} for good? Do it once every machine has synced.`,
    confirmLabel: 'Purge',
    danger: true
  })
  if (!ok) return
  await deleteRequest(true)
}

async function deleteRequest(purging: boolean) {
  if (!selected.value) return
  actionError.value = ''
  const path = selected.value.path
  const query = `path=${encodeURIComponent(path)}${purging ? '&purge=true' : ''}`
  try {
    const res = await props.ctx.api.fetch(`/api/agent_memory?${query}`, {
      method: 'DELETE'
    })
    if (!res.ok) {
      actionError.value = `HTTP ${res.status}`
      return
    }
    if (purging) {
      files.value = files.value.filter(memoryFile => memoryFile.path !== path)
      selectedPath.value = null
    } else {
      selected.value.pending = 'deleted'
      editing.value = false
    }
  } catch (err) {
    actionError.value = err instanceof Error ? err.message : String(err)
  }
}

onMounted(() => {
  load()
  // A deleted entry only carries its id: refresh on those too.
  unsubscribe = props.ctx.events.onEntryChange(entry => {
    if (!entry.kind || entry.kind === 'agent_memory') scheduleRefresh()
  })
})

onUnmounted(() => {
  if (unsubscribe) unsubscribe()
  if (refreshTimer) clearTimeout(refreshTimer)
})
</script>

<template>
  <div class="am-layout" :class="{ 'am-layout--detail': selected }">
    <div class="tree">
      <div class="am-side-head">
        <SearchField
          v-model="search"
          class="am-search"
          label="Filter files by path"
          placeholder="Filter by path"
          autofocus
        />
        <button
          v-if="tree.length"
          type="button"
          class="am-tree-toggle"
          :title="expanded ? 'Collapse all folders' : 'Expand all folders'"
          :aria-label="expanded ? 'Collapse all folders' : 'Expand all folders'"
          @click="toggleAll"
        >
          <ChevronsDownUp v-if="expanded" :size="14" />
          <ChevronsUpDown v-else :size="14" />
        </button>
      </div>
      <div class="am-tree">
        <LoadState
          :state="loadState"
          :empty="tree.length === 0"
          what="files"
          :error-text="loadError"
          empty-text="No files yet. Run the servant-memory skill's push script from a repo."
        >
          <ul :key="treeVersion" class="nodes">
            <li v-for="node in tree" :key="node.path">
              <MemoryTreeNode
                :node="node"
                :selected-path="selectedPath"
                :expanded="expanded"
                @select="select"
              />
            </li>
          </ul>
        </LoadState>
      </div>
    </div>

    <div class="viewer">
      <div class="am-topbar">
        <button
          v-if="selected && !editing"
          type="button"
          class="am-back"
          aria-label="Back to list"
          @click="backToList"
        >
          <ChevronLeft :size="20" />
        </button>
        <span class="am-count"
          >{{ filteredFiles.length }}
          <span class="am-count-unit">{{
            filteredFiles.length === 1 ? 'FILE' : 'FILES'
          }}</span></span
        >
        <div v-if="selected" class="am-topbar-actions">
          <template v-if="isDeleted">
            <button type="button" class="am-btn" @click="restore">
              Restore
            </button>
            <button type="button" class="am-btn am-btn--danger" @click="purge">
              Purge
            </button>
          </template>
          <template v-else-if="editing">
            <button
              type="button"
              class="am-btn"
              :disabled="saving"
              @click="editing = false"
            >
              Cancel
            </button>
            <button
              type="button"
              class="am-btn am-btn--primary"
              :disabled="saving"
              @click="save"
            >
              Save
            </button>
          </template>
          <template v-else>
            <button type="button" class="am-btn" @click="startEdit">
              Edit
            </button>
            <button type="button" class="am-btn am-btn--danger" @click="remove">
              Delete
            </button>
          </template>
        </div>
      </div>

      <template v-if="selected">
        <div class="viewer-head">
          <span class="am-path">{{ selected.path }}</span>
          <span class="am-meta">
            <span v-if="selected.pending === 'modified'" class="am-badge"
              >modified</span
            >
            {{ selectedMeta }}
          </span>
        </div>
        <p v-if="actionError" class="am-action-error error">
          {{ actionError }}
        </p>
        <p v-if="isDeleted" class="am-banner">
          Deleted in Servant: agents remove their copy at their next sync.
          Restore to keep the file, purge once every machine has synced.
        </p>
        <div class="am-reading">
          <div class="am-column">
            <textarea
              v-if="editing"
              v-model="draft"
              class="editor"
              aria-label="File body"
              spellcheck="false"
            />
            <div v-if="split.fields.length && !editing" class="am-frontmatter">
              <div
                v-for="field in split.fields"
                :key="`${field.group}.${field.key}`"
                class="am-frontmatter-row"
              >
                <span class="am-frontmatter-key">
                  <span v-if="field.group" class="am-frontmatter-tag">{{
                    field.group
                  }}</span>
                  {{ field.key }}
                </span>
                <span class="am-frontmatter-value">{{ field.value }}</span>
              </div>
            </div>
            <!-- markdown rendered by the shared Notes renderer, which escapes user data -->
            <article v-if="!editing" class="markdown" v-html="rendered" />
          </div>
        </div>
      </template>
      <p v-else class="am-placeholder">Select a file.</p>
    </div>
  </div>
</template>

<style scoped>
.am-layout {
  display: flex;
  height: var(--app-height);
}

.error {
  color: var(--danger);
}

/* ----- Sidebar: search head + tree, same skeleton as Notes ----- */
.tree {
  width: 280px;
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  border-right: 1px solid var(--border);
}

.am-side-head {
  display: flex;
  gap: 0.5rem;
  padding: 0.75rem;
  border-bottom: 1px solid var(--border);
}

.am-tree-toggle {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  border-radius: 6px;
  padding: 0 0.45rem;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  flex-shrink: 0;
}

.am-tree-toggle:hover,
.am-tree-toggle:focus-visible {
  border-color: var(--primary);
  color: var(--primary);
}

.am-search {
  flex: 1;
  min-width: 0;
}

.am-tree {
  flex: 1;
  overflow-y: auto;
  padding: 0.375rem 0.25rem;
}

.nodes {
  list-style: none;
  margin: 0;
  padding: 0;
}

.am-placeholder {
  color: var(--text-muted);
  text-align: center;
  padding: 2.5rem 1rem;
  font-family: var(--font-mono);
  font-size: var(--text-sm);
}

/* ----- Main: topbar with count and actions ----- */
.viewer {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.am-topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  padding: 0.75rem 1.25rem;
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
}

.am-back {
  display: none;
  width: 44px;
  height: 44px;
  margin: -0.5rem 0 -0.5rem -0.75rem;
  padding: 0;
  flex-shrink: 0;
  align-items: center;
  justify-content: center;
  border: none;
  border-radius: 8px;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
}

.am-back:hover,
.am-back:focus-visible {
  color: var(--primary);
}

.am-count {
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  color: var(--text);
  white-space: nowrap;
}

.am-count-unit {
  color: var(--text-muted);
  letter-spacing: 0.08em;
}

.am-topbar-actions {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.am-btn {
  height: 32px;
  padding: 0 0.75rem;
  flex-shrink: 0;
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  font-size: var(--text-sm);
  border-radius: 8px;
  cursor: pointer;
  transition:
    border-color 0.15s,
    color 0.15s;
}

.am-btn:hover,
.am-btn:focus-visible {
  border-color: var(--primary);
  color: var(--primary);
}

.am-btn:disabled {
  opacity: 0.5;
  cursor: default;
}

.am-btn--primary {
  border-color: var(--primary);
  color: var(--primary);
}

.am-btn--danger:hover,
.am-btn--danger:focus-visible {
  border-color: var(--danger);
  color: var(--danger);
}

/* ----- File head: path and meta under the topbar ----- */
.viewer-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 1rem;
  padding: 0.6rem 1.25rem;
  border-bottom: 1px solid var(--border);
  font-family: var(--font-mono);
  font-size: var(--text-sm);
}

.am-path {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--text);
}

.am-meta {
  flex-shrink: 0;
  color: var(--text-muted);
}

.am-badge {
  display: inline-block;
  margin-right: 0.5rem;
  padding: 0 0.45em;
  border-radius: 6px;
  background: rgba(var(--primary-rgb), 0.15);
  color: var(--primary);
  font-size: var(--text-sm);
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

.am-banner {
  margin: 0;
  padding: 0.6rem 1.25rem;
  border-bottom: 1px solid var(--border);
  background: rgba(var(--primary-rgb), 0.08);
  color: var(--text);
  font-size: var(--text-sm);
}

.am-action-error {
  margin: 0;
  padding: 0.5rem 1.25rem;
  font-family: var(--font-mono);
  font-size: var(--text-sm);
}

/* ----- Editor: a modest, resizable textarea in the reading column ----- */
.editor {
  display: block;
  width: 100%;
  box-sizing: border-box;
  min-height: 22rem;
  max-height: 65vh;
  resize: vertical;
  padding: 0.9rem 1.1rem;
  border: 1px solid var(--border);
  border-radius: var(--control-radius);
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  line-height: 1.6;
  background: var(--bg);
  color: var(--text);
}

/* ----- Preview: one reading column holding the frontmatter block and the rendering ----- */
.am-reading {
  flex: 1;
  overflow-y: auto;
  padding: 1.5rem 1.5rem 4rem;
}

/* A fixed rem width (not ch): the column is the same for the mono block, the
   headings and the body, so their left edges line up. */
.am-column {
  max-width: 44rem;
  margin: 0 auto;
}

.am-frontmatter {
  margin: 0 0 1.75rem;
  padding: 0.9rem 1.1rem;
  border: 1px solid var(--border);
  border-radius: 8px;
  background: var(--bg-surface);
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  line-height: 1.5;
}

.am-frontmatter-row {
  display: flex;
  align-items: baseline;
  gap: 1rem;
  padding: 0.25rem 0;
}

.am-frontmatter-key {
  flex: 0 0 12rem;
  display: flex;
  align-items: baseline;
  gap: 0.4rem;
  min-width: 0;
  color: var(--text-muted);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.am-frontmatter-tag {
  flex-shrink: 0;
  background: rgba(var(--primary-rgb), 0.15);
  color: var(--primary);
  border-radius: 6px;
  padding: 0 0.4em;
  font-size: 0.875em;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

.am-frontmatter-value {
  flex: 1;
  min-width: 0;
  color: var(--text);
  overflow-wrap: anywhere;
}

.markdown {
  font-size: var(--text-md);
  line-height: 1.7;
}

.markdown :deep(h1),
.markdown :deep(h2),
.markdown :deep(h3) {
  margin: 1.4em 0 0.6em;
  line-height: 1.3;
}

.markdown :deep(h1:first-child),
.markdown :deep(h2:first-child) {
  margin-top: 0;
}

.markdown :deep(p) {
  margin: 0.8em 0;
}

.markdown :deep(li) {
  margin: 0.25em 0;
}

.markdown :deep(code) {
  background: var(--bg-surface);
  padding: 0.1em 0.35em;
  border-radius: 4px;
  font-size: 0.875em;
}

.markdown :deep(pre) {
  background: var(--bg-surface);
  padding: 0.75rem;
  border-radius: 8px;
  overflow-x: auto;
}

.markdown :deep(pre code) {
  background: none;
  padding: 0;
}

.markdown :deep(a) {
  color: var(--primary);
}

.markdown :deep(ul),
.markdown :deep(ol) {
  padding-left: 1.4em;
}

.markdown :deep(blockquote) {
  border-left: 3px solid var(--border);
  padding-left: 0.8em;
  color: var(--text-muted);
}

.markdown :deep(table) {
  display: block;
  overflow-x: auto;
  border-collapse: collapse;
}

.markdown :deep(th),
.markdown :deep(td) {
  border: 1px solid var(--border);
  padding: 0.25em 0.6em;
  text-align: left;
}

.markdown :deep(.nt-tag) {
  display: inline-block;
  background: rgba(var(--primary-rgb), 0.15);
  color: var(--primary);
  border-radius: 6px;
  padding: 0 0.4em;
  font-size: 0.875em;
}

/* ----- Responsive ----- */
@media (max-width: 1024px) {
  .tree {
    width: 240px;
  }

  /* Path and meta stack instead of truncating the path. */
  .viewer-head {
    flex-wrap: wrap;
    gap: 0.25rem 1rem;
  }

  .am-path {
    white-space: normal;
    overflow-wrap: anywhere;
  }

  .am-meta {
    flex-shrink: 1;
  }
}

@media (pointer: coarse) {
  .am-tree-toggle {
    min-width: 40px;
  }

  .am-btn {
    height: 40px;
  }
}

/* Phone: one pane at a time, the tree until a file is open. */
@media (max-width: 640px) {
  .tree {
    width: auto;
    flex: 1;
    border-right: none;
  }

  .viewer {
    display: none;
  }

  .am-layout--detail .tree {
    display: none;
  }

  .am-layout--detail .viewer {
    display: flex;
  }

  .am-back {
    display: inline-flex;
  }

  .am-topbar {
    flex-wrap: wrap;
    padding: 0.5rem 1rem;
  }

  .am-count {
    margin-right: auto;
  }

  .viewer-head {
    padding: 0.6rem 1rem;
  }

  .am-reading {
    padding: 1rem 1rem 3rem;
  }

  .am-frontmatter-row {
    flex-direction: column;
    gap: 0.1rem;
  }

  .am-frontmatter-key {
    flex: none;
  }
}
</style>
