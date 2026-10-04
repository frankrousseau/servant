import { config } from '@vue/test-utils'
import { vAutofocus } from './lib/autofocus'
import { vClickKey } from './lib/clickKey'

// In tests, teleported content (the ComboBox panel, the modals) renders in
// place. As a result, wrapper.find can find it.
config.global.stubs = { teleport: true }

// These are the directives that main.ts registers on the app. Without them,
// each mount of a component that uses v-autofocus or v-click-key gives the
// warning "Failed to resolve directive".
config.global.directives = { autofocus: vAutofocus, 'click-key': vClickKey }

// jsdom has no <dialog> interactivity. Polyfill the three methods. Then the
// native-dialog modals (openDialog of lib/dialog.ts, ConfirmModal and others)
// can open and close in tests. The [open] attribute mirrors the real behavior.
if (typeof HTMLDialogElement !== 'undefined') {
  HTMLDialogElement.prototype.showModal ??= function (this: HTMLDialogElement) {
    this.setAttribute('open', '')
  }
  HTMLDialogElement.prototype.show ??= function (this: HTMLDialogElement) {
    this.setAttribute('open', '')
  }
  HTMLDialogElement.prototype.close ??= function (this: HTMLDialogElement) {
    this.removeAttribute('open')
    this.dispatchEvent(new Event('close'))
  }
}
