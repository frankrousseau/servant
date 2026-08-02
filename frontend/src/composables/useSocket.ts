import { watch, onUnmounted } from 'vue'
import { Socket, Channel } from 'phoenix'

import { useAuthStore } from '../stores/auth'
import { reportClientError } from '../lib/reportError'
import type { Entry } from '../types'

export function useSocket() {
  const auth = useAuthStore()
  let socket: Socket | null = null
  let channel: Channel | null = null

  const entryChangeCallbacks: Array<(entry: Entry) => void> = []
  const bulkChangeCallbacks: Array<() => void> = []

  function onEntryChange(cb: (entry: Entry) => void) {
    entryChangeCallbacks.push(cb)
  }

  // Fires on the aggregated "entries_changed" signal (connector syncs / bulk
  // imports), which the server emits once for many rows instead of one
  // entry_change per row. Consumers should refetch here rather than relying on
  // per-entry events (which never arrive for bulk writes).
  function onBulkChange(cb: () => void) {
    bulkChangeCallbacks.push(cb)
  }

  function connect() {
    if (!auth.token || !auth.user) return

    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const socketUrl = `${protocol}//${window.location.host}/socket`

    socket = new Socket(socketUrl, {
      params: { token: auth.token }
    })

    // A silently dead realtime channel (expired token mid-session, server error)
    // leaves the UI showing stale data with no signal; surface it instead.
    // phoenix's bundled types omit Socket.onError, but it exists at runtime.
    ;(socket as unknown as { onError(cb: () => void): void }).onError(() =>
      reportClientError('socket', 'websocket connection error')
    )

    socket.connect()

    channel = socket.channel(`data:${auth.user.id}`, {})
    channel
      .join()
      .receive('error', reason =>
        reportClientError(
          'socket-join',
          `channel join failed: ${JSON.stringify(reason)}`
        )
      )
      .receive('timeout', () =>
        reportClientError('socket-join', 'channel join timed out')
      )

    channel.on('entry_change', (payload: { entry: Entry }) => {
      for (const cb of entryChangeCallbacks) {
        cb(payload.entry)
      }
    })

    channel.on('entries_changed', () => {
      for (const cb of bulkChangeCallbacks) {
        cb()
      }
    })
  }

  function disconnect() {
    if (channel) {
      channel.leave()
      channel = null
    }
    if (socket) {
      socket.disconnect()
      socket = null
    }
  }

  // Connect only once both the token AND the user are available. On a reload
  // the user is populated asynchronously (auth.hydrate), so we must react to it
  // and not just to the token.
  watch(
    () => auth.isAuthenticated && !!auth.user,
    ready => {
      if (ready) {
        connect()
      } else {
        disconnect()
      }
    },
    { immediate: true }
  )

  onUnmounted(() => {
    disconnect()
  })

  return { onEntryChange, onBulkChange }
}

/**
 * Wraps a zero-arg callback so bursts of calls collapse into a single trailing
 * invocation after `delay` ms of quiet. Use to coalesce refetches driven by
 * many socket events (a connector sync fires one event per entry).
 */
export function debounce(fn: () => void, delay = 400): () => void {
  let timer: ReturnType<typeof setTimeout> | null = null
  return () => {
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => {
      timer = null
      fn()
    }, delay)
  }
}
