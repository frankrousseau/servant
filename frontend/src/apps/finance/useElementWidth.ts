import { onBeforeUnmount, onMounted, ref, type Ref } from 'vue'

// Tracks an element's content width, so an SVG chart can draw in real
// pixels (text keeps its size) instead of scaling a fixed viewBox. Keeps
// `fallback` until measured, and the last width while the element is hidden.
export function useElementWidth(
  target: Ref<HTMLElement | null>,
  fallback: number
): Ref<number> {
  const width = ref(fallback)
  let observer: ResizeObserver | null = null

  onMounted(() => {
    if (!target.value || typeof ResizeObserver === 'undefined') return
    observer = new ResizeObserver(([entry]) => {
      const measured = Math.round(entry.contentRect.width)
      if (measured > 0) width.value = measured
    })
    observer.observe(target.value)
  })

  onBeforeUnmount(() => observer?.disconnect())

  return width
}
