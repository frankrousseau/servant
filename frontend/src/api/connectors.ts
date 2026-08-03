// Every call to /api/connectors, named. A connector has a longer life than
// most resources here (configure, sync, start, stop, import a file, hand off to
// a bank's OAuth), and the four views driving it were each spelling out the
// paths.
import type { ConnectorConfig, Schedule, SyncLog } from '../types'
import { apiErrorMessage, apiJson } from '../composables/apiClient'

export async function listConnectors(): Promise<ConnectorConfig[]> {
  const res = await apiJson<{ data: ConnectorConfig[] }>(
    'GET',
    '/api/connectors'
  )
  return res.data
}

export async function getConnector(id: string): Promise<ConnectorConfig> {
  const res = await apiJson<{ data: ConnectorConfig }>(
    'GET',
    `/api/connectors/${id}`
  )
  return res.data
}

export interface NewConnector {
  connector_type: string
  name: string | null
  config: Record<string, unknown>
  schedule: Schedule
  enabled: boolean
}

export async function createConnector(
  attrs: NewConnector
): Promise<ConnectorConfig> {
  const res = await apiJson<{ data: ConnectorConfig }>(
    'POST',
    '/api/connectors',
    { body: attrs }
  )
  return res.data
}

/** Renaming, rescheduling and enabling all go through the same update. */
export async function updateConnector(
  id: string,
  attrs: Record<string, unknown>
): Promise<ConnectorConfig> {
  const res = await apiJson<{ data: ConnectorConfig }>(
    'PUT',
    `/api/connectors/${id}`,
    { body: attrs }
  )
  return res.data
}

export async function deleteConnector(id: string): Promise<void> {
  await apiJson<void>('DELETE', `/api/connectors/${id}`)
}

/** Which cadences this connector type accepts, and the one it suggests. */
export function connectorSchedules(
  type: string
): Promise<{ schedules: Schedule[]; default: Schedule }> {
  return apiJson<{ schedules: Schedule[]; default: Schedule }>(
    'GET',
    `/api/connectors/schedules/${encodeURIComponent(type)}`
  )
}

// ----- running -----

export async function syncConnector(id: string): Promise<void> {
  await apiJson('POST', `/api/connectors/${id}/sync`)
}

export async function startConnector(id: string): Promise<void> {
  await apiJson('POST', `/api/connectors/${id}/start`)
}

export async function stopConnector(id: string): Promise<void> {
  await apiJson('POST', `/api/connectors/${id}/stop`)
}

export async function connectorLogs(id: string): Promise<SyncLog[]> {
  const res = await apiJson<{ data: SyncLog[] }>(
    'GET',
    `/api/connectors/${id}/logs`
  )
  return res.data
}

/**
 * Feeds a file to a connector that imports rather than fetches (bank CSV,
 * vCard). Multipart, so the browser sets the boundary itself and the shared
 * client cannot be used; the token is passed in to keep this module free of
 * the store.
 */
export async function importConnectorFile(
  id: string,
  file: File,
  token: string | null
): Promise<{ imported: number; skipped: number }> {
  const form = new FormData()
  form.append('file', file)
  const res = await fetch(`/api/connectors/${id}/import`, {
    method: 'POST',
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    body: form
  })
  const body = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(apiErrorMessage(body) || 'Import failed')
  return { imported: body.imported, skipped: body.skipped }
}

// ----- Enable Banking (PSD2 consent handshake) -----

/** Step one: where to send the user to consent at their bank. */
export async function enableBankingAuthUrl(
  id: string,
  redirect_url: string
): Promise<string> {
  const res = await apiJson<{ url: string }>(
    'POST',
    `/api/connectors/${id}/enable_banking/auth_url`,
    { body: { redirect_url } }
  )
  return res.url
}

/** Step two: trade the code the bank sent back for stored credentials. */
export async function enableBankingExchange(
  id: string,
  code: string
): Promise<void> {
  await apiJson('POST', `/api/connectors/${id}/enable_banking/exchange`, {
    body: { code }
  })
}
