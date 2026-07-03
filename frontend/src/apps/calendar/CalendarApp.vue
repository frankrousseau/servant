<script setup lang="ts">
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from "vue";
import flatpickr from "flatpickr";
import "flatpickr/dist/flatpickr.min.css";
import type { AppContext, Entry } from "../types";
import {
  formatTime,
  zonedToUtcISO,
  utcToZonedParts,
  todayInUserTz,
} from "../../lib/datetime";

const props = defineProps<{ ctx: AppContext }>();

const MONTH_NAMES = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];
const DAY_HEADERS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

const events = ref<Entry[]>([]);
const viewMode = ref<"calendar" | "list">("calendar");
const currentYear = ref(new Date().getFullYear());
const currentMonth = ref(new Date().getMonth());
const loading = ref(true);
const loadError = ref("");

const modalOpen = ref(false);
const modalEditId = ref<string | null>(null);
const modalDate = ref<string | null>(null);
const modalEndDate = ref("");
const modalTitle = ref("");
const modalTime = ref("");
const modalEndTime = ref("");
const modalLocation = ref("");
const modalSaving = ref(false);

const titleInput = ref<HTMLInputElement | null>(null);
const startInput = ref<HTMLInputElement | null>(null);
const endInput = ref<HTMLInputElement | null>(null);
let fpStart: flatpickr.Instance | null = null;
let fpEnd: flatpickr.Instance | null = null;

