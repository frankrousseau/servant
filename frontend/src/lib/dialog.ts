// A template ref callback for the native dialogs that a v-if mounts. It opens
// them as modals (focus trap, Escape, top layer) immediately when the element
// appears.
// Usage: <dialog :ref="openDialog" class="modal-dialog" ...>
export function openDialog(el: unknown) {
  const dialog = el as HTMLDialogElement | null
  if (dialog && !dialog.open) dialog.showModal()
}
