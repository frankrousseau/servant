<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import flatpickr from 'flatpickr'

import AutocompleteInput from '../../components/AutocompleteInput.vue'
import ComboBox from '../../components/ComboBox.vue'

import { birthdaySeed, contactField, contactName } from '../../lib/contact'
import {
  formatTime,
  todayInUserTz,
  utcToZonedParts,
  zonedToUtcISO
} from '../../lib/datetime'
import { openDialog } from '../../lib/dialog'
import { preferenceRef } from '../preference'
import { addDays, nextOccurrence, occursOn, recurrenceOf } from './recurrence'
import type { Item as ChecklistItem } from '../checklists/markdown'
import type { AppContext, Entry } from '../types'

import 'flatpickr/dist/flatpickr.min.css'

const props = defineProps<{ ctx: AppContext }>()

const MONTH_NAMES = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December'
]
const DAY_HEADERS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']

const events = ref<Entry[]>([])
const checklists = ref<Entry[]>([])
const viewMode = ref<'calendar' | 'list'>('calendar')
const currentYear = ref(new Date().getFullYear())
const currentMonth = ref(new Date().getMonth())
const loading = ref(true)
const loadError = ref('')

const modalOpen = ref(false)
const modalEditId = ref<string | null>(null)
const modalDate = ref<string | null>(null)
const modalEndDate = ref('')
const modalTitle = ref('')
const modalTime = ref('')
const modalEndTime = ref('')
const modalAllDay = ref(false)
const modalLocation = ref('')
const modalCalendar = ref('Manual')
const modalRecurrence = ref('')

const RECURRENCE_OPTIONS = [
  { value: '', label: 'Never' },
  { value: 'weekly', label: 'Every week' },
  { value: 'monthly', label: 'Every month' },
  { value: 'yearly', label: 'Every year' }
]
const modalContact = ref('')
const modalSaving = ref(false)

// ----- contacts (event ↔ contact association) -----

const contacts = ref<Entry[]>([])
const birthdayPrefs = ref<Entry | null>(null)

const contactByName = computed(() => {
  const map = new Map<string, Entry>()
  for (const contact of contacts.value) {
    const key = contactName(contact).toLowerCase()
    if (key !== '(unnamed)' && !map.has(key)) map.set(key, contact)
  }
  return map
})

const contactOptions = computed(() =>
  [...contactByName.value.values()]
    .map(contactName)
    .sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()))
)

function openEventContact(event: Entry) {
  const id = event.data.contact_id as string | undefined
  if (id) props.ctx.navigate(`/contacts/${id}`)
}

// Virtual yearly events derived from contact birthdays, never stored; they
// live under the hideable "Birthdays" agenda and click through to the contact.
// Strictly opt-in: only contacts flagged on their page (prefs/birthdays entry).
const birthdayEvents = computed<Entry[]>(() => {
  const optedIn = new Set(
    (birthdayPrefs.value?.data.contact_ids as string[]) || []
  )
  if (!optedIn.size) return []
  return contacts.value.flatMap(contact => {
    if (!optedIn.has(contact.id)) return []
    const seed = birthdaySeed(contactField(contact, 'birthday'))
    if (!seed) return []
    return [
      {
        ...contact,
        id: `birthday:${contact.id}`,
        kind: 'event',
        title: `🎂 ${contactName(contact)}`,
        // Noon UTC keeps the civil date stable across user timezones.
        occurred_at: `${seed}T12:00:00Z`,
        data: {
          all_day: true,
          calendar: 'Birthdays',
          recurrence: 'yearly',
          contact_id: contact.id,
          contact_name: contactName(contact)
        }
      } as Entry
    ]
  })
})

// Virtual all-day events from checklist item deadlines (items carry an
// optional due "YYYY-MM-DD"); pending items only, checking one off removes
// it from the calendar. Same mechanics as birthdays: never stored, own
// hideable "Deadlines" agenda, click-through to the checklist.
const deadlineEvents = computed<Entry[]>(() =>
  checklists.value.flatMap(list => {
    const items = (list.data.items as ChecklistItem[]) || []
    return items.flatMap((item, i) =>
      item.due && !item.done
        ? [
            {
              ...list,
              id: `deadline:${list.id}:${i}`,
              kind: 'event',
              title: `⏰ ${item.text}`,
              occurred_at: `${item.due}T12:00:00Z`,
              data: {
                all_day: true,
                calendar: 'Deadlines',
                checklist_id: list.id,
                checklist_title: list.title
              }
            } as Entry
          ]
        : []
    )
  })
)

// ----- calendars ("agendas") -----
// An agenda is an entry of kind "calendar", created through the manage
// dialog; events reference it by name in data.calendar. Names coming from
// synced events (iCal connectors) appear in the list too, without an entity
// behind them. "Manual" is the ever-present default.

const calendarOf = (event: Entry) =>
  ((event.data.calendar as string) || 'Manual').trim() || 'Manual'

const calendarEntities = ref<Entry[]>([])
const manageOpen = ref(false)
const newCalName = ref('')
const manageError = ref('')

const calendarEntityByName = computed(() => {
  const map = new Map<string, Entry>()
  for (const c of calendarEntities.value) {
    const name = (c.title || '').trim()
    if (name && !map.has(name)) map.set(name, c)
  }
  return map
})

