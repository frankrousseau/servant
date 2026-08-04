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

const props = withDefaults(
  defineProps<{
    kind: string
    size?: number
  }>(),
  { size: 16 }
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