// Civil "YYYY-MM-DD" of a picked Date (from flatpickr, in the browser's tz) —
// the calendar-day the user actually clicked. This is a wall-clock label, later
// combined with the picked time and interpreted in the user's tz on save.
function formatISODate(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

// Day header for the list view. `dateStr` is a civil date label; format it
// without any tz shift (it's not an instant).
function formatDateHeader(dateStr: string): string {
  const [y, m, d] = dateStr.split("-").map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, {
    weekday: "short",
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

// The user-timezone calendar date(s) an event's UTC instant falls on.
function eventDateStr(iso: string): string {
  return utcToZonedParts(iso).date;
}

function eventsForDateStr(dateStr: string): Entry[] {
  return events.value.filter((e) => {
    if (!e.occurred_at) return false;
    const startDate = eventDateStr(e.occurred_at);
    const endStr = e.data.end_at as string | undefined;
    if (endStr && !isNaN(new Date(endStr).getTime())) {
      return startDate <= dateStr && eventDateStr(endStr) >= dateStr;
    }
    return startDate === dateStr;
  });
}

interface Cell {
  empty: boolean;
  day?: number;
  dateStr?: string;
  isToday?: boolean;
  events?: Entry[];
}

const calendarCells = computed<Cell[]>(() => {
  // Weekday of the 1st is a civil-calendar fact (tz-independent). Cells carry a
  // pure "YYYY-MM-DD" label; events are bucketed by their user-tz date.
  const firstDay = new Date(currentYear.value, currentMonth.value, 1);
  let startDow = firstDay.getDay() - 1;
  if (startDow < 0) startDow = 6;
  const daysInMonth = new Date(currentYear.value, currentMonth.value + 1, 0).getDate();
  const today = todayInUserTz();
  const ym = `${currentYear.value}-${String(currentMonth.value + 1).padStart(2, "0")}`;
  const cells: Cell[] = [];
  for (let i = 0; i < startDow; i++) cells.push({ empty: true });
  for (let day = 1; day <= daysInMonth; day++) {
    const dateStr = `${ym}-${String(day).padStart(2, "0")}`;
    cells.push({
      empty: false,
      day,
      dateStr,
      isToday: dateStr === today,
      events: eventsForDateStr(dateStr),
    });
  }
  return cells;
});

const upcomingDays = computed(() => {
  // Group by the event's date in the user's timezone, from today (user tz) on.
  const today = todayInUserTz();
  const grouped: Record<string, Entry[]> = {};
  for (const e of events.value) {
    const key = e.occurred_at ? eventDateStr(e.occurred_at) : "unknown";
    (grouped[key] ||= []).push(e);
  }
  return Object.keys(grouped)
    .filter((d) => d >= today)
    .sort()
    .map((date) => ({ date, events: grouped[date] }));
});

const monthLabel = computed(() => `${MONTH_NAMES[currentMonth.value]} ${currentYear.value}`);

function prevMonth() {
  if (--currentMonth.value < 0) {
    currentMonth.value = 11;
    currentYear.value--;
  }
}
function nextMonth() {
  if (++currentMonth.value > 11) {
    currentMonth.value = 0;
    currentYear.value++;
  }
}
function goToday() {
  currentYear.value = new Date().getFullYear();
  currentMonth.value = new Date().getMonth();
}

function openModal(dateStr: string) {
  modalEditId.value = null;
  modalDate.value = dateStr;
  modalEndDate.value = dateStr;
  modalTitle.value = "";
  modalTime.value = "09:00";
  modalEndTime.value = "10:00";
  modalLocation.value = "";
  modalSaving.value = false;
  modalOpen.value = true;
}

function openEditModal(entry: Entry) {
  modalEditId.value = entry.id;
  // Show the stored UTC instant as wall-clock date/time in the user's timezone.
  const start = entry.occurred_at
    ? utcToZonedParts(entry.occurred_at)
    : { date: todayInUserTz(), time: "09:00" };
  modalDate.value = start.date;
  modalTime.value = start.time;

  const endStr = entry.data.end_at as string | undefined;
  if (endStr && !isNaN(new Date(endStr).getTime())) {
    const end = utcToZonedParts(endStr);
    modalEndDate.value = end.date;
    modalEndTime.value = end.time;
  } else {
    modalEndDate.value = modalDate.value;
    modalEndTime.value = "";
  }

  modalTitle.value = entry.title || (entry.data.summary as string) || "";
  modalLocation.value = (entry.data.location as string) || "";
  modalSaving.value = false;
  modalOpen.value = true;
}

function closeModal() {
  modalOpen.value = false;
  modalEditId.value = null;
  modalDate.value = null;
}

function onEventClick(id: string | undefined) {
  const entry = events.value.find((e) => e.id === id);
  if (entry) openEditModal(entry);
}

async function saveEvent() {
  if (!modalDate.value || !modalTitle.value.trim()) return;
  modalSaving.value = true;

  const endDateStr = modalEndDate.value || modalDate.value;
  const endTimeStr = modalEndTime.value || "23:59";
  const dtstart = modalDate.value.replace(/-/g, "") + "T" + modalTime.value.replace(":", "") + "00";
  const dtend = endDateStr.replace(/-/g, "") + "T" + endTimeStr.replace(":", "") + "00";
  // Interpret the picked wall-clock time in the user's timezone, store as UTC.
  const occurredAt = zonedToUtcISO(modalDate.value, modalTime.value);
  const endAt = zonedToUtcISO(endDateStr, endTimeStr);

  const attrs = {
    kind: "event",
    source: modalEditId.value ? undefined : "manual",
    title: modalTitle.value.trim(),
    occurred_at: occurredAt,
    data: {
      summary: modalTitle.value.trim(),
      dtstart,
      dtend,
      end_at: endAt,
      location: modalLocation.value.trim() || null,
      calendar: modalEditId.value
        ? events.value.find((e) => e.id === modalEditId.value)?.data.calendar || "Manual"
        : "Manual",
    },
  };

  try {
    if (modalEditId.value) {
      await props.ctx.api.entries.update(modalEditId.value, attrs);
    } else {
      await props.ctx.api.entries.create(attrs);
    }
    events.value = await props.ctx.api.entries.list({ kind: "event" });
    closeModal();
  } catch {
    modalSaving.value = false;
  }
}

async function deleteEvent() {
  if (!modalEditId.value) return;
  const confirmed = await props.ctx.confirm.ask({ message: "Delete this event?", danger: true });
  if (!confirmed) return;
  try {
    await props.ctx.api.entries.delete(modalEditId.value);
    events.value = await props.ctx.api.entries.list({ kind: "event" });
    closeModal();
  } catch {
    // ignore
  }
}

async function exportIcs() {
  const res = await props.ctx.api.fetch("/api/export/entries.ics");
  const blob = await res.blob();
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "calendar.ics";
  a.click();
  URL.revokeObjectURL(url);
}

function destroyPickers() {
  fpStart?.destroy();
  fpEnd?.destroy();
  fpStart = null;
  fpEnd = null;
}

watch(modalOpen, async (open) => {
  if (open) {
    await nextTick();
    titleInput.value?.focus();
    if (startInput.value) {
      fpStart = flatpickr(startInput.value, {
        dateFormat: "Y-m-d",
        defaultDate: modalDate.value || undefined,
        onChange: ([date]) => {
          modalDate.value = formatISODate(date);
          if (modalEndDate.value < modalDate.value) {
            modalEndDate.value = modalDate.value;
            fpEnd?.setDate(modalDate.value);
          }
        },
      }) as flatpickr.Instance;
    }
    if (endInput.value) {
      fpEnd = flatpickr(endInput.value, {
        dateFormat: "Y-m-d",
        defaultDate: modalEndDate.value || undefined,
        onChange: ([date]) => {
          modalEndDate.value = formatISODate(date);
        },
      }) as flatpickr.Instance;
    }
  } else {
    destroyPickers();
  }
});

async function reload() {
  loadError.value = "";
  try {
    events.value = await props.ctx.api.entries.list({ kind: "event" });
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : "Failed to load events";
  } finally {
    loading.value = false;
  }
}

onMounted(reload);
onUnmounted(destroyPickers);
</script>

<template>
  <p v-if="loading" class="cal-loading">Loading events...</p>
  <p v-else-if="loadError" class="cal-loading">{{ loadError }}</p>
  <div v-else class="cal-container">
    <div class="cal-header">
      <template v-if="viewMode === 'calendar'">
        <div class="cal-nav">
          <button class="cal-nav-btn" @click="prevMonth">‹</button>
          <button class="cal-nav-btn cal-today-btn" @click="goToday">Today</button>
          <button class="cal-nav-btn" @click="nextMonth">›</button>
        </div>
        <span class="cal-month-label">{{ monthLabel }}</span>
      </template>
      <span v-else class="cal-month-label">Upcoming</span>
      <div class="cal-header-actions">
        <button class="cal-nav-btn" title="Export as .ics" @click="exportIcs">Export</button>
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

    <div v-if="viewMode === 'calendar'" class="cal-grid">
      <div v-for="dh in DAY_HEADERS" :key="dh" class="cal-grid-header">{{ dh }}</div>
      <div
        v-for="(cell, i) in calendarCells"
        :key="i"
        class="cal-cell"
        :class="{ 'cal-cell--empty': cell.empty, 'cal-cell--today': cell.isToday }"
        :data-date="cell.empty ? undefined : cell.dateStr"
        @click="!cell.empty && cell.dateStr && openModal(cell.dateStr)"
      >
        <template v-if="!cell.empty">
          <span class="cal-day-num">{{ cell.day }}</span>
          <div v-if="cell.events && cell.events.length" class="cal-dots">
            <span v-for="n in Math.min(cell.events.length, 3)" :key="n" class="cal-dot"></span>
            <span v-if="cell.events.length > 3" class="cal-dot-more">+{{ cell.events.length - 3 }}</span>
          </div>
          <div
            v-for="ev in (cell.events || []).slice(0, 2)"
            :key="ev.id"
            class="cal-cell-event"
            @click.stop="onEventClick(ev.id)"
          >
            {{ ev.title || "Untitled" }}
          </div>
        </template>
      </div>
    </div>

    <template v-else>
      <p v-if="upcomingDays.length === 0" class="cal-empty">No upcoming events.</p>
      <div v-for="group in upcomingDays" :key="group.date" class="cal-day">
        <div class="cal-day-header">{{ formatDateHeader(group.date) }}</div>
        <div
          v-for="e in group.events"
          :key="e.id"
          class="cal-event"
          @click.stop="onEventClick(e.id)"
        >
          <div class="cal-event-time">
            {{ e.data.dtstart ? formatTime(e.occurred_at || "") : "All day" }}
          </div>
          <div class="cal-event-body">
            <span class="cal-event-title">{{ e.title || "Untitled" }}</span>
            <span v-if="e.data.location" class="cal-event-loc">{{ e.data.location }}</span>
            <span v-if="e.data.calendar" class="cal-event-cal">{{ e.data.calendar }}</span>
          </div>
        </div>
      </div>
    </template>
  </div>

  <Teleport to="body">
    <div v-if="modalOpen" class="cal-modal-overlay" @click.self="closeModal">
      <div class="cal-modal">
        <div class="cal-modal-header">{{ modalEditId ? "Edit event" : "New event" }}</div>
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
            <label>Start date</label><input ref="startInput" type="date" />
          </div>
          <div class="cal-modal-field">
            <label>End date</label><input ref="endInput" type="date" />
          </div>
        </div>
        <div class="cal-modal-row">
          <div class="cal-modal-field">
            <label>Start time</label><input v-model="modalTime" type="time" />
          </div>
          <div class="cal-modal-field">
            <label>End time</label><input v-model="modalEndTime" type="time" />
          </div>
        </div>
        <div class="cal-modal-field">
          <label>Location</label><input v-model="modalLocation" type="text" placeholder="Optional" />
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
          <button class="cal-modal-btn cal-modal-btn--primary" :disabled="modalSaving" @click="saveEvent">
            {{ modalSaving ? "Saving..." : "Save" }}
          </button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.cal-loading {
  color: var(--text-muted);
  padding: 2rem;
}
.cal-container {
  padding: 0;
  height: calc(100vh - 4rem);
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
  border-radius: 6px;
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
  font-size: 1.15rem;
  font-weight: 600;
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
  border-radius: 4px;
  cursor: pointer;
  font-size: 0.85rem;
}
.cal-toggle-btn:hover {
  color: var(--text);
}
.cal-toggle-btn--active {
  background: var(--bg-hover);
  color: var(--text);
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
  font-size: 0.8rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
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
.cal-cell--today {
  background: rgba(108, 140, 255, 0.06);
}
.cal-cell--today .cal-day-num {
  color: var(--primary);
  font-weight: 700;
}
.cal-day-num {
  font-size: 0.85rem;
  color: var(--text-muted);
}
.cal-dots {
  display: flex;
  gap: 3px;
  margin-top: 2px;
}
.cal-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--primary);
}
.cal-dot-more {
  font-size: 0.65rem;
  color: var(--text-muted);
}
.cal-cell-event {
  font-size: 0.75rem;
  color: var(--text);
  margin-top: 2px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  background: rgba(108, 140, 255, 0.12);
  padding: 1px 4px;
  border-radius: 3px;
  cursor: pointer;
}
.cal-cell-event:hover {
  background: rgba(108, 140, 255, 0.25);
}
.cal-empty {
  color: var(--text-muted);
  padding: 2rem 0;
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
  width: 60px;
  flex-shrink: 0;
  font-size: 0.9rem;
  color: var(--text-muted);
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
.cal-event-cal {
  font-size: 0.8rem;
  color: var(--primary);
}
.cal-cell[data-date] {
  cursor: pointer;
}
.cal-cell[data-date]:hover {
  background: rgba(108, 140, 255, 0.04);
}
.cal-cell--today:hover {
  background: rgba(108, 140, 255, 0.1);
}
.cal-modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.6);
  z-index: 100;
  display: flex;
  align-items: center;
  justify-content: center;
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
  padding: 0.4rem 1rem;
  border-radius: 6px;
  cursor: pointer;
  font-size: 0.9rem;
}
.cal-modal-btn:hover {
  border-color: var(--text-muted);
}
.cal-modal-btn--primary {
  background: var(--primary);
  border-color: var(--primary);
  color: #fff;
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

<style>
/* Flatpickr dark theme (global — the picker renders on document.body). */
.flatpickr-calendar {
  background: var(--bg-surface) !important;
  border-color: var(--border) !important;
  box-shadow: 0 4px 20px rgba(0, 0, 0, 0.4) !important;
}
.flatpickr-months,
.flatpickr-weekdays {
  background: var(--bg-surface) !important;
}
.flatpickr-month,
.flatpickr-current-month .flatpickr-monthDropdown-months {
  background: var(--bg-surface) !important;
  color: var(--text) !important;
}
span.flatpickr-weekday {
  color: var(--text-muted) !important;
  background: var(--bg-surface) !important;
}
.flatpickr-day {
  color: var(--text) !important;
}
.flatpickr-day:hover {
  background: var(--bg-hover) !important;
  border-color: var(--bg-hover) !important;
}
.flatpickr-day.selected {
  background: var(--primary) !important;
  border-color: var(--primary) !important;
  color: #fff !important;
}
.flatpickr-day.today {
  border-color: var(--primary) !important;
}
.flatpickr-day.prevMonthDay,
.flatpickr-day.nextMonthDay {
  color: var(--text-muted) !important;
  opacity: 0.4;
}
.flatpickr-months .flatpickr-prev-month,
.flatpickr-months .flatpickr-next-month {
  fill: var(--text-muted) !important;
  color: var(--text-muted) !important;
}
.flatpickr-months .flatpickr-prev-month:hover,
.flatpickr-months .flatpickr-next-month:hover {
  fill: var(--text) !important;
  color: var(--text) !important;
}
.numInputWrapper span {
  border-color: var(--border) !important;
}
.numInputWrapper span:hover {
  background: var(--bg-hover) !important;
}
.numInputWrapper span svg path {
  fill: var(--text-muted) !important;
}
</style>
