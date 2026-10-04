import type { Directive } from 'vue'

// Lets the keyboard activate an element that is not a <button> and that has
// role="button". Enter and Space trigger its existing @click handler (WCAG
// 2.1.1). The listener goes away with the element, so an explicit teardown is
// not necessary.
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
