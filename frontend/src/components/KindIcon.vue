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
  ListChecks,
  Mail,
  Receipt,
  StickyNote,
  UserRound
} from 'lucide-vue-next'

import { kindColor } from '../lib/kind'

// The icon is decorative by default, because it is usually next to the name
// of the kind. Pass a label when the icon is alone, so that assistive tech
// announces it. `plain` drops the kind-colored tile and draws the glyph in
// the current text color. It is for the hosts that give a theme to the badge
// around the icon themselves.
const props = withDefaults(
  defineProps<{
    kind: string
    size?: number
    label?: string
    plain?: boolean
  }>(),
  { size: 16, label: undefined, plain: false }
)

// The lucide component for each kind is knowledge of the render layer and
// stays here. The color comes from the shared kind palette in lib/kind.ts.
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
  health: Heart,
  checklist: ListChecks
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
    :style="
      plain
        ? undefined
        : {
            background: color,
            width: size + 12 + 'px',
            height: size + 12 + 'px'
          }
    "
  >
    <component :is="icon" :size="size" :color="plain ? undefined : '#fff'" />
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
