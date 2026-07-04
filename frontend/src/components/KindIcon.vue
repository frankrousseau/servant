<script setup lang="ts">
import {
  ArrowLeftRight,
  Landmark,
  Link,
  FileText,
  Mail,
  Image,
  UserRound,
  StickyNote,
  CalendarDays,
  Receipt,
  Heart,
  CircleDot,
} from "lucide-vue-next";
import { computed } from "vue";

const props = withDefaults(
  defineProps<{
    kind: string;
    size?: number;
  }>(),
  { size: 16 },
);

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
};

const colorMap: Record<string, string> = {
  transaction: "#9d7bff",
  bank_tx: "#4a9c6d",
  blockchain_tx: "#9b6cff",
  article: "#f0a06c",
  email: "#5cc98a",
  photo: "#c96cd0",
  contact: "#6ccec9",
  note: "#e0d56c",
  event: "#e07c5a",
  invoice: "#8b6cff",
  health: "#e05577",
};

const icon = computed(() => iconMap[props.kind] || CircleDot);
const color = computed(() => colorMap[props.kind] || "#8b8fa3");
</script>

<template>
  <span
    class="kind-icon"
    :style="{ background: color, width: size + 12 + 'px', height: size + 12 + 'px' }"
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
