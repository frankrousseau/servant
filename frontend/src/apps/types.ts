// Single source of truth in ../types to keep the apps and views from drifting.
export type { Entry } from '../types'
import type { Entry } from '../types'

export interface AggregateBucket {
  /** Local day "YYYY-MM-DD", week's Monday "YYYY-MM-DD", "YYYY-MM" or "YYYY". */
  bucket: string
  value: number
}

export interface EntriesAPI {
  list(filters?: Record<string, string>): Promise<Entry[]>
  get(id: string): Promise<Entry>
  create(attrs: Record<string, unknown>): Promise<Entry>
  update(id: string, attrs: Record<string, unknown>): Promise<Entry>
  delete(id: string): Promise<void>
  stats(): Promise<Record<string, number>>
  /**
   * Server-side COUNT/SUM of entries bucketed by local day/week/month/year
   * in the user's timezone. Same filters as list (kind, source, from, to, q)
   * plus agg, field (for sum), bucket and tz.
   */
  aggregate(params: Record<string, string>): Promise<AggregateBucket[]>
}

export interface UploadResult {
  path: string
  filename: string
  size: number
  mime_type: string
}

export interface ViewerItem {
  id: string
  src: string
  /** Original full-resolution source when `src` is a downscaled display copy. */
  fullSrc?: string
  video?: boolean
  title?: string
  subtitle?: string
  meta?: Record<string, string | number | null>
}

export interface ViewerAPI {
  open(items: ViewerItem[], startIndex?: number): void
  close(): void
  onDelete(cb: (id: string) => void): void
  // Fired on user-initiated closes (backdrop, Esc, Close button), not on
  // programmatic close(); lets the app sync its URL or state.
  onClose(cb: () => void): void
}

export interface ConfirmAPI {
  ask(opts: {
    title?: string
    message: string
    confirmLabel?: string
    danger?: boolean
  }): Promise<boolean>
}

export interface AppContext {
  navigate(path: string): void
  // What the user kept enabled in Settings > Apps; null means the default
  // set. A getter on the context object, so it stays live.
  readonly enabledApps: string[] | null
  confirm: ConfirmAPI
  api: {
    entries: EntriesAPI
    upload(
      file: File,
      app?: string,
      onProgress?: (pct: number) => void
    ): Promise<UploadResult>
    fetch(path: string, opts?: RequestInit): Promise<Response>
  }
  viewer: ViewerAPI
}

export interface AppModule {
  mount(el: HTMLElement, ctx: AppContext): void | Promise<void>
  unmount?(el: HTMLElement): void
}

export interface AppDef {
  id: string
  name: string
  icon: string
  builtin: boolean
  load: () => Promise<{ default: AppModule }>
}
