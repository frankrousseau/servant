// Public auth capabilities (no token needed). Defaults to "enabled" when the
// endpoint is unreachable so a network hiccup never hides the register link
// on an open instance — the server still enforces the real rule on POST.
export async function fetchRegistrationEnabled(): Promise<boolean> {
  try {
    const res = await fetch('/api/auth/config')
    if (!res.ok) return true
    const body = (await res.json()) as { registration_enabled?: boolean }
    return body.registration_enabled !== false
  } catch {
    return true
  }
}
