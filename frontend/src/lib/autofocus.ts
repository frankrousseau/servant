import type { Directive } from 'vue'

// Default landing focus for a page (AGENTS.md accessibility rules): the
// search field when the page has one, else a navigation button. Also used
// by conditionally rendered forms (e.g. the TOTP step of the login page),
// where the native autofocus attribute is unreliable on dynamic inserts.
// An optional binding value gates the focus, so a v-for can target its
// first item: v-autofocus="index === 0".
export const vAutofocus: Directive<HTMLElement> = {
  mounted: (el, binding) => {
    if (binding.value !== false) el.focus()
  }
}
