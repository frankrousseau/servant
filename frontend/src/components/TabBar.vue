<script lang="ts">
import type { Component } from 'vue'

export interface TabOption<V extends string = string> {
  value: V
  label: string
  icon?: Component
}
</script>

<script setup lang="ts" generic="T extends string">
import { computed, nextTick, ref, useId, useSlots } from 'vue'

// The Servant tab strip: a role="tablist" of buttons bound to v-model, with
// the keyboard model assistive tech expects (one Tab stop on the selected
// tab, Left/Right/Home/End to move, selection follows focus). Section tabs
// (Finance, Audit) use the underline look; view switches (Grid/List, edit
// modes) the compact pill look.
//
// <TabBar v-model="tab" :options="TABS" label="Finance sections">
//   <OverviewView v-if="tab === 'overview'" />...
// </TabBar>
// With content, the bar wraps it in the matching role="tabpanel". Without
// (a view switch in a header, far from what it switches), it renders the
// strip alone and leaves aria-controls out rather than point at nothing.
const props = withDefaults(
  defineProps<{
    modelValue: T
    options: TabOption<T>[]
    // Accessible name of the strip: what the tabs switch between.
    label: string
    variant?: 'underline' | 'pill'
  }>(),
  { variant: 'underline' }
)
const emit = defineEmits<{ 'update:modelValue': [value: T] }>()

const slots = useSlots()
const baseId = useId()
const buttons = ref<HTMLButtonElement[]>([])
const hasPanel = computed(() => Boolean(slots.default))

const tabId = (value: T) => `${baseId}-tab-${value}`
const panelId = `${baseId}-panel`

async function select(index: number) {
  const option = props.options[index]
  if (!option) return
  emit('update:modelValue', option.value)
  await nextTick()
  buttons.value[index]?.focus()
}

function onKeydown(event: KeyboardEvent, index: number) {
  const last = props.options.length - 1
  const target = {
    ArrowRight: index === last ? 0 : index + 1,
    ArrowLeft: index === 0 ? last : index - 1,
    Home: 0,
    End: last
  }[event.key]
  if (target === undefined) return
  event.preventDefault()
  select(target)
}
</script>

<template>
  <div
    class="tab-bar"
    :class="`tab-bar--${variant}`"
    role="tablist"
    :aria-label="label"
  >
    <button
      v-for="(option, index) in options"
      :id="tabId(option.value)"
      :key="option.value"
      ref="buttons"
      type="button"
      role="tab"
      class="tab-bar-tab"
      :class="{ 'tab-bar-tab--active': option.value === modelValue }"
      :aria-selected="option.value === modelValue"
      :aria-controls="hasPanel ? panelId : undefined"
      :tabindex="option.value === modelValue ? 0 : -1"
      @click="select(index)"
      @keydown="onKeydown($event, index)"
    >
      <component :is="option.icon" v-if="option.icon" :size="15" />
      {{ option.label }}
    </button>
  </div>
  <div
    v-if="hasPanel"
    :id="panelId"
    role="tabpanel"
    class="tab-bar-panel"
    :aria-labelledby="tabId(modelValue)"
  >
    <slot />
  </div>
</template>

<style scoped>
.tab-bar {
  display: flex;
  gap: 0.25rem;
}

.tab-bar-tab {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  background: transparent;
  border: none;
  color: var(--text-muted);
  cursor: pointer;
  white-space: nowrap;
}

.tab-bar-tab:hover {
  color: var(--text);
}

/* ----- Underline: section tabs ----- */
.tab-bar--underline {
  overflow-x: auto;
  border-bottom: 1px solid var(--border);
  margin-bottom: 1rem;
}

.tab-bar--underline .tab-bar-tab {
  font-family: var(--font-mono);
  font-size: 0.8rem;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  padding: 0.5rem 0.9rem;
  border-radius: 0;
}

.tab-bar--underline .tab-bar-tab--active {
  color: var(--primary);
  box-shadow: inset 0 -2px 0 var(--primary);
}

/* ----- Pill: compact view switch ----- */
.tab-bar--pill {
  gap: 0.2rem;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--control-radius);
  padding: 2px;
}

.tab-bar--pill .tab-bar-tab {
  font-size: 0.85rem;
  padding: 0.3rem 0.7rem;
  border-radius: calc(var(--control-radius) - 2px);
}

.tab-bar--pill .tab-bar-tab--active,
.tab-bar--pill .tab-bar-tab--active:hover {
  background: var(--primary);
  color: var(--primary-contrast);
}

@media (pointer: coarse) {
  .tab-bar-tab {
    min-height: 44px;
  }
}
</style>
