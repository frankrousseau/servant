<script setup lang="ts">
import type { TreeNode } from './tree'

// Harness roots (depth 0) and their sections (depth 1) stay open;
// expand/collapse all acts on the third level (projects, skills).
withDefaults(
  defineProps<{
    node: TreeNode
    selectedPath: string | null
    expanded: boolean
    depth?: number
  }>(),
  { depth: 0 }
)

const emit = defineEmits<{ select: [node: TreeNode] }>()
</script>

<template>
  <button
    v-if="node.file"
    type="button"
    class="file"
    :class="{ 'file--active': node.path === selectedPath }"
    :aria-current="node.path === selectedPath ? 'true' : undefined"
    @click="emit('select', node)"
  >
    <span class="file-name">{{ node.name }}</span>
  </button>
  <details v-else :open="depth < 2 || expanded">
    <summary class="folder">
      <span class="folder-caret" aria-hidden="true"></span>
      <span class="folder-name">{{ node.name }}</span>
    </summary>
    <ul class="nodes">
      <li v-for="child in node.children" :key="child.path">
        <MemoryTreeNode
          :node="child"
          :selected-path="selectedPath"
          :expanded="expanded"
          :depth="depth + 1"
          @select="emit('select', $event)"
        />
      </li>
    </ul>
  </details>
</template>

<style scoped>
.nodes {
  list-style: none;
  margin: 0;
  padding-left: 0.75rem;
}

/* ----- Folders: structure, same mono uppercase labels as the Notes tree ----- */
.folder {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.4rem;
  margin-top: 0.4rem;
  border-radius: 6px;
  cursor: pointer;
  list-style: none;
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.76rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  user-select: none;
}

.folder::-webkit-details-marker {
  display: none;
}

.folder:hover {
  background: var(--bg-hover);
}

.folder-caret {
  width: 0.9em;
  flex-shrink: 0;
}

.folder-caret::before {
  content: '\25B8';
}

details[open] > .folder .folder-caret::before {
  content: '\25BE';
}

.folder-name {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* ----- Files: the note rows of Notes, violet rail when selected ----- */
.file {
  display: flex;
  align-items: center;
  width: 100%;
  padding: 0.45rem 0.5rem;
  border: 0;
  border-radius: 6px;
  background: none;
  color: inherit;
  font: inherit;
  font-size: 0.92rem;
  text-align: left;
  cursor: pointer;
}

.file-name {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.file:hover {
  background: var(--bg-hover);
}

.file--active {
  background: rgba(var(--primary-rgb), 0.1);
  box-shadow: inset 2px 0 0 var(--primary);
  border-radius: 0 6px 6px 0;
}
</style>