async function createCalendar() {
  const name = newCalName.value.trim()
  manageError.value = ''
  if (!name) return
  if (calendars.value.some(calendar => calendar.name === name)) {
    manageError.value = 'This calendar already exists.'
    return
  }
  await props.ctx.api.entries.create({
    kind: 'calendar',
    source: 'calendar_app',
    title: name,
    data: {}
  })
  calendarEntities.value = await props.ctx.api.entries.list({
    kind: 'calendar'
  })
  newCalName.value = ''
}

async function setCalendarColor(name: string, event: Event) {
  const color = (event.target as HTMLInputElement).value
  const entity = calendarEntityByName.value.get(name)
  if (entity) {
    await props.ctx.api.entries.update(entity.id, {
      data: { ...entity.data, color }
    })
  } else {
    // Synced agenda (no entity yet): materialize one to carry the color.
    await props.ctx.api.entries.create({
      kind: 'calendar',
      source: 'calendar_app',
      title: name,
      data: { color }
    })
  }
  calendarEntities.value = await props.ctx.api.entries.list({
    kind: 'calendar'
  })
}

// ponytail: deleting a non-empty calendar is refused rather than reassigning
// its events; add a bulk "move to Manual" if that ever gets tedious.
async function deleteCalendar(name: string) {
  manageError.value = ''
  const entity = calendarEntityByName.value.get(name)
  if (!entity) return
  const count = events.value.filter(event => calendarOf(event) === name).length
  if (count > 0) {
    manageError.value = `"${name}" still has ${count} event(s). Move or delete them first.`
    return
  }
  const ok = await props.ctx.confirm.ask({
    message: `Delete calendar "${name}"?`,
    danger: true
  })
  if (!ok) return
  await props.ctx.api.entries.delete(entity.id)
  calendarEntities.value = await props.ctx.api.entries.list({
    kind: 'calendar'
  })
}

const CAL_PALETTE = [
  '#9d7bff',
  '#6ccec9',
  '#4fd674',
  '#ffb454',
  '#ff5c7a',
  '#5ca0ff'
]

// The color stored on the calendar entity wins; otherwise a stable default
// per name (djb2 hash), so it survives agendas coming and going.
function calColor(name: string): string {
  const stored = calendarEntityByName.value.get(name)?.data.color as
    | string
    | undefined
  if (stored) return stored
  let hash = 5381
  for (let i = 0; i < name.length; i++)
    hash = ((hash << 5) + hash + name.charCodeAt(i)) | 0
  return CAL_PALETTE[Math.abs(hash) % CAL_PALETTE.length]
}

// Per-chip CSS vars consumed by the stylesheet (rail, tint, time color).
function calVars(event: Entry): Record<string, string> {
  const hex = calColor(calendarOf(event))
  const red = parseInt(hex.slice(1, 3), 16)
  const green = parseInt(hex.slice(3, 5), 16)
  const blue = parseInt(hex.slice(5, 7), 16)
  return { '--cal-color': hex, '--cal-rgb': `${red}, ${green}, ${blue}` }
}

const calendars = computed(() => {
  const counts = new Map<string, number>()
  counts.set('Manual', 0)
  for (const name of calendarEntityByName.value.keys()) counts.set(name, 0)
  for (const event of allEvents.value) {
    const name = calendarOf(event)
    counts.set(name, (counts.get(name) || 0) + 1)
  }
  return Array.from(counts.entries())
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([name, count]) => ({
      name,
      count,
      color: calColor(name),
      // Entity-backed (created here) or "derived" from synced events only.
      owned: calendarEntityByName.value.has(name)
    }))
})

const hiddenCalList = preferenceRef<string[]>(props.ctx, 'calendar.hidden', [])
const hiddenCals = computed(() => new Set(hiddenCalList.value))

function toggleCalendar(name: string) {
  hiddenCalList.value = hiddenCals.value.has(name)
    ? hiddenCalList.value.filter(calendar => calendar !== name)
    : [...hiddenCalList.value, name]
}

const allEvents = computed(() => [
  ...events.value,
  ...birthdayEvents.value,
  ...deadlineEvents.value
])

const visibleEvents = computed(() =>
  allEvents.value.filter(event => !hiddenCals.value.has(calendarOf(event)))
)

const titleInput = ref<HTMLInputElement | null>(null)
const startInput = ref<HTMLInputElement | null>(null)
const endInput = ref<HTMLInputElement | null>(null)
let fpStart: flatpickr.Instance | null = null
let fpEnd: flatpickr.Instance | null = null

// Civil "YYYY-MM-DD" of a picked Date (from flatpickr, in the browser's tz):
// the calendar-day the user actually clicked. This is a wall-clock label, later
// combined with the picked time and interpreted in the user's tz on save.
function formatISODate(date: Date): string {
  const y = date.getFullYear()
  const m = String(date.getMonth() + 1).padStart(2, '0')
  const d = String(date.getDate()).padStart(2, '0')
  return `${y}-${m}-${d}`
}

// Day header for the list view. `dateStr` is a civil date label; format it
// without any tz shift (it's not an instant).
function formatDateHeader(dateStr: string): string {
  const [year, month, day] = dateStr.split('-').map(Number)
  return new Date(year, month - 1, day).toLocaleDateString(undefined, {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    year: 'numeric'
  })
}

// The user-timezone calendar date(s) an event's UTC instant falls on.
function eventDateStr(iso: string): string {
  return utcToZonedParts(iso).date
}

