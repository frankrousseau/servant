import { describe, expect, it } from 'vitest'

import {
  movePinnedApp,
  pinApp,
  pinnedApps,
  placePinnedApp,
  readSidebarPreference,
  unpinApp,
  unpinnedApps
} from './sidebarApps'

const apps = ['calendar', 'contacts', 'files', 'photos'].map(id => ({ id }))
const ids = (list: { id: string }[]) => list.map(app => app.id)
const empty = readSidebarPreference(undefined)

describe('readSidebarPreference', () => {
  it('reads anything malformed as never customized', () => {
    expect(readSidebarPreference(null)).toEqual({ order: [], hidden: [] })
    expect(readSidebarPreference('nope')).toEqual({ order: [], hidden: [] })
    expect(readSidebarPreference({ order: ['files', 3], hidden: 'x' })).toEqual(
      { order: ['files'], hidden: [] }
    )
  })
})

describe('pinnedApps', () => {
  it('pins every app in registry order by default', () => {
    expect(ids(pinnedApps(apps, empty))).toEqual(ids(apps))
    expect(unpinnedApps(apps, empty)).toEqual([])
  })

  it('follows the stored order, new apps last, hidden ones out', () => {
    const pref = { order: ['photos', 'calendar'], hidden: ['contacts'] }
    expect(ids(pinnedApps(apps, pref))).toEqual(['photos', 'calendar', 'files'])
    expect(ids(unpinnedApps(apps, pref))).toEqual(['contacts'])
  })

  it('ignores ids of apps that are gone', () => {
    const pref = { order: ['gone', 'files'], hidden: ['removed'] }
    expect(ids(pinnedApps(apps, pref))).toEqual([
      'files',
      'calendar',
      'contacts',
      'photos'
    ])
  })
})

describe('pinApp and unpinApp', () => {
  it('unpins an app and keeps the others in their displayed order', () => {
    const pref = unpinApp(apps, empty, 'contacts')
    expect(pref).toEqual({
      order: ['calendar', 'files', 'photos'],
      hidden: ['contacts']
    })
  })

  it('pins an app back at the end of the sidebar', () => {
    const unpinned = unpinApp(apps, empty, 'calendar')
    const pref = pinApp(apps, unpinned, 'calendar')
    expect(ids(pinnedApps(apps, pref))).toEqual([
      'contacts',
      'files',
      'photos',
      'calendar'
    ])
    expect(pref.hidden).toEqual([])
  })
})

describe('movePinnedApp', () => {
  it('swaps an app with its neighbour', () => {
    const up = movePinnedApp(apps, empty, 'files', -1)
    expect(up.order).toEqual(['calendar', 'files', 'contacts', 'photos'])
    const down = movePinnedApp(apps, up, 'calendar', 1)
    expect(down.order).toEqual(['files', 'calendar', 'contacts', 'photos'])
  })

  it('leaves the preference alone past either end or for an unpinned app', () => {
    expect(movePinnedApp(apps, empty, 'calendar', -1)).toBe(empty)
    expect(movePinnedApp(apps, empty, 'photos', 1)).toBe(empty)
    const pref = unpinApp(apps, empty, 'files')
    expect(movePinnedApp(apps, pref, 'files', -1)).toBe(pref)
  })
})

describe('placePinnedApp', () => {
  it('puts an app at the dropped index, both ways', () => {
    const down = placePinnedApp(apps, empty, 'calendar', 2)
    expect(down.order).toEqual(['contacts', 'files', 'calendar', 'photos'])
    const up = placePinnedApp(apps, empty, 'photos', 0)
    expect(up.order).toEqual(['photos', 'calendar', 'contacts', 'files'])
  })

  it('leaves the preference alone for a no-op or an index out of range', () => {
    expect(placePinnedApp(apps, empty, 'files', 2)).toBe(empty)
    expect(placePinnedApp(apps, empty, 'files', 4)).toBe(empty)
    expect(placePinnedApp(apps, empty, 'files', -1)).toBe(empty)
  })
})
