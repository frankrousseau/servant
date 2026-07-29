export interface User {
  id: string
  username: string
  display_name: string
  email: string | null
  avatar_path: string | null
  timezone?: string | null
  theme?: string | null
  enabled_apps?: string[] | null
  totp_enabled?: boolean
  admin?: boolean
}

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

export type Schedule =
  | 'on_demand'
  | 'every_5_minutes'
  | 'every_hour'
  | 'every_day'
  | 'every_week'
  | 'continuous'

export const SCHEDULE_LABELS: Record<Schedule, string> = {
  on_demand: 'On demand',
  every_5_minutes: 'Every 5 minutes',
  every_hour: 'Every hour',
  every_day: 'Every day',
  every_week: 'Every week',
  continuous: 'Continuous'
}

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

export interface SyncLog {
  id: string
  status: 'running' | 'completed' | 'failed'
  entries_count: number
  error: string | null
  started_at: string
  finished_at: string | null
}

// Kind icons/colors for visual differentiation
export const KIND_CONFIG: Record<string, { icon: string; color: string }> = {
  transaction: { icon: '↔', color: '#9d7bff' },
  article: { icon: '¶', color: '#f0a06c' },
  email: { icon: '@', color: '#5cc98a' },
  photo: { icon: '◻', color: '#c96cd0' },
  contact: { icon: '●', color: '#6ccec9' },
  note: { icon: '✎', color: '#e0d56c' },
  checklist: { icon: '☑', color: '#6c9bd0' }
}

export function kindIcon(kind: string): string {
  return KIND_CONFIG[kind]?.icon ?? '·'
}

export function kindColor(kind: string): string {
  return KIND_CONFIG[kind]?.color ?? '#8b8fa3'
}

export function relativeTime(dateStr: string): string {
  const date = new Date(dateStr)
  const now = new Date()
  const diffMs = now.getTime() - date.getTime()
  const diffSec = Math.floor(diffMs / 1000)
  const diffMin = Math.floor(diffSec / 60)
  const diffHour = Math.floor(diffMin / 60)
  const diffDay = Math.floor(diffHour / 24)

  if (diffSec < 60) return 'just now'
  if (diffMin < 60) return `${diffMin}m ago`
  if (diffHour < 24) return `${diffHour}h ago`
  if (diffDay < 7) return `${diffDay}d ago`
  return date.toLocaleDateString()
}

// Single byte formatter (bytes/KB/MB/GB) shared by photos, files, photo detail
// and the audit page, which previously each carried a copy that disagreed on
// KB precision. Caps at GB: disk sizes read better as 1843.2 GB than 1.8 TB.
export function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`
  return `${(bytes / 1024 ** 3).toFixed(1)} GB`
}
