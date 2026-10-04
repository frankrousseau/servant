<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import flatpickr from 'flatpickr'
import 'flatpickr/dist/flatpickr.min.css'

// A themed replacement for <input type="date">. It has the same "YYYY-MM-DD"
// string contract, but the popup is flatpickr. The global overrides in
// style.css give the popup its style. The native calendar follows only
// light/dark, never the palette.
const props = defineProps<{
  modelValue: string
  max?: string
  title?: string
  placeholder?: string
}>()
const emit = defineEmits<{ 'update:modelValue': [value: string] }>()

const input = ref<HTMLInputElement | null>(null)
let fp: flatpickr.Instance | null = null

onMounted(() => {
  fp = flatpickr(input.value!, {
    dateFormat: 'Y-m-d',
    maxDate: props.max,
    defaultDate: props.modelValue || undefined,
    // Let the user clear an optional field (filters, birthday, token expiry):
    // the user deletes the text. The native date input also had a clear
    // affordance.
    allowInput: true,
    onChange: (_dates, str) => emit('update:modelValue', str),
    onClose: (_dates, str) => {
      if (str !== props.modelValue) emit('update:modelValue', str)
    }
  }) as flatpickr.Instance
})

watch(
  () => props.modelValue,
  value => {
    if (!fp) return
    if (!value) fp.clear(false)
    else fp.setDate(value, false)
  }
)
watch(
  () => props.max,
  max => fp?.set('maxDate', max)
)

onBeforeUnmount(() => fp?.destroy())
</script>

<template>
  <input ref="input" type="text" :title="title" :placeholder="placeholder" />
</template>
