import type { Directive } from 'vue'

// Makes a non-<button> element carrying role="button" keyboard-activatable:
// Enter and Space trigger its existing @click handler (WCAG 2.1.1). The listener
// dies with the element, so no explicit teardown is needed.
export const vClickKey: Directive<HTMLElement> = {
  mounted(el) {
    el.addEventListener('keydown', (e: KeyboardEvent) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault()
        el.click()
      }
    })
  }
}
