import { fetchAuthConfig } from '../api/auth'

// The public auth capabilities (no token is necessary). The default is
// "enabled" when the endpoint is unreachable. As a result, a short network
// failure never hides the register link on an open instance. The server still
// enforces the real rule on POST.
export async function fetchRegistrationEnabled(): Promise<boolean> {
  try {
    const config = await fetchAuthConfig()
    return config.registration_enabled !== false
  } catch {
    return true
  }
}
