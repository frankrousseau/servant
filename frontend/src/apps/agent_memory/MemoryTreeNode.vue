<script setup lang="ts">
import type { TreeNode } from './tree'

defineProps<{ node: TreeNode; selectedPath: string | null }>()

const emit = defineEmits<{ select: [node: TreeNode] }>()
</script>

<template>
  <button
    v-if="node.file"
    type="button"
    class="file"
    :class="{ 'file--active': node.path === selectedPath }"
    @click="emit('select', node)"
  >
    {{ node.name }}
  </button>
  <details v-else open>
    <summary>{{ node.name }}</summary>
    <ul class="nodes">
      <li v-for="child in node.children" :key="child.path">
        <MemoryTreeNode
          :node="child"
          :selected-path="selectedPath"
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

summary {
  cursor: pointer;
  padding: 0.15rem 0;
  font-family: var(--font-mono);
  font-size: 0.85rem;
}

.file {
  display: block;
  width: 100%;
  padding: 0.15rem 0.4rem;
  border: 0;
  border-radius: 4px;
  background: none;
  color: var(--text);
  font-family: var(--font-mono);
  font-size: 0.85rem;
  text-align: left;
  cursor: pointer;
}

.file:hover {
  background: var(--bg-hover);
}

.file--active {
  background: var(--primary);
  color: var(--primary-contrast);
}
</style>
