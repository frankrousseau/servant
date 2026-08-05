<script setup lang="ts">
import { computed } from 'vue'
import {
  ArrowLeftRight,
  CalendarDays,
  CircleDot,
  FileText,
  Heart,
  Image,
  Landmark,
  Link,
  Mail,
  Receipt,
  StickyNote,
  UserRound
} from 'lucide-vue-next'

import { kindColor } from '../lib/kind'

// Decorative by default (the icon usually sits next to the kind's name);
// pass a label when the icon stands alone so assistive tech announces it.
const props = withDefaults(
  defineProps<{
    kind: string
    size?: number
    label?: string
  }>(),
  { size: 16, label: undefined }
)

// The lucide component per kind is render-layer knowledge and stays here;
// the color comes from the shared kind palette in lib/kind.ts.
const iconMap: Record<string, typeof ArrowLeftRight> = {
  transaction: ArrowLeftRight,
  bank_tx: Landmark,
  blockchain_tx: Link,
  article: FileText,
  email: Mail,
  photo: Image,
  contact: UserRound,
  note: StickyNote,
  event: CalendarDays,
  invoice: Receipt,
  health: Heart
}

const icon = computed(() => iconMap[props.kind] || CircleDot)
const color = computed(() => kindColor(props.kind))
</script>

<template>
  <span
    class="kind-icon"
    :role="label ? 'img' : undefined"
    :aria-label="label"
    :aria-hidden="label ? undefined : 'true'"
    :style="{
      background: color,
      width: size + 12 + 'px',
      height: size + 12 + 'px'
    }"
  >
    <component :is="icon" :size="size" color="#fff" />
  </span>
</template>

<style scoped>
.kind-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border-radius: var(--radius, 6px);
  flex-shrink: 0;
}
</style>
