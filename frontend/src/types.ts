// Shapes the API returns, mirrored from what the Phoenix controllers render.
// Types only: the helpers that used to sit here live in lib/ (datetime, kind,
// filesize, connectors), so importing a shape never pulls in runtime code.

// ----- account -----

export interface User {
  id: string
  username: string
  display_name: string
  email: string | null
  avatar_path: string | null
  timezone?: string | null
  theme?: string | null
  // null on either means "render like the browser does"
  time_format?: string | null
  date_format?: string | null
  enabled_apps?: string[] | null
  totp_enabled?: boolean
  admin?: boolean
  // Only /api/auth/me returns it (the Profile page's "member since").
  inserted_at?: string
}

export interface ApiToken {
  id: string
  name: string
  prefix: string
  scopes: string[]
  expires_at: string | null
  last_used_at: string | null
  inserted_at: string
  token?: string // present only in the create response
}

// ----- apps -----

export interface InstalledApp {
  id: string
  name: string
  description: string | null
  icon: string | null
  entry_url: string
  repo_url: string | null
  built_in: boolean
  generated: boolean
  has_previous: boolean
  updated_at: string
}

// ----- data -----

export interface Entry {
  id: string
  kind: string
  source: string
  external_id: string | null
  title: string | null
  occurred_at: string | null
  data: Record<string, unknown>
  metadata: Record<string, unknown>
  inserted_at: string
  updated_at: string
}

export interface PaginationMeta {
  page: number
  per_page: number
  total: number
  total_pages: number
}

// ----- connectors -----

export type Schedule =
  | 'on_demand'
  | 'every_5_minutes'
  | 'every_hour'
  | 'every_day'
  | 'every_week'
  | 'continuous'

export interface ConnectorConfig {
  id: string
  connector_type: string
  name: string | null
  enabled: boolean
  config: Record<string, unknown>
  schedule: Schedule
  last_synced_at: string | null
  error: string | null
  inserted_at: string
  updated_at: string
}

export interface SyncLog {
  id: string
  status: 'running' | 'completed' | 'failed'
  entries_count: number
  error: string | null
  started_at: string
  finished_at: string | null
}

// ----- agents -----

export interface AiConfig {
  enabled: boolean
  base_url: string
  model: string
  api_key: string | null
}

export interface Agent {
  id: string
  name: string
  prompt: string | null
  mode: 'prompt' | 'recipe'
  recipe: Record<string, unknown> | null
  // null = the model configured in Settings > Agents
  model: string | null
  kinds: string[]
  lookback_days: number
  schedule: 'every_hour' | 'every_day' | 'every_week'
  // null = interval counted from the last run, not a fixed hour
  run_at_hour: number | null
  enabled: boolean
  last_run_at: string | null
  inserted_at: string
}

export interface AgentRun {
  id: string
  type: string
  action: string
  agent_id: string | null
  app_id: string | null
  status: 'running' | 'ok' | 'error'
  model: string | null
  prompt: string | null
  input_tokens: number | null
  output_tokens: number | null
  duration_ms: number | null
  error: string | null
  inserted_at: string
}

/** A public link over the photos carrying one or more tags (Photos > Share). */
export interface PhotoShare {
  id: string
  name: string | null
  tags: string[]
  match: 'any' | 'all'
  token: string
  /** Path of the public page on this instance. */
  path: string
  inserted_at: string
}

/** One photo of a public feed, as the share link exposes it. */
export interface SharedPhoto {
  id: string
  title: string | null
  occurred_at: string | null
  mime_type: string | null
  video: boolean
  thumb: string | null
  src: string | null
  full: string | null
}

export interface SharedFeed {
  name: string | null
  tags: string[]
  match: 'any' | 'all'
  photos: SharedPhoto[]
}