function eventsForDateStr(dateStr: string): Entry[] {
  return visibleEvents.value.filter(event => {
    if (!event.occurred_at) return false
    const startDate = eventDateStr(event.occurred_at)
    // Recurring events repeat from their seed date on (single-day).
    const rec = recurrenceOf(event.data)
    if (rec) return occursOn(startDate, rec, dateStr)
    const endStr = event.data.end_at as string | undefined
    if (endStr && !isNaN(new Date(endStr).getTime())) {
      return startDate <= dateStr && eventDateStr(endStr) >= dateStr
    }
    return startDate === dateStr
  })
}

interface Cell {
  empty: boolean
  day?: number
  dateStr?: string
  isToday?: boolean
  events?: Entry[]
}

const calendarCells = computed<Cell[]>(() => {
  // Weekday of the 1st is a civil-calendar fact (tz-independent). Cells carry a
  // pure "YYYY-MM-DD" label; events are bucketed by their user-tz date.
  const firstDay = new Date(currentYear.value, currentMonth.value, 1)
  let startDow = firstDay.getDay() - 1
  if (startDow < 0) startDow = 6
  const daysInMonth = new Date(
    currentYear.value,
    currentMonth.value + 1,
    0
  ).getDate()
  const today = todayInUserTz()
  const ym = `${currentYear.value}-${String(currentMonth.value + 1).padStart(2, '0')}`
  const cells: Cell[] = []
  for (let i = 0; i < startDow; i++) cells.push({ empty: true })
  for (let day = 1; day <= daysInMonth; day++) {
    const dateStr = `${ym}-${String(day).padStart(2, '0')}`
    cells.push({
      empty: false,
      day,
      dateStr,
      isToday: dateStr === today,
      events: eventsForDateStr(dateStr)
    })
  }
  return cells
})

const upcomingDays = computed(() => {
  // Group by the event's date in the user's timezone, from today (user tz) on.
  // ponytail: a recurring event is listed once, at its next occurrence;
  // expand the full horizon if that ever feels lacking.
  const today = todayInUserTz()
  const grouped: Record<string, Entry[]> = {}
  for (const event of visibleEvents.value) {
    const rec = recurrenceOf(event.data)
    const key = !event.occurred_at
      ? 'unknown'
      : rec
        ? nextOccurrence(eventDateStr(event.occurred_at), rec, today)
        : eventDateStr(event.occurred_at)
    ;(grouped[key] ||= []).push(event)
  }
  return Object.keys(grouped)
    .filter(date => date >= today)
    .sort()
    .map(date => ({ date, events: grouped[date] }))
})

const monthLabel = computed(
  () => `${MONTH_NAMES[currentMonth.value]} ${currentYear.value}`
)

function prevMonth() {
  if (--currentMonth.value < 0) {
    currentMonth.value = 11
    currentYear.value--
  }
}
function nextMonth() {
  if (++currentMonth.value > 11) {
    currentMonth.value = 0
    currentYear.value++
  }
}
function goToday() {
  currentYear.value = new Date().getFullYear()
  currentMonth.value = new Date().getMonth()
}

function openModal(dateStr: string) {
  modalEditId.value = null
  modalDate.value = dateStr
  modalEndDate.value = dateStr
  modalTitle.value = ''
  modalTime.value = '09:00'
  modalEndTime.value = '10:00'
  modalAllDay.value = false
  modalLocation.value = ''
  modalCalendar.value = 'Manual'
  modalRecurrence.value = ''
  modalContact.value = ''
  modalSaving.value = false
  modalOpen.value = true
}

function openEditModal(entry: Entry) {
  modalEditId.value = entry.id
  // Show the stored UTC instant as wall-clock date/time in the user's timezone.
  const start = entry.occurred_at
    ? utcToZonedParts(entry.occurred_at)
    : { date: todayInUserTz(), time: '09:00' }
  modalDate.value = start.date
  modalTime.value = start.time

  const endStr = entry.data.end_at as string | undefined
  if (endStr && !isNaN(new Date(endStr).getTime())) {
    const end = utcToZonedParts(endStr)
    modalEndDate.value = end.date
    modalEndTime.value = end.time
  } else {
    modalEndDate.value = modalDate.value
    modalEndTime.value = ''
  }

  modalTitle.value = entry.title || (entry.data.summary as string) || ''
  modalAllDay.value = entry.data.all_day === true
  modalLocation.value = (entry.data.location as string) || ''
  modalCalendar.value = calendarOf(entry)
  modalRecurrence.value = recurrenceOf(entry.data) || ''
  modalContact.value = (entry.data.contact_name as string) || ''
  modalSaving.value = false
  modalOpen.value = true
}

function closeModal() {
  modalOpen.value = false
  modalEditId.value = null
  modalDate.value = null
}

function onEventClick(id: string | undefined) {
  // Birthdays are virtual: nothing to edit, open the contact instead.
  if (id?.startsWith('birthday:')) {
    props.ctx.navigate(`/contacts/${id.slice('birthday:'.length)}`)
    return
  }
  // Deadlines are virtual too: open their checklist.
  if (id?.startsWith('deadline:')) {
    const listId = id.slice('deadline:'.length).split(':')[0]
    props.ctx.navigate(`/apps/checklists?selected=${listId}`)
    return
  }
  const entry = events.value.find(event => event.id === id)
  if (entry) openEditModal(entry)
}

// All-day events use date-only dtstart/dtend (iCal convention).
function icalStamp(dateStr: string, timeStr: string, allDay: boolean): string {
  const date = dateStr.replace(/-/g, '')
  return allDay ? date : `${date}T${timeStr.replace(':', '')}00`
}

// ----- drag and drop: move an event to another day -----

const draggedId = ref<string | null>(null)
const dragOverDate = ref<string | null>(null)

