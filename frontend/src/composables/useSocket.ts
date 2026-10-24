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

  // The two subscriptions return an unsubscribe function, for the callers
  // that live longer than a single consumer. The app host keeps one socket
  // while apps come and go.
  function onEntryChange(cb: (entry: Entry) => void) {
    entryChangeCallbacks.push(cb)
    return () => remove(entryChangeCallbacks, cb)
  }

  // Fires on the aggregated "entries_changed" signal (connector syncs, bulk
  // imports). The server emits it one time for many rows, and not one
  // entry_change for each row. Consumers must refetch here. They must not
  // rely on the events for each entry, which never arrive for bulk writes.
  function onBulkChange(cb: () => void) {
    bulkChangeCallbacks.push(cb)
    return () => remove(bulkChangeCallbacks, cb)
  }

  function remove<T>(list: T[], item: T) {
    const index = list.indexOf(item)
    if (index >= 0) list.splice(index, 1)
  }

  function connect() {
    if (!auth.token || !auth.user) return

    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const socketUrl = `${protocol}//${window.location.host}/socket`

    socket = new Socket(socketUrl, {
      params: { token: auth.token }
    })

    // A realtime channel can die with no signal (expired token in the middle
    // of a session, server error). The UI then shows stale data. Report the
    // failure. The bundled types of phoenix omit Socket.onError, but it
    // exists at runtime.
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

  // Connect only when the token AND the user are both available. On a reload,
  // auth.hydrate populates the user asynchronously. As a result, the watch
  // must react to the user and not only to the token.
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
 * Wraps a zero-arg callback so that a burst of calls becomes a single
 * trailing call after `delay` ms of quiet. Use it to merge the refetches
 * that many socket events trigger (a connector sync fires one event for each
 * entry).
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
