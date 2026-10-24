<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'

// A face crop rendered from a photo thumbnail. The box is relative (0..1).
// As a result, each derivative of the original with the same aspect ratio
// can be the source.
const props = defineProps<{ src: string; box: number[] }>()

const SIZE = 56
const MARGIN = 0.25 // a wider crop keeps the face away from the edges

const canvas = ref<HTMLCanvasElement | null>(null)

function draw() {
  const el = canvas.value
  if (!el) return
  const img = new Image()
  img.onload = () => {
    const [boxX, boxY, boxWidth, boxHeight] = props.box
    const naturalWidth = img.naturalWidth
    const naturalHeight = img.naturalHeight
    // The source region is a square centered on the box, with the margin
    // included.
    const side =
      Math.max(boxWidth * naturalWidth, boxHeight * naturalHeight) *
      (1 + MARGIN * 2)
    const centerX = (boxX + boxWidth / 2) * naturalWidth
    const centerY = (boxY + boxHeight / 2) * naturalHeight
    const sourceX = Math.max(
      0,
      Math.min(centerX - side / 2, naturalWidth - side)
    )
    const sourceY = Math.max(
      0,
      Math.min(centerY - side / 2, naturalHeight - side)
    )
    const cropSide = Math.min(side, naturalWidth, naturalHeight)
    el.getContext('2d')?.drawImage(
      img,
      sourceX,
      sourceY,
      cropSide,
      cropSide,
      0,
      0,
      SIZE,
      SIZE
    )
  }
  // Without this handler, a missing or deleted thumbnail gives a blank
  // canvas. Draw a placeholder glyph. Then the chip means "image
  // unavailable", not "empty".
  img.onerror = () => {
    const ctx = el.getContext('2d')
    if (!ctx) return
    ctx.fillStyle = 'rgba(128,128,128,0.15)'
    ctx.fillRect(0, 0, SIZE, SIZE)
    ctx.fillStyle = 'rgba(128,128,128,0.7)'
    ctx.font = '24px sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillText('?', SIZE / 2, SIZE / 2)
  }
  img.src = props.src
}

onMounted(draw)
watch(() => [props.src, props.box], draw)
</script>

<template>
  <!-- An unnamed face crop has no useful description to announce. The
       adjacent name input is the interactive part of the row. -->
  <canvas
    ref="canvas"
    class="face-chip"
    :width="SIZE"
    :height="SIZE"
    aria-hidden="true"
  />
</template>

<style scoped>
.face-chip {
  width: 56px;
  height: 56px;
  border-radius: 8px;
  background: var(--bg-hover);
  flex-shrink: 0;
}
</style>
