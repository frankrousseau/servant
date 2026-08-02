import { fetchAuthConfig } from '../api/auth'

// Public auth capabilities (no token needed). Defaults to "enabled" when the
// endpoint is unreachable so a network hiccup never hides the register link
// on an open instance; the server still enforces the real rule on POST.
export async function fetchRegistrationEnabled(): Promise<boolean> {
  try {
    const config = await fetchAuthConfig()
    return config.registration_enabled !== false
  } catch {
    return true
  }
}
