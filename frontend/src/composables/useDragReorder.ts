import { computed, ref } from 'vue'

export type DropMark = 'before' | 'after'

// Native drag and drop to reorder a list of ids (the sidebar's pinned apps,
// the Apps page's order column). Hovering a row marks the gap under the
// pointer: its top half drops before it, its bottom half after it. `marks`
// says which row draws that gap, keyed by id, and leaves out the gaps that
// would put the item back where it is. Drags that did not start in this
// list (a file from the desktop) are ignored.
//
// Keyboard and touch users get the arrow buttons of the Apps page: HTML
// drag and drop is mouse-only on most touch browsers.
export function useDragReorder(
  ids: () => string[],
  place: (id: string, toIndex: number) => void
) {
  const draggingId = ref<string | null>(null)
  // Insertion point in the list as displayed, 0..length
  const gap = ref<number | null>(null)

  const marks = computed<Record<string, DropMark>>(() => {
    const list = ids()
    const from = draggingId.value ? list.indexOf(draggingId.value) : -1
    if (from === -1 || gap.value === null) return {}
    if (gap.value === from || gap.value === from + 1) return {}
    return gap.value < list.length
      ? { [list[gap.value]]: 'before' }
      : { [list[list.length - 1]]: 'after' }
  })

  function onDragStart(id: string, event: DragEvent) {
    draggingId.value = id
    const transfer = event.dataTransfer
    if (!transfer) return
    transfer.effectAllowed = 'move'
    // Firefox starts no drag without data
    transfer.setData('text/plain', id)
    // A link's default drag image is its URL; show the row instead
    const row = event.currentTarget as HTMLElement
    const box = row.getBoundingClientRect()
    transfer.setDragImage(
      row,
      event.clientX - box.left,
      event.clientY - box.top
    )
  }

  function onDragOver(index: number, event: DragEvent) {
    if (!draggingId.value) return
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
    const box = (event.currentTarget as HTMLElement).getBoundingClientRect()
    gap.value = event.clientY < box.top + box.height / 2 ? index : index + 1
  }

  // On the list element: the pointer left the list for good (not just
  // crossed from one row to the next), so no gap stays marked.
  function onDragLeave(event: DragEvent) {
    const list = event.currentTarget as HTMLElement
    if (!list.contains(event.relatedTarget as Node | null)) gap.value = null
  }

  function onDrop(event: DragEvent) {
    if (!draggingId.value) return
    event.preventDefault()
    const from = ids().indexOf(draggingId.value)
    if (from !== -1 && gap.value !== null) {
      // The gap counts the dragged row itself, which leaves its slot first
      const to = gap.value > from ? gap.value - 1 : gap.value
      if (to !== from) place(draggingId.value, to)
    }
    onDragEnd()
  }

  function onDragEnd() {
    draggingId.value = null
    gap.value = null
  }

  return {
    draggingId,
    marks,
    onDragStart,
    onDragOver,
    onDragLeave,
    onDrop,
    onDragEnd
  }
}