// Virtual events (birthdays, checklist deadlines) are derived, not stored:
// there is nothing to move, so they stay undraggable.
function draggable(entry: Entry): boolean {
  return !entry.id.startsWith('birthday:') && !entry.id.startsWith('deadline:')
}

function onEventDragStart(entry: Entry, event: DragEvent) {
  draggedId.value = entry.id
  event.dataTransfer?.setData('text/plain', entry.id)
  if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move'
}

function onEventDragEnd() {
  draggedId.value = null
  dragOverDate.value = null
}

// Drop moves start and end by the same number of days, keeping both times.
// A recurring event moves by its seed, so the whole series follows.
async function moveEventTo(dateStr: string) {
  const entry = events.value.find(event => event.id === draggedId.value)
  onEventDragEnd()
  if (!entry?.occurred_at) return
  const start = utcToZonedParts(entry.occurred_at)
  if (start.date === dateStr) return

  const allDay = entry.data.all_day === true
  const endStr = entry.data.end_at as string | undefined
  const end =
    endStr && !isNaN(new Date(endStr).getTime())
      ? utcToZonedParts(endStr)
      : null
  const delta = Math.round(
    (Date.parse(dateStr) - Date.parse(start.date)) / 86_400_000
  )
  const endDateStr = end ? addDays(end.date, delta) : null

  try {
    await props.ctx.api.entries.update(entry.id, {
      occurred_at: zonedToUtcISO(dateStr, start.time),
      data: {
        ...entry.data,
        dtstart: icalStamp(dateStr, start.time, allDay),
        dtend: endDateStr
          ? icalStamp(endDateStr, end!.time, allDay)
          : undefined,
        end_at: endDateStr ? zonedToUtcISO(endDateStr, end!.time) : undefined
      }
    })
    events.value = await props.ctx.api.entries.list({ kind: 'event' })
  } catch {
    // the event stays where it was
  }
}

async function saveEvent() {
  if (!modalDate.value || !modalTitle.value.trim()) return
  modalSaving.value = true

  const endDateStr = modalEndDate.value || modalDate.value
  const allDay = modalAllDay.value
  const startTimeStr = allDay ? '00:00' : modalTime.value
  const endTimeStr = allDay ? '23:59' : modalEndTime.value || '23:59'
  const dtstart = icalStamp(modalDate.value, startTimeStr, allDay)
  const dtend = icalStamp(endDateStr, endTimeStr, allDay)
  // Interpret the picked wall-clock time in the user's timezone, store as UTC.
  const occurredAt = zonedToUtcISO(modalDate.value, startTimeStr)
  const endAt = zonedToUtcISO(endDateStr, endTimeStr)

  const attrs = {
    kind: 'event',
    source: modalEditId.value ? undefined : 'manual',
    title: modalTitle.value.trim(),
    occurred_at: occurredAt,
    data: {
      summary: modalTitle.value.trim(),
      dtstart,
      dtend,
      end_at: endAt,
      all_day: allDay,
      location: modalLocation.value.trim() || null,
      calendar: modalCalendar.value.trim() || 'Manual',
      recurrence: modalRecurrence.value || null,
      contact_name: modalContact.value.trim() || null,
      contact_id:
        contactByName.value.get(modalContact.value.trim().toLowerCase())?.id ||
        null
    }
  }

  try {
    if (modalEditId.value) {
      await props.ctx.api.entries.update(modalEditId.value, attrs)
    } else {
      await props.ctx.api.entries.create(attrs)
    }
    events.value = await props.ctx.api.entries.list({ kind: 'event' })
    closeModal()
  } catch {
    modalSaving.value = false
  }
}

async function deleteEvent() {
  if (!modalEditId.value) return
  const confirmed = await props.ctx.confirm.ask({
    message: 'Delete this event?',
    danger: true
  })
  if (!confirmed) return
  try {
    await props.ctx.api.entries.delete(modalEditId.value)
    events.value = await props.ctx.api.entries.list({ kind: 'event' })
    closeModal()
  } catch {
    // ignore
  }
}

async function exportIcs() {
  const res = await props.ctx.api.fetch('/api/export/entries.ics')
  const blob = await res.blob()
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = 'calendar.ics'
  a.click()
  URL.revokeObjectURL(url)
}

function destroyPickers() {
  fpStart?.destroy()
  fpEnd?.destroy()
  fpStart = null
  fpEnd = null
}

watch(modalOpen, async open => {
  if (open) {
    await nextTick()
    titleInput.value?.focus()
    if (startInput.value) {
      fpStart = flatpickr(startInput.value, {
        dateFormat: 'Y-m-d',
        defaultDate: modalDate.value || undefined,
        onChange: ([date]) => {
          modalDate.value = formatISODate(date)
          if (modalEndDate.value < modalDate.value) {
            modalEndDate.value = modalDate.value
            fpEnd?.setDate(modalDate.value)
          }
        }
      }) as flatpickr.Instance
    }
    if (endInput.value) {
      fpEnd = flatpickr(endInput.value, {
        dateFormat: 'Y-m-d',
        defaultDate: modalEndDate.value || undefined,
        onChange: ([date]) => {
          modalEndDate.value = formatISODate(date)
        }
      }) as flatpickr.Instance
    }
  } else {
    destroyPickers()
  }
})

