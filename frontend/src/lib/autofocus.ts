import type { Directive } from 'vue'

// Sets the default focus when a page opens (AGENTS.md accessibility rules).
// The focus goes to the search field when the page has one. If not, it goes
// to a navigation button. The forms with a conditional render also use this
// directive (for example the TOTP step of the login page). On dynamic
// inserts, the native autofocus attribute is not reliable. An optional
// binding value controls the focus, so a v-for can target its first item:
// v-autofocus="index === 0".
export const vAutofocus: Directive<HTMLElement> = {
  mounted: (el, binding) => {
    if (binding.value !== false) el.focus()
  }
}
