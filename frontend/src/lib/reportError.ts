import { apiJson } from '../composables/apiClient'

// Mirrors a browser-side error into the Audit log of the server. Then a
// self-hosted operator can diagnose it (without this, no one sees the
// console). The call does not wait for the reply. It drops consecutive
// identical messages, so an error loop cannot flood the ring buffer of the
// server.
let lastMessage = ''

export function reportClientError(context: string, message: string) {
  if (!message || message === lastMessage) return
  lastMessage = message
  void apiJson('POST', '/api/client_errors', {
    body: { context, message }
  }).catch(() => {})
}

export function messageOf(reason: unknown): string {
  if (reason instanceof Error) return reason.message
  if (typeof reason === 'string') return reason
  try {
    return JSON.stringify(reason)
  } catch {
    return String(reason)
  }
}