async function reload() {
  loadError.value = ''
  try {
    const [evs, cals, cts, prefs, lists] = await Promise.all([
      props.ctx.api.entries.list({ kind: 'event' }),
      props.ctx.api.entries.list({ kind: 'calendar' }),
      // Contacts, prefs and checklists only feed the association combobox,
      // the birthday opt-ins and the deadline agenda; degrade gracefully.
      props.ctx.api.entries
        .list({ kind: 'contact' })
        .catch(() => [] as Entry[]),
      props.ctx.api.entries.list({ kind: 'prefs' }).catch(() => [] as Entry[]),
      props.ctx.api.entries
        .list({ kind: 'checklist' })
        .catch(() => [] as Entry[])
    ])
    events.value = evs
    calendarEntities.value = cals
    contacts.value = cts
    birthdayPrefs.value =
      prefs.find(entry => entry.title === 'birthdays') || null
    checklists.value = lists
  } catch (err) {
    loadError.value =
      err instanceof Error ? err.message : 'Failed to load events'
  } finally {
    loading.value = false
  }
}

onMounted(reload)
onUnmounted(destroyPickers)
</script>

<template>
  <p v-if="loading" class="cal-loading">Loading events...</p>
  <p v-else-if="loadError" class="cal-loading">{{ loadError }}</p>
  <div v-else class="cal-container">
    <div class="cal-header">
      <template v-if="viewMode === 'calendar'">
        <div class="cal-nav">
          <button class="cal-nav-btn" @click="prevMonth">‹</button>
          <button class="cal-nav-btn cal-today-btn" @click="goToday">
            Today
          </button>
          <button class="cal-nav-btn" @click="nextMonth">›</button>
        </div>
        <span class="cal-month-label">{{ monthLabel }}</span>
      </template>
      <span v-else class="cal-month-label">Upcoming</span>
      <div class="cal-header-actions">
        <button
          class="cal-nav-btn"
          title="Manage calendars"
          @click="manageOpen = true"
        >
          Calendars
        </button>
        <button class="cal-nav-btn" title="Export as .ics" @click="exportIcs">
          Export
        </button>
        <div class="cal-view-toggle">
          <button
            class="cal-toggle-btn"
            :class="{ 'cal-toggle-btn--active': viewMode === 'calendar' }"
            @click="viewMode = 'calendar'"
          >
            Grid
          </button>
          <button
            class="cal-toggle-btn"
            :class="{ 'cal-toggle-btn--active': viewMode === 'list' }"
            @click="viewMode = 'list'"
          >
            List
          </button>
        </div>
      </div>
    </div>

    <div v-if="calendars.length > 1" class="cal-legend">
      <button
        v-for="calendar in calendars"
        :key="calendar.name"
        class="cal-legend-item"
        :class="{ 'cal-legend-item--off': hiddenCals.has(calendar.name) }"
        :title="
          hiddenCals.has(calendar.name)
            ? 'Show this agenda'
            : 'Hide this agenda'
        "
        @click="toggleCalendar(calendar.name)"
      >
        <span
          class="cal-legend-swatch"
          :style="{ background: calendar.color }"
        ></span>
        {{ calendar.name }}
        <span class="cal-legend-count">{{ calendar.count }}</span>
      </button>
    </div>

    <div v-if="viewMode === 'calendar'" class="cal-grid">
      <div v-for="dh in DAY_HEADERS" :key="dh" class="cal-grid-header">
        {{ dh }}
      </div>
      <div
        v-for="(cell, index) in calendarCells"
        :key="index"
        class="cal-cell"
        :class="{
          'cal-cell--empty': cell.empty,
          'cal-cell--today': cell.isToday,
          'cal-cell--drop': !cell.empty && dragOverDate === cell.dateStr
        }"
        :data-date="cell.empty ? undefined : cell.dateStr"
        @click="!cell.empty && cell.dateStr && openModal(cell.dateStr)"
        @dragover.prevent="
          dragOverDate = cell.empty ? null : (cell.dateStr ?? null)
        "
        @drop.prevent="!cell.empty && cell.dateStr && moveEventTo(cell.dateStr)"
      >
        <template v-if="!cell.empty">
          <span class="cal-day-num">{{ cell.day }}</span>
          <div
            v-for="ev in (cell.events || []).slice(0, 3)"
            :key="ev.id"
            class="cal-cell-event"
            :class="{
              'cal-cell-event--allday': ev.data?.all_day,
              'cal-cell-event--dragging': draggedId === ev.id
            }"
            :style="calVars(ev)"
            :draggable="draggable(ev)"
            :title="
              draggable(ev) ? 'Drag to another day to move it' : undefined
            "
            @click.stop="onEventClick(ev.id)"
            @dragstart.stop="onEventDragStart(ev, $event)"
            @dragend="onEventDragEnd"
          >
            <span
              v-if="!ev.data?.all_day && ev.occurred_at"
              class="cal-chip-time"
              >{{ formatTime(ev.occurred_at) }}</span
            >
            <span
              v-if="ev.data?.recurrence"
              class="cal-chip-rec"
              title="Recurring"
              >↻</span
            >
            <span class="cal-chip-title">{{ ev.title || 'Untitled' }}</span>
          </div>
          <div v-if="(cell.events?.length ?? 0) > 3" class="cal-cell-more">
            +{{ cell.events!.length - 3 }} more
          </div>
        </template>
      </div>
    </div>

    <template v-else>
      <p v-if="upcomingDays.length === 0" class="cal-empty">
        No upcoming events.
      </p>
      <div v-for="group in upcomingDays" :key="group.date" class="cal-day">
        <div class="cal-day-header">{{ formatDateHeader(group.date) }}</div>
        <div
          v-for="event in group.events"
          :key="event.id"
          class="cal-event"
          @click.stop="onEventClick(event.id)"
        >
          <div
            class="cal-event-time"
            :style="{ color: calColor(calendarOf(event)) }"
          >
            {{
              event.data.all_day || !event.data.dtstart
                ? 'All day'
                : formatTime(event.occurred_at || '')
            }}
          </div>
          <div class="cal-event-body">
            <span class="cal-event-title">
              <span
                v-if="event.data.recurrence"
                class="cal-event-rec"
                title="Recurring"
                >↻</span
              >
              {{ event.title || 'Untitled' }}
            </span>
            <span v-if="event.data.location" class="cal-event-loc">{{
              event.data.location
            }}</span>
            <span
              v-if="event.data.contact_name"
              class="cal-event-contact"
              :title="event.data.contact_id ? 'Open contact' : undefined"
              @click.stop="openEventContact(event)"
              >👤 {{ event.data.contact_name }}</span
            >
            <span
              class="cal-event-cal"
              :style="{ color: calColor(calendarOf(event)) }"
              >{{ calendarOf(event) }}</span
            >
          </div>
        </div>
      </div>
    </template>
  </div>

  <Teleport to="body">
    <dialog
      v-if="manageOpen"
      :ref="openDialog"
      class="modal-dialog"
      aria-labelledby="cal-manage-title"
      @click.self="manageOpen = false"
      @cancel="manageOpen = false"
    >
      <div class="cal-modal">
        <div id="cal-manage-title" class="cal-modal-header">Calendars</div>
        <div class="cal-manage-list">
          <div
            v-for="calendar in calendars"
            :key="calendar.name"
            class="cal-manage-row"
          >
            <input
              type="color"
              class="cal-color-input"
              :value="calendar.color"
              title="Pick a color for this calendar"
              @change="setCalendarColor(calendar.name, $event)"
            />
            <span class="cal-manage-name">{{ calendar.name }}</span>
            <span class="cal-manage-count">{{ calendar.count }} evt</span>
            <span
              v-if="!calendar.owned && calendar.name !== 'Manual'"
              class="cal-manage-synced"
              >synced</span
            >
            <button
              v-if="calendar.owned"
              class="cal-manage-delete"
              title="Delete this calendar"
              @click="deleteCalendar(calendar.name)"
            >
              ✕
            </button>
          </div>
        </div>
        <p v-if="manageError" class="cal-manage-error">{{ manageError }}</p>
        <div class="cal-manage-add">
          <input
            v-model="newCalName"
            type="text"
            placeholder="New calendar name"
            @keydown.enter="createCalendar"
          />
          <button
            class="cal-modal-btn cal-modal-btn--primary"
            @click="createCalendar"
          >
            Add
          </button>
        </div>
        <div class="cal-modal-actions">
          <span class="cal-modal-spacer"></span>
          <button class="cal-modal-btn" @click="manageOpen = false">
            Close
          </button>
        </div>
      </div>
    </dialog>

    <dialog
      v-if="modalOpen"
      :ref="openDialog"
      class="modal-dialog"
      aria-labelledby="cal-event-title"
      @click.self="closeModal"
      @cancel="closeModal"
    >
      <div class="cal-modal">
        <div id="cal-event-title" class="cal-modal-header">
          {{ modalEditId ? 'Edit event' : 'New event' }}
        </div>
        <div class="cal-modal-field">
          <label>Title</label>
          <input
            ref="titleInput"
            v-model="modalTitle"
            type="text"
            placeholder="Event title"
            @keydown.enter="saveEvent"
          />
        </div>
        <div class="cal-modal-row">
          <div class="cal-modal-field">
            <!-- type=text (not date): flatpickr provides the themed calendar; a
                 native date picker would open a second calendar on top of it. -->
            <label>Start date</label
            ><input ref="startInput" type="text" readonly />
          </div>
          <div class="cal-modal-field">
            <label>End date</label><input ref="endInput" type="text" readonly />
          </div>
        </div>
        <label class="cal-allday-toggle">
          <input type="checkbox" v-model="modalAllDay" />
          All day
        </label>
        <div v-if="!modalAllDay" class="cal-modal-row">
          <div class="cal-modal-field">
            <label>Start time</label><input v-model="modalTime" type="time" />
          </div>
          <div class="cal-modal-field">
            <label>End time</label><input v-model="modalEndTime" type="time" />
          </div>
        </div>
        <div class="cal-modal-field">
          <label>Location</label
          ><input v-model="modalLocation" type="text" placeholder="Optional" />
        </div>
        <div class="cal-modal-row">
          <div class="cal-modal-field">
            <label>Calendar</label>
            <ComboBox
              v-model="modalCalendar"
              :options="calendars.map(calendar => calendar.name)"
            />
          </div>
          <div class="cal-modal-field">
            <label>Repeats</label>
            <ComboBox v-model="modalRecurrence" :options="RECURRENCE_OPTIONS" />
          </div>
        </div>
        <div class="cal-modal-field">
          <label>Contact</label>
          <AutocompleteInput
            v-model="modalContact"
            :options="contactOptions"
            placeholder="Optional: link a contact"
          />
        </div>
        <div class="cal-modal-actions">
          <button
            v-if="modalEditId"
            class="cal-modal-btn cal-modal-btn--danger"
            @click="deleteEvent"
          >
            Delete
          </button>
          <span class="cal-modal-spacer"></span>
          <button class="cal-modal-btn" @click="closeModal">Cancel</button>
          <button
            class="cal-modal-btn cal-modal-btn--primary"
            :disabled="modalSaving"
            @click="saveEvent"
          >
            {{ modalSaving ? 'Saving...' : 'Save' }}
          </button>
        </div>
      </div>
    </dialog>
  </Teleport>
