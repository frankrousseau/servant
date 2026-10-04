// This module gives a name to each call to /api/auth. The account endpoints
// are in two groups. The calls of the first group go through the shared
// client. The few calls of the second group must not.
//
// The shared client changes each 401 into a logout. That is wrong during the
// login: a bad password or a wrong TOTP code gives a 401. The shared client
// would then clear a session that the user did not open. Those calls use
// fetch directly, with the same error parsing. As a result, a changeset-style
// {errors: {field: [...]}} body shows its real message and not a generic one.
import type { User } from '../types'
import { apiErrorMessage, apiJson } from '../composables/apiClient'

export type Session = { token: string; user: User }
export type LoginReply = Session | { requires_totp: true; ticket: string }

async function postUnauthenticated<T>(
  path: string,
  body: unknown,
  fallbackMessage: string
): Promise<T> {
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  })

  if (!res.ok) {
    const err = await res.json().catch(() => ({}))
    throw new Error(apiErrorMessage(err) || fallbackMessage)
  }
  return res.json()
}

// ----- entering a session -----

/** Resolves to a pending-TOTP marker when the account has 2FA. */
export function login(username: string, password: string): Promise<LoginReply> {
  return postUnauthenticated<LoginReply>(
    '/api/auth/login',
    { username, password },
    'Login failed'
  )
}

export function verifyTotp(ticket: string, code: string): Promise<Session> {
  return postUnauthenticated<Session>(
    '/api/auth/totp/verify',
    { ticket, code },
    'Invalid code'
  )
}

export function register(
  username: string,
  password: string,
  display_name: string
): Promise<Session> {
  return postUnauthenticated<Session>(
    '/api/auth/register',
    { username, password, display_name },
    'Registration failed'
  )
}

/**
 * Clears the HttpOnly cookie on the server. The call does not wait for the
 * reply: the local state goes away if the request succeeds or not.
 */
export function logout(): void {
  fetch('/api/auth/logout', { method: 'POST' }).catch(() => {})
}

/**
 * Tells if this instance still accepts self-registration. The call is
 * unauthenticated.
 */
export async function fetchAuthConfig(): Promise<{
  registration_enabled: boolean
}> {
  const res = await fetch('/api/auth/config')
  if (!res.ok) throw new Error('Failed to read the auth config')
  return res.json()
}

/**
 * Returns the current user, authenticated by the cookie alone. Returns null on
 * a 401 (no session). Also returns the in-memory token that is necessary for
 * the socket, when there is one.
 */
export async function fetchMe(): Promise<{
  user: User
  token: string | null
} | null> {
  const res = await fetch('/api/auth/me')
  if (res.status === 401) return null
  if (!res.ok) throw new Error('Failed to read the session')
  const body = await res.json()
  return { user: body.data, token: body.token ?? null }
}

// ----- account -----

export async function updateProfile(
  attrs: Record<string, unknown>
): Promise<User> {
  const res = await apiJson<{ data: User }>('PUT', '/api/auth/profile', {
    body: attrs
  })
  return res.data
}

export async function changePassword(
  current_password: string,
  new_password: string
): Promise<void> {
  await apiJson('PUT', '/api/auth/password', {
    body: { current_password, new_password }
  })
}

/**
 * The request is multipart, so the browser sets the boundary itself. The
 * shared client forces a JSON content-type, so this call cannot use it. The
 * caller passes the token, and this module does not read it from the store.
 * As a result, this module does not depend on the store.
 */
export async function uploadAvatar(
  file: File,
  token: string | null
): Promise<{ avatar_path: string }> {
  const form = new FormData()
  form.append('avatar', file)
  const res = await fetch('/api/auth/avatar', {
    method: 'POST',
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    body: form
  })
  const body = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(apiErrorMessage(body) || 'Upload failed')
  return body.data
}

// ----- two-factor -----

export interface TotpSetup {
  secret: string
  otpauth_url: string
  /** A signed handle on the pending secret. The confirm call sends it back. */
  payload: string
}

export function setupTotp(): Promise<TotpSetup> {
  return apiJson<TotpSetup>('POST', '/api/auth/totp/setup')
}

export async function confirmTotp(
  payload: string,
  code: string
): Promise<void> {
  await apiJson('POST', '/api/auth/totp/confirm', { body: { payload, code } })
}

export async function disableTotp(code: string): Promise<void> {
  await apiJson('DELETE', '/api/auth/totp', { body: { code } })
}
