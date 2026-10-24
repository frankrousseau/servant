// Single source of truth in ../types, so that the apps and the views do not
// drift.
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
   * Server-side COUNT or SUM of the entries, in buckets by local day, week,
   * month or year in the user's timezone. Takes the same filters as list
   * (kind, source, from, to, q), plus agg, field (for sum), bucket and tz.
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
  note?: string
}

export interface ViewerAPI {
  open(items: ViewerItem[], startIndex?: number): void
  close(): void
  onDelete(cb: (id: string) => void): void
  // Fires when the user edits the note of an item in the info panel. The
  // viewer already shows the new text, and the app persists it.
  onNote(cb: (id: string, note: string) => void): void
  // Fires when the user closes the viewer (backdrop, Esc, Close button), not
  // on a programmatic close(). Lets the app sync its URL or state.
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
  // What the user kept enabled in Settings > Apps. null means the default
  // set. This is a getter on the context object. As a result, it stays live.
  readonly enabledApps: string[] | null
  confirm: ConfirmAPI
  // UI preferences stored on the account. As a result, they follow the user
  // from one device to the next. The keys have the namespace "<app>.<name>".
  // get() is reactive and set() saves that one key (null removes it).
  preferences: {
    get<T>(key: string, fallback: T): T
    set(key: string, value: unknown): void
  }
  // Live entry changes from the user's data channel (created, updated, or
  // deleted; a deleted entry carries only `id`). Returns an unsubscribe
  // function. Call it in the teardown of the app.
  events: {
    onEntryChange(cb: (entry: Entry) => void): () => void
  }
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
