import type { AppDef } from './types'

// Alphabetical by name; this array is the sidebar display order.
export const BUILTIN_APPS: AppDef[] = [
  {
    id: 'calendar',
    name: 'Calendar',
    icon: 'CalendarDays',
    builtin: true,
    load: () => import('./calendar')
  },
  {
    id: 'checklists',
    name: 'Checklists',
    icon: 'ListChecks',
    builtin: true,
    load: () => import('./checklists')
  },
  {
    id: 'contacts',
    name: 'Contacts',
    icon: 'UserRound',
    builtin: true,
    load: () => import('./contacts')
  },
  {
    id: 'files',
    name: 'Files',
    icon: 'FolderOpen',
    builtin: true,
    load: () => import('./files')
  },
  {
    id: 'finance',
    name: 'Finance',
    icon: 'Wallet',
    builtin: true,
    load: () => import('./finance')
  },
  {
    id: 'notes',
    name: 'Notes',
    icon: 'NotebookPen',
    builtin: true,
    load: () => import('./notes')
  },
  {
    id: 'photos',
    name: 'Photos',
    icon: 'Image',
    builtin: true,
    load: () => import('./photos')
  },
  {
    id: 'trackers',
    name: 'Trackers',
    icon: 'Target',
    builtin: true,
    load: () => import('./trackers')
  }
]

// Built-in apps enabled for accounts that never touched the Settings
// toggles (user.enabled_apps is null).
export const DEFAULT_ENABLED_APPS = ['calendar', 'contacts', 'files', 'photos']

// The built-in apps the user kept enabled; null/undefined means the default
// set. Unknown ids (from a newer frontend or an uninstalled custom app id
// that leaked in) are ignored.
export function enabledBuiltins(ids: string[] | null | undefined): AppDef[] {
  const enabled = ids ?? DEFAULT_ENABLED_APPS
  return BUILTIN_APPS.filter(a => enabled.includes(a.id))
}

// Agents is not a mounted app (it keeps its own /agents route) but it is
// toggled like one: hidden from the sidebar and palette unless enabled.
// Not in DEFAULT_ENABLED_APPS, so it is off until the user opts in.
export function agentsEnabled(ids: string[] | null | undefined): boolean {
  return (ids ?? DEFAULT_ENABLED_APPS).includes('agents')
}

// Crypto is a slice across the app rather than an app: the blockchain
// connectors and the crypto side of Finance. Toggled the same way, and off
// until the user opts in. Configured connectors keep syncing when it is off,
// they are only hidden; the Settings copy says so.
export function cryptoEnabled(ids: string[] | null | undefined): boolean {
  return (ids ?? DEFAULT_ENABLED_APPS).includes('crypto')
}
