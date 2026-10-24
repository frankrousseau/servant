// Which apps the sidebar lists, and in what order. The choice is a user
// preference ("shell.sidebar"), so it follows the account across devices.
//
// The preference records what the user unpinned rather than what they
// pinned: an app enabled or installed later shows up in the sidebar (at the
// end) without a second step, and only an explicit unpin takes it out.
// Ids that no longer match an app (an uninstalled one) are ignored on read.

export const SIDEBAR_PREFERENCE = 'shell.sidebar'

export interface SidebarPreference {
  // Pinned app ids in display order; pinned apps missing from it follow,
  // in registry order.
  order: string[]
  hidden: string[]
}

interface HasId {
  id: string
}

// Anything that is not a well-formed preference reads as "never customized".
export function readSidebarPreference(raw: unknown): SidebarPreference {
  const value = (raw ?? {}) as Partial<SidebarPreference>
  const ids = (list: unknown) =>
    Array.isArray(list)
      ? list.filter((id): id is string => typeof id === 'string')
      : []
  return { order: ids(value.order), hidden: ids(value.hidden) }
}

export function pinnedApps<T extends HasId>(
  apps: T[],
  pref: SidebarPreference
): T[] {
  const rank = (id: string) => {
    const index = pref.order.indexOf(id)
    return index === -1 ? pref.order.length : index
  }
  // Array.prototype.sort is stable: unranked apps keep the registry order.
  return apps
    .filter(app => !pref.hidden.includes(app.id))
    .sort((a, b) => rank(a.id) - rank(b.id))
}

export function unpinnedApps<T extends HasId>(
  apps: T[],
  pref: SidebarPreference
): T[] {
  return apps.filter(app => pref.hidden.includes(app.id))
}

// Every write stores the full pinned order as displayed, so the sidebar
// never reshuffles behind the user's back once they touched it.

export function pinApp<T extends HasId>(
  apps: T[],
  pref: SidebarPreference,
  id: string
): SidebarPreference {
  const order = pinnedApps(apps, pref)
    .map(app => app.id)
    .filter(appId => appId !== id)
  return {
    order: [...order, id],
    hidden: pref.hidden.filter(appId => appId !== id)
  }
}

export function unpinApp<T extends HasId>(
  apps: T[],
  pref: SidebarPreference,
  id: string
): SidebarPreference {
  const order = pinnedApps(apps, pref)
    .map(app => app.id)
    .filter(appId => appId !== id)
  const hidden = pref.hidden.includes(id) ? pref.hidden : [...pref.hidden, id]
  return { order, hidden }
}

// Puts a pinned app at `toIndex` of the displayed order (a drag and drop);
// an unpinned app or an index out of range leaves the preference as is.
export function placePinnedApp<T extends HasId>(
  apps: T[],
  pref: SidebarPreference,
  id: string,
  toIndex: number
): SidebarPreference {
  const order = pinnedApps(apps, pref).map(app => app.id)
  const from = order.indexOf(id)
  if (from === -1 || toIndex < 0 || toIndex >= order.length) return pref
  if (toIndex === from) return pref
  order.splice(toIndex, 0, ...order.splice(from, 1))
  return { order, hidden: pref.hidden }
}

// delta -1 moves the app one slot up, +1 one slot down (the arrow buttons);
// past either end it stays where it is.
export function movePinnedApp<T extends HasId>(
  apps: T[],
  pref: SidebarPreference,
  id: string,
  delta: number
): SidebarPreference {
  const from = pinnedApps(apps, pref).findIndex(app => app.id === id)
  if (from === -1) return pref
  return placePinnedApp(apps, pref, id, from + delta)
}
