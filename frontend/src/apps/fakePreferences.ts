import { reactive } from 'vue'

import type { AppContext } from './types'

// Test stand-in for ctx.preferences: an in-memory, reactive store.
export function fakePreferences(
  initial: Record<string, unknown> = {}
): AppContext['preferences'] & { values: Record<string, unknown> } {
  const values = reactive({ ...initial })
  return {
    values,
    get: <T>(key: string, fallback: T) => (values[key] as T) ?? fallback,
    set: (key: string, value: unknown) => {
      values[key] = value
    }
  }
}
