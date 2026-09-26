import { computed } from 'vue'

import type { AppContext } from './types'

// A preference as a writable ref: reads follow the account, writes save it.
export function preferenceRef<T>(ctx: AppContext, key: string, fallback: T) {
  return computed<T>({
    get: () => ctx.preferences.get(key, fallback),
    set: value => ctx.preferences.set(key, value)
  })
}
