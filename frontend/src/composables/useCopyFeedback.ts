import { ref } from 'vue'

// Copies to the clipboard and remembers what was copied for a moment, so
// the button that did it can say "Copied".
export function useCopyFeedback(delay = 1500) {
  const copiedId = ref<string | null>(null)

  function copy(text: string, id: string) {
    void navigator.clipboard.writeText(text)
    copiedId.value = id
    setTimeout(() => {
      if (copiedId.value === id) copiedId.value = null
    }, delay)
  }

  return { copiedId, copy }
}
