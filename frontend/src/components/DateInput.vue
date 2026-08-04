<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import flatpickr from 'flatpickr'
import 'flatpickr/dist/flatpickr.min.css'

// Themed replacement for <input type="date">: same "YYYY-MM-DD" string
// contract, but the popup is flatpickr, styled by the global overrides in
// style.css (the native calendar only follows light/dark, never the
// palette).
const props = defineProps<{
  modelValue: string
  max?: string
  title?: string
}>()
const emit = defineEmits<{ 'update:modelValue': [value: string] }>()

const input = ref<HTMLInputElement | null>(null)
let fp: flatpickr.Instance | null = null

onMounted(() => {
  fp = flatpickr(input.value!, {
    dateFormat: 'Y-m-d',
    maxDate: props.max,
    defaultDate: props.modelValue || undefined,
    // Let optional fields (filters, birthday, token expiry) be cleared by
    // deleting the text; the native date input had a clear affordance too.
    allowInput: true,
    onChange: (_dates, str) => emit('update:modelValue', str),
    onClose: (_dates, str) => {
      if (str !== props.modelValue) emit('update:modelValue', str)
    }
  }) as flatpickr.Instance
})

watch(
  () => props.modelValue,
  v => {
    if (!fp) return
    if (!v) fp.clear(false)
    else fp.setDate(v, false)
  }
)
watch(
  () => props.max,
  m => fp?.set('maxDate', m)
)

onBeforeUnmount(() => fp?.destroy())
</script>

<template>
  <input ref="input" type="text" :title="title" />
</template>
