import { useAuthStore } from '../stores/auth'

// Single HTTP client for the whole app (Vue views via useApi and the imperative
// apps via createContext). Handles the Bearer header, 401 -> logout, and error
// parsing in one place.

export interface ApiOptions extends RequestInit {
  params?: Record<string, string>
}

// Turns an API error payload into a readable message: either `{error: "..."}`
// or a changeset-style `{errors: {field: ["msg", ...]}}`.
export function apiErrorMessage(err: unknown): string | null {
  if (typeof err !== 'object' || err === null) return null
  const e = err as { error?: unknown; errors?: unknown }
  if (typeof e.error === 'string') return e.error
  if (typeof e.errors === 'object' && e.errors !== null) {
    const parts = Object.entries(e.errors as Record<string, unknown>).map(
      ([field, msgs]) =>
        `${field}: ${Array.isArray(msgs) ? msgs.join(', ') : String(msgs)}`
    )
    if (parts.length) return parts.join('; ')
  }
  return null
}

export async function apiFetch(
  path: string,
  opts: ApiOptions = {}
): Promise<Response> {
  const auth = useAuthStore()
  const { params, headers, ...rest } = opts

  const url = new URL(path, window.location.origin)
  if (params) {
    for (const [key, value] of Object.entries(params))
      url.searchParams.set(key, value)
  }

  const finalHeaders: Record<string, string> = {
    'Content-Type': 'application/json',
    ...((headers as Record<string, string>) || {})
  }
  if (auth.token) finalHeaders['Authorization'] = `Bearer ${auth.token}`

  const res = await fetch(url.toString(), { ...rest, headers: finalHeaders })

  if (res.status === 401) {
    auth.logout()
    throw new Error('Unauthorized')
  }
  if (!res.ok) {
    const err = await res.json().catch(() => ({}))
    throw new Error(apiErrorMessage(err) || `Request failed: ${res.status}`)
  }
  return res
}

export async function apiJson<T>(
  method: string,
  path: string,
  opts: { body?: unknown; params?: Record<string, string> } = {}
): Promise<T> {
  const res = await apiFetch(path, {
    method,
    params: opts.params,
    body: opts.body != null ? JSON.stringify(opts.body) : undefined
  })
  if (res.status === 204) return undefined as T
  return res.json()
}