</template>

<style scoped>
.cal-loading {
  color: var(--text-muted);
  padding: 2rem;
  font-family: var(--font-mono);
}
.cal-container {
  /* The header and grid pad nothing themselves, and the app is now flush
     against the window, so the breathing room lives here (same as finance
     and trackers). */
  padding: 1rem 1.25rem;
  height: 100vh;
  display: flex;
  flex-direction: column;
}
.cal-header {
  display: flex;
  align-items: center;
  gap: 1rem;
  margin-bottom: 1rem;
}
.cal-nav {
  display: flex;
  gap: 0.25rem;
}
.cal-nav-btn {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  padding: 0.3rem 0.6rem;
  border-radius: var(--control-radius);
  cursor: pointer;
  font-size: 1rem;
}
.cal-nav-btn:hover {
  color: var(--text);
  border-color: var(--text-muted);
}
.cal-today-btn {
  font-size: 0.85rem;
}
.cal-month-label {
  font-family: var(--font-display);
  font-weight: 400;
  font-size: 1.6rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  flex: 1;
}
.cal-header-actions {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.cal-view-toggle {
  display: flex;
  gap: 0.2rem;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 2px;
}
.cal-toggle-btn {
  background: transparent;
  border: none;
  color: var(--text-muted);
  padding: 0.3rem 0.7rem;
  border-radius: calc(var(--control-radius) - 2px);
  cursor: pointer;
  font-size: 0.85rem;
}
.cal-toggle-btn:hover {
  color: var(--text);
}
.cal-toggle-btn--active {
  background: var(--primary);
  color: var(--primary-contrast);
}
/* :hover (0-2-1) outranks the modifier (0-2-0); keep the contrast text. */
.cal-toggle-btn--active:hover {
  color: var(--primary-contrast);
}
.cal-grid {
  display: grid;
  grid-template-columns: repeat(7, 1fr);
  border: 1px solid var(--border);
  border-radius: 8px;
  overflow: hidden;
  flex: 1;
  grid-template-rows: auto repeat(6, 1fr);
}
.cal-grid-header {
  padding: 0.5rem;
  text-align: center;
  font-family: var(--font-mono);
  font-size: 0.72rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.12em;
  background: var(--bg-surface);
  border-bottom: 1px solid var(--border);
}
.cal-cell {
  padding: 0.35rem;
  border-bottom: 1px solid var(--border);
  border-right: 1px solid var(--border);
  cursor: default;
  position: relative;
  overflow: hidden;
}
.cal-cell:nth-child(7n + 14) {
  border-right: none;
}
.cal-cell--empty {
  background: var(--bg-surface);
}
/* Today: phosphor ring inside the cell */
.cal-cell--today {
  background: rgba(var(--primary-rgb), 0.08);
  box-shadow: inset 0 0 0 1px rgba(var(--primary-rgb), 0.55);
}
.cal-cell--today .cal-day-num {
  color: var(--primary);
  font-weight: 700;
}
/* Drop target while an event is dragged over it */
.cal-cell--drop {
  background: rgba(var(--primary-rgb), 0.18);
  box-shadow: inset 0 0 0 2px var(--primary);
}
.cal-day-num {
  font-family: var(--font-mono);
  font-size: 0.8rem;
  color: var(--text-muted);
}
/* Event chips: colored rail + tint per agenda (--cal-color/--cal-rgb are set
   inline per chip), mono time; same selection language as the rest of the
   system */
.cal-cell-event {
  display: flex;
  align-items: baseline;
  gap: 4px;
  font-size: 0.72rem;
  color: var(--text);
  margin-top: 2px;
  white-space: nowrap;
  overflow: hidden;
  background: rgba(var(--cal-rgb, var(--primary-rgb)), 0.1);
  border-left: 2px solid var(--cal-color, var(--primary));
  padding: 1px 4px 1px 5px;
  border-radius: 0 3px 3px 0;
  cursor: pointer;
  transition: background 0.1s;
}
.cal-cell-event:hover {
  background: rgba(var(--cal-rgb, var(--primary-rgb)), 0.25);
}
.cal-cell-event--dragging {
  opacity: 0.4;
}
/* All-day: a solid band, no rail, no time */
.cal-cell-event--allday {
  background: rgba(var(--cal-rgb, var(--primary-rgb)), 0.22);
  border-left-color: transparent;
  border-radius: 3px;
}
.cal-cell-more {
  font-family: var(--font-mono);
  font-size: 0.66rem;
  color: var(--text-muted);
  margin-top: 2px;
  padding-left: 5px;
}
.cal-chip-time {
  font-family: var(--font-mono);
  font-size: 0.68rem;
  color: var(--cal-color, var(--primary));
  flex-shrink: 0;
}
/* Agenda legend: click to hide/show an agenda */
.cal-legend {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
  margin-bottom: 0.75rem;
}
.cal-legend-item {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text);
  font-family: var(--font-mono);
  font-size: 0.75rem;
  padding: 0.25rem 0.6rem;
  border-radius: 999px;
  cursor: pointer;
}
.cal-legend-item:hover {
  border-color: var(--text-muted);
}
.cal-legend-item--off {
  opacity: 0.45;
}
.cal-legend-item--off .cal-legend-swatch {
  background: var(--text-muted) !important;
}
.cal-legend-swatch {
  width: 9px;
  height: 9px;
  border-radius: 2px;
  flex-shrink: 0;
}
.cal-legend-count {
  color: var(--text-muted);
}
/* Manage-calendars dialog */
.cal-color-input {
  width: 20px;
  height: 20px;
  padding: 0;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: transparent;
  cursor: pointer;
  flex-shrink: 0;
}
.cal-color-input::-webkit-color-swatch-wrapper {
  padding: 2px;
}
.cal-color-input::-webkit-color-swatch {
  border: none;
  border-radius: 2px;
}
.cal-color-input::-moz-color-swatch {
  border: none;
  border-radius: 2px;
}
.cal-manage-list {
  display: flex;
  flex-direction: column;
  margin-bottom: 0.75rem;
}
.cal-manage-row {
  display: flex;
  align-items: center;
  gap: 0.55rem;
  padding: 0.4rem 0.15rem;
  border-bottom: 1px solid var(--border);
  font-size: 0.9rem;
}
.cal-manage-name {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.cal-manage-count,
.cal-manage-synced {
  font-family: var(--font-mono);
  font-size: 0.72rem;
  color: var(--text-muted);
  flex-shrink: 0;
}
.cal-manage-synced {
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.cal-manage-delete {
  background: transparent;
  border: none;
  color: var(--text-muted);
  cursor: pointer;
  padding: 0 0.25rem;
  font-size: 1.15rem;
  flex-shrink: 0;
}
.cal-manage-delete:hover {
  color: var(--danger);
}
.cal-manage-error {
  color: var(--danger);
  font-size: 0.82rem;
  margin: 0 0 0.5rem;
}
.cal-manage-add {
  display: flex;
  gap: 0.5rem;
}
.cal-manage-add input {
  flex: 1;
  padding: 0.4rem 0.65rem;
  font-size: 0.9rem;
  border-radius: 6px;
}
.cal-chip-title {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
}
.cal-empty {
  color: var(--text-muted);
  padding: 2rem 0;
  font-family: var(--font-mono);
  font-size: 0.88rem;
}
.cal-day {
  margin-bottom: 1.5rem;
}
.cal-day-header {
  font-weight: 600;
  font-size: 0.9rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
  padding-bottom: 0.5rem;
  border-bottom: 1px solid var(--border);
  margin-bottom: 0.5rem;
}
.cal-event {
  display: flex;
  gap: 1rem;
  padding: 0.5rem 0;
  cursor: pointer;
  border-radius: 6px;
}
.cal-event:hover {
  background: var(--bg-hover);
}
.cal-event-time {
  width: 64px;
  flex-shrink: 0;
  font-family: var(--font-mono);
  font-size: 0.85rem;
  color: var(--primary);
}
.cal-event-body {
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
}
.cal-event-title {
  font-weight: 500;
}
.cal-event-loc {
  font-size: 0.9rem;
  color: var(--text-muted);
}
.cal-chip-rec {
  flex-shrink: 0;
  font-size: 0.68rem;
  color: var(--cal-color, var(--primary));
}
.cal-event-rec {
  color: var(--text-muted);
}
.cal-event-contact {
  font-size: 0.85rem;
  color: var(--text-muted);
  cursor: pointer;
  align-self: flex-start;
}
.cal-event-contact:hover {
  color: var(--primary);
}
.cal-event-cal {
  font-size: 0.8rem;
  color: var(--primary);
}
.cal-cell[data-date] {
  cursor: pointer;
}
.cal-cell[data-date]:hover {
  background: rgba(var(--primary-rgb), 0.04);
}
.cal-cell--today:hover {
  background: rgba(var(--primary-rgb), 0.1);
}
.cal-allday-toggle {
  display: flex;
  align-items: center;
  gap: 0.45rem;
  font-size: 0.9rem;
  color: var(--text-muted);
  cursor: pointer;
  margin: 0.25rem 0;
}
.cal-allday-toggle input {
  width: 16px;
  height: 16px;
  padding: 0;
  margin: 0;
  flex-shrink: 0;
  accent-color: var(--primary);
}
.cal-modal {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 1.25rem;
  width: 100%;
  max-width: 400px;
}
.cal-modal-header {
  font-weight: 600;
  font-size: 1.05rem;
  margin-bottom: 1rem;
}
.cal-modal-field {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  margin-bottom: 0.75rem;
}
.cal-modal-field label {
  font-size: 0.85rem;
  color: var(--text-muted);
}
.cal-modal-row {
  display: flex;
  gap: 0.75rem;
}
.cal-modal-row .cal-modal-field {
  flex: 1;
}
.cal-modal-actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
  margin-top: 0.5rem;
}
.cal-modal-btn {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text);
  padding: 0.35rem 0.8rem;
  border-radius: var(--control-radius);
  cursor: pointer;
  font-size: 0.85rem;
}
.cal-modal-btn:hover {
  border-color: var(--text-muted);
}
.cal-modal-btn--primary {
  background: var(--primary);
  border-color: var(--primary);
  color: var(--primary-contrast);
}
.cal-modal-btn--primary:hover {
  background: var(--primary-hover);
}
.cal-modal-btn--danger {
  color: var(--danger);
  border-color: var(--danger);
}
.cal-modal-btn--danger:hover {
  background: rgba(240, 108, 108, 0.1);
}
.cal-modal-spacer {
  flex: 1;
}
.cal-modal-btn:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}
</style>

<!-- Flatpickr theme overrides live in style.css: the picker renders on
     document.body and is shared with DateInput.vue. -->
