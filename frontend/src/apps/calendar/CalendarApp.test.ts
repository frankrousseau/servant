import { describe, it, expect, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'

import CalendarApp from './CalendarApp.vue'

import type { Entry } from '../types'

// A two-hour meeting on 2026-08-12 12:00 UTC, in the month the app opens on.
const MEETING: Entry = {
  id: 'e1',
  kind: 'event',
  source: 'manual',
  external_id: null,
  title: 'Meeting',
  occurred_at: '2026-08-12T12:00:00Z',
  data: {
    summary: 'Meeting',
    dtstart: '20260812T120000',
    dtend: '20260812T140000',
    end_at: '2026-08-12T14:00:00Z',
    all_day: false,
    calendar: 'Manual'
  },
  metadata: {},
  inserted_at: '2026-08-01T00:00:00Z',
  updated_at: '2026-08-01T00:00:00Z'
}

function makeCtx() {
  return {
    navigate: vi.fn(),
    confirm: { ask: vi.fn().mockResolvedValue(true) },
    api: {
      entries: {
        list: vi.fn(async (filters?: Record<string, string>) =>
          filters?.kind === 'event' ? [MEETING] : []
        ),
        get: vi.fn(),
        update: vi.fn(async () => MEETING),
        create: vi.fn(),
        delete: vi.fn()
      },
      upload: vi.fn(),
      fetch: vi.fn()
    },
    viewer: { open: vi.fn(), close: vi.fn(), onDelete: vi.fn() }
  }
}

describe('CalendarApp drag and drop', () => {
  it('moves a dropped event to the target day, times and duration kept', async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-08-05T09:00:00Z'))
    const ctx = makeCtx()
    const wrapper = mount(CalendarApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('.cal-cell-event').trigger('dragstart')
    const target = wrapper
      .findAll('.cal-cell')
      .find(cell => cell.attributes('data-date') === '2026-08-20')
    expect(target?.exists()).toBe(true)
    await target!.trigger('drop')
    await flushPromises()

    expect(ctx.api.entries.update).toHaveBeenCalled()
    const [id, attrs] = ctx.api.entries.update.mock.calls[0] as unknown as [
      string,
      { occurred_at: string; data: Record<string, unknown> }
    ]
    expect(id).toBe('e1')
    expect(attrs.occurred_at).toBe('2026-08-20T12:00:00.000Z')
    expect(attrs.data.end_at).toBe('2026-08-20T14:00:00.000Z')
    // The iCal stamps are wall-clock (test-runner timezone): only assert the
    // day moved, the instants above already pin the time.
    expect(attrs.data.dtstart).toMatch(/^20260820T/)
    expect(attrs.data.dtend).toMatch(/^20260820T/)
    vi.useRealTimers()
  })
})
