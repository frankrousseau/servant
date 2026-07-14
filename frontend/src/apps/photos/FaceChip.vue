<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'

// A face crop rendered from a photo thumbnail: the box is relative (0..1),
// so any same-aspect derivative of the original works as source.
const props = defineProps<{ src: string; box: number[] }>()

const SIZE = 56
const MARGIN = 0.25 // widen the crop so the face is not wall-to-wall

const canvas = ref<HTMLCanvasElement | null>(null)

function draw() {
  const el = canvas.value
  if (!el) return
  const img = new Image()
  img.onload = () => {
    const [x, y, w, h] = props.box
    const nw = img.naturalWidth
    const nh = img.naturalHeight
    // Square source region centered on the box, margin included.
    const side = Math.max(w * nw, h * nh) * (1 + MARGIN * 2)
    const cx = (x + w / 2) * nw
    const cy = (y + h / 2) * nh
    const sx = Math.max(0, Math.min(cx - side / 2, nw - side))
    const sy = Math.max(0, Math.min(cy - side / 2, nh - side))
    const s = Math.min(side, nw, nh)
    el.getContext('2d')?.drawImage(img, sx, sy, s, s, 0, 0, SIZE, SIZE)
  }
  img.src = props.src
}

onMounted(draw)
watch(() => [props.src, props.box], draw)
</script>

<template>
  <canvas ref="canvas" class="face-chip" :width="SIZE" :height="SIZE" />
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
