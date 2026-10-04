import type { Schedule } from '../types'

// The UI text for the sync cadence of a connector.
export const SCHEDULE_LABELS: Record<Schedule, string> = {
  on_demand: 'On demand',
  every_5_minutes: 'Every 5 minutes',
  every_hour: 'Every hour',
  every_day: 'Every day',
  every_week: 'Every week',
  continuous: 'Continuous'
}
