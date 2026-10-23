import { ref } from 'vue'

// Shared open state: the palette listens for Ctrl+K itself, and the mobile top
// bar opens it from a button (a phone has no keyboard shortcut to reach it).
const open = ref(false)

export function useCommandPalette() {
  function toggle() {
    open.value = !open.value
  }

  return { open, toggle }
}
