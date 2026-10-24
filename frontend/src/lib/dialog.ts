import type flatpickr from 'flatpickr'

// A template ref callback for the native dialogs that a v-if mounts. It opens
// them as modals (focus trap, Escape, top layer) immediately when the element
// appears.
// Usage: <dialog :ref="openDialog" class="modal-dialog" ...>
export function openDialog(el: unknown) {
  const dialog = el as HTMLDialogElement | null
  if (dialog && !dialog.open) dialog.showModal()
}

// Flatpickr options for a date input that may sit in a modal dialog. The
// picker renders on document.body by default, under the top layer where a
// modal dialog lives, so no z-index can lift it over the modal. Inside a
// dialog it mounts in the dialog itself and takes fixed coordinates: fixed
// also keeps it out of the dialog's overflow clipping.
export function pickerPlacement(
  input: HTMLElement
): Pick<flatpickr.Options.Options, 'appendTo' | 'position'> {
  const dialog = input.closest('dialog')
  if (!dialog) return {}
  return { appendTo: dialog, position: placeFixed }
}

const GAP = 2

function placeFixed(instance: flatpickr.Instance, custom?: HTMLElement) {
  const calendar = instance.calendarContainer
  const bounds = (custom || instance._positionElement).getBoundingClientRect()
  const height = calendar.offsetHeight
  const width = calendar.offsetWidth
  const above =
    window.innerHeight - bounds.bottom < height + GAP &&
    bounds.top > height + GAP
  calendar.classList.toggle('arrowTop', !above)
  calendar.classList.toggle('arrowBottom', above)
  calendar.classList.add('arrowLeft')
  calendar.style.position = 'fixed'
  calendar.style.top = `${above ? bounds.top - height - GAP : bounds.bottom + GAP}px`
  calendar.style.left = `${Math.max(0, Math.min(bounds.left, window.innerWidth - width))}px`
  calendar.style.right = 'auto'
}
