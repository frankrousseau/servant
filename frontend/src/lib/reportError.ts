import { apiJson } from '../composables/apiClient'

// Mirror a browser-side error into the server Audit log so a self-hosted
// operator can diagnose it (the console is never seen otherwise). Fire-and-forget,
// and de-dupes consecutive identical messages so an error loop can't flood the
// server-side ring buffer.
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
