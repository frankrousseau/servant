import { describe, expect, it, vi } from 'vitest'

import { useDragReorder } from './useDragReorder'

// A row 40px tall at the top of the viewport: clientY under 20 is its top
// half, from 20 its bottom half.
function dragEvent(clientY = 0) {
  const row = {
    getBoundingClientRect: () => ({ top: 0, left: 0, height: 40 })
  }
  return {
    clientX: 0,
    clientY,
    currentTarget: row,
    preventDefault: vi.fn(),
    dataTransfer: {
      setData: vi.fn(),
      setDragImage: vi.fn(),
      effectAllowed: '',
      dropEffect: ''
    }
  } as unknown as DragEvent
}

function setup() {
  const list = ['calendar', 'contacts', 'files', 'photos']
  const place = vi.fn()
  return { place, drag: useDragReorder(() => list, place) }
}

describe('useDragReorder', () => {
  it('drops below a row past its middle, counting the slot the item left', () => {
    const { place, drag } = setup()
    drag.onDragStart('calendar', dragEvent())
    drag.onDragOver(2, dragEvent(30))
    expect(drag.marks.value).toEqual({ photos: 'before' })
    drag.onDrop(dragEvent())
    expect(place).toHaveBeenCalledWith('calendar', 2)
    expect(drag.draggingId.value).toBeNull()
  })

  it('drops above a row in its top half, and after the last row', () => {
    const { place, drag } = setup()
    drag.onDragStart('photos', dragEvent())
    drag.onDragOver(1, dragEvent(10))
    expect(drag.marks.value).toEqual({ contacts: 'before' })
    drag.onDrop(dragEvent())
    expect(place).toHaveBeenCalledWith('photos', 1)

    drag.onDragStart('calendar', dragEvent())
    drag.onDragOver(3, dragEvent(30))
    expect(drag.marks.value).toEqual({ photos: 'after' })
    drag.onDrop(dragEvent())
    expect(place).toHaveBeenLastCalledWith('calendar', 3)
  })

  it('marks nothing and places nothing around the dragged row itself', () => {
    const { place, drag } = setup()
    drag.onDragStart('files', dragEvent())
    drag.onDragOver(1, dragEvent(30))
    expect(drag.marks.value).toEqual({})
    drag.onDrop(dragEvent())
    expect(place).not.toHaveBeenCalled()
  })

  it('ignores drags that did not start in the list', () => {
    const { place, drag } = setup()
    const over = dragEvent(30)
    drag.onDragOver(0, over)
    expect(over.preventDefault).not.toHaveBeenCalled()
    drag.onDrop(dragEvent())
    expect(place).not.toHaveBeenCalled()
  })
})
