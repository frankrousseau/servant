<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'

import MemoryTreeNode from './MemoryTreeNode.vue'

import { formatDateTime } from '../../lib/datetime'
import { renderMarkdown } from '../notes/render'
import { splitFrontmatter } from './frontmatter'
import { buildTree } from './tree'
import type { AppContext } from '../types'
import type { MemoryFile, TreeNode } from './tree'

const props = defineProps<{ ctx: AppContext }>()

const files = ref<MemoryFile[]>([])
const loading = ref(true)
const loadError = ref('')
const actionError = ref('')
const search = ref('')
const searchInput = ref<HTMLInputElement | null>(null)
const selectedPath = ref<string | null>(null)
const editing = ref(false)
const draft = ref('')
const saving = ref(false)

const filteredFiles = computed(() => {
  const needle = search.value.trim().toLowerCase()
  if (!needle) return files.value
  return files.value.filter(memoryFile =>
    memoryFile.path.toLowerCase().includes(needle)
  )
})

const tree = computed(() => buildTree(filteredFiles.value))

const selected = computed(
  () =>
    files.value.find(memoryFile => memoryFile.path === selectedPath.value) ??
    null
)

const split = computed(() => splitFrontmatter(selected.value?.body ?? ''))

const rendered = computed(() =>
  selected.value ? renderMarkdown(split.value.content, () => null) : ''
)

const selectedMeta = computed(() => {
  if (!selected.value) return ''
  return `${selected.value.tool} · ${selected.value.size} bytes · ${formatDateTime(selected.value.updated_at)}`
})

async function load() {
  loading.value = true
  loadError.value = ''
  try {
    const res = await props.ctx.api.fetch('/api/agent_memory?include=body')
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    files.value = json.data
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : String(err)
  } finally {
    loading.value = false
  }
}

function select(node: TreeNode) {
  if (!node.file) return
  selectedPath.value = node.file.path
  editing.value = false
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

async function remove() {
  if (!selected.value) return
  const ok = await props.ctx.confirm.ask({
    title: 'Delete file',
    message: `Delete ${selected.value.path}? Agents will not pull it any more.`,
    confirmLabel: 'Delete',
    danger: true
  })
  if (!ok) return
  actionError.value = ''
  const path = selected.value.path
  try {
    const res = await props.ctx.api.fetch(
      `/api/agent_memory?path=${encodeURIComponent(path)}`,
      { method: 'DELETE' }
    )
    if (!res.ok) {
      actionError.value = `HTTP ${res.status}`
      return
    }
    files.value = files.value.filter(memoryFile => memoryFile.path !== path)
    selectedPath.value = null
  } catch (err) {
    actionError.value = err instanceof Error ? err.message : String(err)
  }
}

onMounted(() => {
  load()
  // Apps are mounted as separate Vue instances after a dynamic import, so the
  // native `autofocus` attribute below is never honored; focus by hand.
  searchInput.value?.focus()
})
</script>

<template>
  <div class="am-layout">
    <div class="tree">
      <div class="am-side-head">
        <input
          ref="searchInput"
          v-model="search"
          type="search"
          class="am-search"
          placeholder="Filter by path"
          aria-label="Filter files by path"
        />
      </div>
      <div class="am-tree">
        <p v-if="loading" class="am-placeholder">Loading…</p>
        <p v-else-if="loadError" class="am-placeholder error">
          {{ loadError }}
        </p>
        <p v-else-if="tree.length === 0" class="am-placeholder">
          No files yet. Run the servant-memory skill's push script from a repo.
        </p>
        <ul v-else class="nodes">
          <li v-for="node in tree" :key="node.path">
            <MemoryTreeNode
              :node="node"
              :selected-path="selectedPath"
              @select="select"
            />
          </li>
        </ul>
      </div>
    </div>

    <div class="viewer">
      <div class="am-topbar">
        <span class="am-count"
          >{{ filteredFiles.length }}
          <span class="am-count-unit">{{
            filteredFiles.length === 1 ? 'FILE' : 'FILES'
          }}</span></span
        >
        <div v-if="selected" class="am-topbar-actions">
          <template v-if="editing">
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
          <span class="am-meta">{{ selectedMeta }}</span>
        </div>
        <p v-if="actionError" class="am-action-error error">
          {{ actionError }}
        </p>
        <textarea
          v-if="editing"
          v-model="draft"
          class="editor"
          aria-label="File body"
          spellcheck="false"
        />
        <div v-else class="am-reading">
          <dl v-if="split.fields.length" class="am-frontmatter">
            <div
              v-for="field in split.fields"
              :key="field.key"
              class="am-frontmatter-row"
            >
              <dt>{{ field.key }}</dt>
              <dd>{{ field.value }}</dd>
            </div>
          </dl>
          <!-- markdown rendered by the shared Notes renderer, which escapes user data -->
          <article class="markdown" v-html="rendered" />
        </div>
      </template>
      <p v-else class="am-placeholder">Select a file.</p>
    </div>
  </div>
</template>

<style scoped>
.am-layout {
  display: flex;
  height: 100vh;
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
  padding: 0.75rem;
  border-bottom: 1px solid var(--border);
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
  font-size: 0.88rem;
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
  padding: 0.75rem 1.25rem;
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
}

.am-count {
  font-family: var(--font-mono);
  font-size: 0.85rem;
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
  font-size: 0.85rem;
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
  font-size: 0.8rem;
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

.am-action-error {
  margin: 0;
  padding: 0.5rem 1.25rem;
  font-family: var(--font-mono);
  font-size: 0.85rem;
}

/* ----- Editor: the raw markdown pane of Notes ----- */
.editor {
  flex: 1;
  border: none;
  border-radius: 0;
  resize: none;
  padding: 1rem 1.25rem;
  font-family: var(--font-mono);
  font-size: 0.9rem;
  line-height: 1.6;
  background: var(--bg);
  color: var(--text);
}

.editor:focus {
  outline: none;
}

/* ----- Preview: frontmatter block, then Notes rendering, in a reading column ----- */
.am-reading {
  flex: 1;
  overflow-y: auto;
  padding: 1rem 1.25rem 3rem;
}

.am-frontmatter {
  max-width: 72ch;
  margin: 0 auto 1rem;
  padding: 0.6rem 0.9rem;
  border: 1px solid var(--border);
  border-radius: 8px;
  background: var(--bg-surface);
  font-family: var(--font-mono);
  font-size: 0.8rem;
}

.am-frontmatter-row {
  display: flex;
  gap: 0.75rem;
  padding: 0.15rem 0;
}

.am-frontmatter dt {
  flex: 0 0 11rem;
  color: var(--text-muted);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.am-frontmatter dd {
  margin: 0;
  min-width: 0;
  color: var(--text);
}

.markdown {
  line-height: 1.65;
}

.markdown > :deep(*) {
  max-width: 72ch;
  margin-left: auto;
  margin-right: auto;
}

.markdown :deep(h1),
.markdown :deep(h2),
.markdown :deep(h3) {
  margin-top: 0.8em;
  margin-bottom: 0.4em;
}

.markdown :deep(p) {
  margin-top: 0.5em;
  margin-bottom: 0.5em;
}

.markdown :deep(code) {
  background: var(--bg-surface);
  padding: 0.1em 0.35em;
  border-radius: 4px;
  font-size: 0.85em;
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
  font-size: 0.85em;
}

@media (max-width: 800px) {
  .am-layout {
    flex-direction: column;
    height: auto;
  }

  .tree {
    width: auto;
    max-height: 40vh;
    border-right: none;
    border-bottom: 1px solid var(--border);
  }
}
</style>
