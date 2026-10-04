import { ref } from 'vue'

const visible = ref(false)
const title = ref('')
const message = ref('')
const confirmLabel = ref('Delete')
const danger = ref(true)
let resolveFn: ((value: boolean) => void) | null = null

export function useConfirm() {
  function ask(opts: {
    title?: string
    message: string
    confirmLabel?: string
    danger?: boolean
  }): Promise<boolean> {
    // There is a single shared modal. A previous ask() can still be pending
    // (its promise never settled). If so, resolve it as canceled before you
    // use the slot again. If not, that awaiter would hang forever, and the UI
    // that awaited it would freeze.
    if (resolveFn) {
      resolveFn(false)
      resolveFn = null
    }

    title.value = opts.title || 'Confirm'
    message.value = opts.message
    confirmLabel.value = opts.confirmLabel || 'Delete'
    danger.value = opts.danger ?? true
    visible.value = true

    return new Promise(resolve => {
      resolveFn = resolve
    })
  }

  function resolve(value: boolean) {
    visible.value = false
    resolveFn?.(value)
    resolveFn = null
  }

  return { visible, title, message, confirmLabel, danger, ask, resolve }
}
