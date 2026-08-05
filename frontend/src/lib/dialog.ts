// Template ref callback for v-if mounted native dialogs: opens them modal
// (focus trap, Escape, top layer) as soon as the element appears.
// Usage: <dialog :ref="openDialog" class="modal-dialog" ...>
export function openDialog(el: unknown) {
  const dialog = el as HTMLDialogElement | null
  if (dialog && !dialog.open) dialog.showModal()
}
