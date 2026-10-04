import { config } from '@vue/test-utils'
import { vAutofocus } from './lib/autofocus'
import { vClickKey } from './lib/clickKey'

// Teleported content (ComboBox panel, modals) renders in place during tests
// so wrapper.find keeps seeing it.
config.global.stubs = { teleport: true }

// The directives main.ts registers on the app: without them every mount of a
// component using v-autofocus or v-click-key warns "Failed to resolve directive".
config.global.directives = { autofocus: vAutofocus, 'click-key': vClickKey }

// jsdom has no <dialog> interactivity: polyfill the three methods so the
// native-dialog modals (lib/dialog.ts openDialog, ConfirmModal, ...) can
// open and close in tests. The [open] attribute mirrors the real behavior.
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
