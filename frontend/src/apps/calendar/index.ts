import type { AppModule, Entry } from "../types";
import flatpickr from "flatpickr";
import "flatpickr/dist/flatpickr.min.css";
import { escapeHtml } from "../escapeHtml";

function formatTime(dt: string): string {
  return new Date(dt).toLocaleTimeString(undefined, {
    hour: "2-digit",
    minute: "2-digit",
  });
}

function formatDateHeader(iso: string): string {
  return new Date(iso + "T12:00:00").toLocaleDateString(undefined, {
    weekday: "short",
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function sameDay(a: Date, b: Date): boolean {
  return (
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
  );
}

const MONTH_NAMES = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

const DAY_HEADERS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

const calendarApp: AppModule = {
  mount(el, ctx) {
    let events: Entry[] = [];
    let viewMode: "calendar" | "list" = "calendar";
    let currentYear = new Date().getFullYear();
    let currentMonth = new Date().getMonth();

    function eventsForDate(date: Date): Entry[] {
      return events.filter((e) => {
        if (!e.occurred_at) return false;
        const start = new Date(e.occurred_at);
        const endStr = (e.data.end_at as string) || (e.data.dtend as string);
        if (endStr) {
          const end = new Date(endStr);
          // Event spans from start date to end date (inclusive of start day, exclusive or inclusive of end day)
          const dayStart = new Date(date.getFullYear(), date.getMonth(), date.getDate());
          const dayEnd = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 59);
          return start <= dayEnd && end >= dayStart;
        }
        return sameDay(start, date);
      });
    }

    function groupByDate(): Record<string, Entry[]> {
      const grouped: Record<string, Entry[]> = {};
      for (const e of events) {
        const key = e.occurred_at
          ? new Date(e.occurred_at).toISOString().slice(0, 10)
          : "unknown";
        (grouped[key] ||= []).push(e);
      }
      return grouped;
    }

    function prevMonth(): void {
      currentMonth--;
      if (currentMonth < 0) {
        currentMonth = 11;
        currentYear--;
      }
      render();
    }

    function nextMonth(): void {
      currentMonth++;
      if (currentMonth > 11) {
        currentMonth = 0;
        currentYear++;
      }
      render();
    }

    function goToday(): void {
      currentYear = new Date().getFullYear();
      currentMonth = new Date().getMonth();
      render();
    }

    // --- Renderers (use string concat to avoid OXC template parsing issues) ---

    function renderCalendarView(): string {
      const firstDay = new Date(currentYear, currentMonth, 1);
      // Monday = 0, Sunday = 6
      let startDow = firstDay.getDay() - 1;
      if (startDow < 0) startDow = 6;
      const daysInMonth = new Date(currentYear, currentMonth + 1, 0).getDate();
      const today = new Date();

      let gridHtml = "";
      // Empty cells before first day
      for (let i = 0; i < startDow; i++) {
        gridHtml += '<div class="cal-cell cal-cell--empty"></div>';
      }
      // Day cells
      for (let day = 1; day <= daysInMonth; day++) {
        const date = new Date(currentYear, currentMonth, day);
        const dayEvents = eventsForDate(date);
        const isToday = sameDay(date, today);
        const cellClass = "cal-cell" + (isToday ? " cal-cell--today" : "");

        let dotsHtml = "";
        if (dayEvents.length > 0) {
          const count = Math.min(dayEvents.length, 3);
          let dots = "";
          for (let j = 0; j < count; j++) dots += '<span class="cal-dot"></span>';
          if (dayEvents.length > 3) dots += '<span class="cal-dot-more">+' + (dayEvents.length - 3) + "</span>";
          dotsHtml = '<div class="cal-dots">' + dots + "</div>";
        }

        let eventsPreview = "";
        for (const ev of dayEvents.slice(0, 2)) {
          eventsPreview += '<div class="cal-cell-event" data-event-id="' + ev.id + '">' + escapeHtml(ev.title || "Untitled") + "</div>";
        }

        gridHtml +=
          '<div class="' + cellClass + '" data-date="' + date.toISOString().slice(0, 10) + '">'
          + '<span class="cal-day-num">' + day + "</span>"
          + dotsHtml
          + eventsPreview
          + "</div>";
      }

      const headerHtml =
        '<div class="cal-header">'
        + '<div class="cal-nav">'
        + '<button class="cal-nav-btn" id="cal-prev">&lsaquo;</button>'
        + '<button class="cal-nav-btn cal-today-btn" id="cal-today">Today</button>'
        + '<button class="cal-nav-btn" id="cal-next">&rsaquo;</button>'
        + "</div>"
        + '<span class="cal-month-label">' + MONTH_NAMES[currentMonth] + " " + currentYear + "</span>"
        + '<div class="cal-header-actions">'
        + '<button class="cal-nav-btn" id="cal-export" title="Export as .ics">Export</button>'
        + '<div class="cal-view-toggle">'
        + '<button class="cal-toggle-btn cal-toggle-btn--active" id="cal-view-cal">Grid</button>'
        + '<button class="cal-toggle-btn" id="cal-view-list">List</button>'
        + "</div></div>"
        + "</div>";

      let dayHeadersHtml = "";
      for (const dh of DAY_HEADERS) {
        dayHeadersHtml += '<div class="cal-grid-header">' + dh + "</div>";
      }

      return headerHtml
        + '<div class="cal-grid">'
        + dayHeadersHtml
        + gridHtml
        + "</div>";
    }

    function renderListView(): string {
      const today = new Date().toISOString().slice(0, 10);
      const grouped = groupByDate();
      const sortedDates = Object.keys(grouped).filter((d) => d >= today).sort();

      const headerHtml =
        '<div class="cal-header">'
        + '<span class="cal-month-label">Upcoming</span>'
        + '<div class="cal-header-actions">'
        + '<button class="cal-nav-btn" id="cal-export" title="Export as .ics">Export</button>'
        + '<div class="cal-view-toggle">'
        + '<button class="cal-toggle-btn" id="cal-view-cal">Grid</button>'
        + '<button class="cal-toggle-btn cal-toggle-btn--active" id="cal-view-list">List</button>'
        + "</div></div>"
        + "</div>";

      if (sortedDates.length === 0) {
        return headerHtml + '<p class="cal-empty">No upcoming events.</p>';
      }

      let daysHtml = "";
      for (const date of sortedDates) {
        let eventsHtml = "";
        for (const e of grouped[date]) {
          const timeStr = e.data.dtstart ? escapeHtml(formatTime(e.occurred_at || "")) : "All day";
          let bodyHtml = '<span class="cal-event-title">' + escapeHtml(e.title || "Untitled") + "</span>";
          if (e.data.location) bodyHtml += '<span class="cal-event-loc">' + escapeHtml(e.data.location as string) + "</span>";
          if (e.data.calendar) bodyHtml += '<span class="cal-event-cal">' + escapeHtml(e.data.calendar as string) + "</span>";
          eventsHtml +=
            '<div class="cal-event" data-event-id="' + e.id + '">'
            + '<div class="cal-event-time">' + timeStr + "</div>"
            + '<div class="cal-event-body">' + bodyHtml + "</div>"
            + "</div>";
        }
        daysHtml +=
          '<div class="cal-day">'
          + '<div class="cal-day-header">' + escapeHtml(formatDateHeader(date)) + "</div>"
          + eventsHtml
          + "</div>";
      }

      return headerHtml + daysHtml;
    }

    // --- Event modal (create + edit) ---

    let modalOpen = false;
    let modalEditId: string | null = null; // null = create, string = edit
    let modalDate: string | null = null;
    let modalEndDate: string = "";
    let modalTitle = "";
    let modalTime = "";
    let modalEndTime = "";
    let modalLocation = "";
    let modalSaving = false;

    function renderModal(): string {
      if (!modalOpen || !modalDate) return "";
      const isEdit = !!modalEditId;
      const headerText = isEdit ? "Edit event" : "New event";
      const savingAttr = modalSaving ? " disabled" : "";
      const deleteBtn = isEdit
        ? '<button class="cal-modal-btn cal-modal-btn--danger" id="cal-modal-delete">Delete</button>'
        : "";
      return '<div class="cal-modal-overlay" id="cal-modal-overlay">'
        + '<div class="cal-modal">'
        + '<div class="cal-modal-header">' + headerText + '</div>'
        + '<div class="cal-modal-field"><label>Title</label><input id="cal-modal-title" type="text" placeholder="Event title" value="' + escapeHtml(modalTitle) + '" /></div>'
        + '<div class="cal-modal-row">'
        + '<div class="cal-modal-field"><label>Start date</label><input id="cal-modal-date" type="date" value="' + escapeHtml(modalDate || "") + '" /></div>'
        + '<div class="cal-modal-field"><label>End date</label><input id="cal-modal-enddate" type="date" value="' + escapeHtml(modalEndDate) + '" /></div>'
        + '</div>'
        + '<div class="cal-modal-row">'
        + '<div class="cal-modal-field"><label>Start time</label><input id="cal-modal-time" type="time" value="' + escapeHtml(modalTime) + '" /></div>'
        + '<div class="cal-modal-field"><label>End time</label><input id="cal-modal-endtime" type="time" value="' + escapeHtml(modalEndTime) + '" /></div>'
        + '</div>'
        + '<div class="cal-modal-field"><label>Location</label><input id="cal-modal-location" type="text" placeholder="Optional" value="' + escapeHtml(modalLocation) + '" /></div>'
        + '<div class="cal-modal-actions">'
        + deleteBtn
        + '<span class="cal-modal-spacer"></span>'
        + '<button class="cal-modal-btn" id="cal-modal-cancel">Cancel</button>'
        + '<button class="cal-modal-btn cal-modal-btn--primary" id="cal-modal-save"' + savingAttr + '>' + (modalSaving ? "Saving..." : "Save") + '</button>'
        + '</div></div></div>';
    }

    function openModal(dateStr: string): void {
      modalOpen = true;
      modalEditId = null;
      modalDate = dateStr;
      modalEndDate = dateStr;
      modalTitle = "";
      modalTime = "09:00";
      modalEndTime = "10:00";
      modalLocation = "";
      modalSaving = false;
      render();
      (el.querySelector("#cal-modal-title") as HTMLInputElement)?.focus();
    }

    function openEditModal(entry: Entry): void {
      modalOpen = true;
      modalEditId = entry.id;
      const startDt = entry.occurred_at ? new Date(entry.occurred_at) : new Date();
      modalDate = formatISODate(startDt);
      modalTime = String(startDt.getHours()).padStart(2, "0") + ":" + String(startDt.getMinutes()).padStart(2, "0");

      const endStr = (entry.data.end_at as string) || (entry.data.dtend as string);
      if (endStr) {
        const endDt = new Date(endStr);
        modalEndDate = formatISODate(endDt);
        modalEndTime = String(endDt.getHours()).padStart(2, "0") + ":" + String(endDt.getMinutes()).padStart(2, "0");
      } else {
        modalEndDate = modalDate;
        modalEndTime = "";
      }

      modalTitle = entry.title || (entry.data.summary as string) || "";
      modalLocation = (entry.data.location as string) || "";
      modalSaving = false;
      render();
      (el.querySelector("#cal-modal-title") as HTMLInputElement)?.focus();
    }

    function closeModal(): void {
      fpStart?.destroy();
      fpEnd?.destroy();
      fpStart = null;
      fpEnd = null;
      modalOpen = false;
      modalEditId = null;
      modalDate = null;
      render();
    }

    async function saveEvent(): Promise<void> {
      if (!modalDate || !modalTitle.trim()) return;
      modalSaving = true;
      render();

      const dtstart = modalDate.replace(/-/g, "") + "T" + modalTime.replace(":", "") + "00";
      const endDateStr = modalEndDate || modalDate;
      const dtend = endDateStr.replace(/-/g, "") + "T" + (modalEndTime || "23:59").replace(":", "") + "00";
      const occurredAt = modalDate + "T" + modalTime + ":00Z";
      const endAt = endDateStr + "T" + (modalEndTime || "23:59") + ":00Z";

      const attrs = {
        kind: "event",
        source: modalEditId ? undefined : "manual",
        title: modalTitle.trim(),
        occurred_at: occurredAt,
        data: {
          summary: modalTitle.trim(),
          dtstart: dtstart,
          dtend: dtend,
          end_at: endAt,
          location: modalLocation.trim() || null,
          calendar: modalEditId
            ? events.find((e) => e.id === modalEditId)?.data.calendar || "Manual"
            : "Manual",
        },
      };

      try {
        if (modalEditId) {
          await ctx.api.entries.update(modalEditId, attrs);
        } else {
          await ctx.api.entries.create(attrs);
        }
        events = await ctx.api.entries.list({ kind: "event" });
        closeModal();
      } catch {
        modalSaving = false;
        render();
      }
    }

    async function deleteEvent(): Promise<void> {
      if (!modalEditId) return;
      const confirmed = await ctx.confirm.ask({
        message: "Delete this event?",
        danger: true,
      });
      if (!confirmed) return;
      try {
        await ctx.api.entries.delete(modalEditId);
        events = await ctx.api.entries.list({ kind: "event" });
        closeModal();
      } catch {
        // ignore
      }
    }

    let fpStart: flatpickr.Instance | null = null;
    let fpEnd: flatpickr.Instance | null = null;

    function bindModalEvents(): void {
      el.querySelector("#cal-modal-overlay")?.addEventListener("click", (e) => {
        if ((e.target as HTMLElement).id === "cal-modal-overlay") closeModal();
      });
      el.querySelector("#cal-modal-cancel")?.addEventListener("click", closeModal);
      el.querySelector("#cal-modal-delete")?.addEventListener("click", deleteEvent);
      el.querySelector("#cal-modal-save")?.addEventListener("click", saveEvent);
      el.querySelector("#cal-modal-title")?.addEventListener("input", (e) => {
        modalTitle = (e.target as HTMLInputElement).value;
      });
      el.querySelector("#cal-modal-time")?.addEventListener("input", (e) => {
        modalTime = (e.target as HTMLInputElement).value;
      });
      el.querySelector("#cal-modal-endtime")?.addEventListener("input", (e) => {
        modalEndTime = (e.target as HTMLInputElement).value;
      });
      el.querySelector("#cal-modal-location")?.addEventListener("input", (e) => {
        modalLocation = (e.target as HTMLInputElement).value;
      });
      el.querySelector("#cal-modal-title")?.addEventListener("keydown", (e) => {
        if ((e as KeyboardEvent).key === "Enter") saveEvent();
      });

      // Flatpickr date pickers
      if (el.querySelector("#cal-modal-date")) {
        fpStart = flatpickr("#cal-modal-date", {
          dateFormat: "Y-m-d",
          defaultDate: modalDate || undefined,
          onChange: ([date]) => {
            modalDate = formatISODate(date);
            if (modalEndDate < modalDate) {
              modalEndDate = modalDate;
              fpEnd?.setDate(modalDate);
            }
          },
        }) as flatpickr.Instance;
      }

      if (el.querySelector("#cal-modal-enddate")) {
        fpEnd = flatpickr("#cal-modal-enddate", {
          dateFormat: "Y-m-d",
          defaultDate: modalEndDate || undefined,
          onChange: ([date]) => {
            modalEndDate = formatISODate(date);
          },
        }) as flatpickr.Instance;
      }
    }

    function formatISODate(date: Date): string {
      const y = date.getFullYear();
      const m = String(date.getMonth() + 1).padStart(2, "0");
      const d = String(date.getDate()).padStart(2, "0");
      return y + "-" + m + "-" + d;
    }

    // --- Main render ---

    function render(): void {
      const content = viewMode === "calendar" ? renderCalendarView() : renderListView();
      el.innerHTML = '<div class="cal-container">' + content + "</div>" + renderModal();

      // Bind nav events
      el.querySelector("#cal-prev")?.addEventListener("click", prevMonth);
      el.querySelector("#cal-next")?.addEventListener("click", nextMonth);
      el.querySelector("#cal-today")?.addEventListener("click", goToday);

      el.querySelector("#cal-export")?.addEventListener("click", async () => {
        const res = await ctx.api.fetch("/api/export/entries.ics");
        const blob = await res.blob();
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "calendar.ics";
        a.click();
        URL.revokeObjectURL(url);
      });

      el.querySelector("#cal-view-cal")?.addEventListener("click", () => {
        viewMode = "calendar";
        render();
      });
      el.querySelector("#cal-view-list")?.addEventListener("click", () => {
        viewMode = "list";
        render();
      });

      // Event clicks → open edit modal (both grid and list)
      el.querySelectorAll("[data-event-id]").forEach((elem) => {
        elem.addEventListener("click", (e) => {
          e.stopPropagation();
          const eventId = (elem as HTMLElement).dataset.eventId;
          const entry = events.find((ev) => ev.id === eventId);
          if (entry) openEditModal(entry);
        });
      });

      // Cell clicks → open create modal (grid view)
      el.querySelectorAll(".cal-cell[data-date]").forEach((cell) => {
        cell.addEventListener("click", () => {
          const dateStr = (cell as HTMLElement).dataset.date;
          if (dateStr) openModal(dateStr);
        });
      });

      // Modal events
      bindModalEvents();
    }

    // Styles
    const style = document.createElement("style");
    style.dataset.app = "calendar";
    style.textContent = [
      ".cal-container { padding: 0; height: calc(100vh - 4rem); display: flex; flex-direction: column; }",
      ".cal-header { display: flex; align-items: center; gap: 1rem; margin-bottom: 1rem; }",
      ".cal-nav { display: flex; gap: 0.25rem; }",
      ".cal-nav-btn { background: transparent; border: 1px solid var(--border); color: var(--text-muted); padding: 0.3rem 0.6rem; border-radius: 6px; cursor: pointer; font-size: 1rem; }",
      ".cal-nav-btn:hover { color: var(--text); border-color: var(--text-muted); }",
      ".cal-today-btn { font-size: 0.85rem; }",
      ".cal-month-label { font-size: 1.15rem; font-weight: 600; flex: 1; }",
      ".cal-header-actions { display: flex; align-items: center; gap: 0.5rem; }",
      ".cal-view-toggle { display: flex; gap: 0.2rem; background: var(--bg-surface); border: 1px solid var(--border); border-radius: 6px; padding: 2px; }",
      ".cal-toggle-btn { background: transparent; border: none; color: var(--text-muted); padding: 0.3rem 0.7rem; border-radius: 4px; cursor: pointer; font-size: 0.85rem; }",
      ".cal-toggle-btn:hover { color: var(--text); }",
      ".cal-toggle-btn--active { background: var(--bg-hover); color: var(--text); }",
      // Grid
      ".cal-grid { display: grid; grid-template-columns: repeat(7, 1fr); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; flex: 1; grid-template-rows: auto repeat(6, 1fr); }",
      ".cal-grid-header { padding: 0.5rem; text-align: center; font-size: 0.8rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.04em; background: var(--bg-surface); border-bottom: 1px solid var(--border); }",
      ".cal-cell { padding: 0.35rem; border-bottom: 1px solid var(--border); border-right: 1px solid var(--border); cursor: default; position: relative; overflow: hidden; }",
      ".cal-cell:nth-child(7n+14) { border-right: none; }",
      ".cal-cell--empty { background: var(--bg-surface); }",
      ".cal-cell--today { background: rgba(108, 140, 255, 0.06); }",
      ".cal-cell--today .cal-day-num { color: var(--primary); font-weight: 700; }",
      ".cal-day-num { font-size: 0.85rem; color: var(--text-muted); }",
      ".cal-dots { display: flex; gap: 3px; margin-top: 2px; }",
      ".cal-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--primary); }",
      ".cal-dot-more { font-size: 0.65rem; color: var(--text-muted); }",
      ".cal-cell-event { font-size: 0.75rem; color: var(--text); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; background: rgba(108, 140, 255, 0.12); padding: 1px 4px; border-radius: 3px; cursor: pointer; }",
      ".cal-cell-event:hover { background: rgba(108, 140, 255, 0.25); }",
      // List
      ".cal-empty { color: var(--text-muted); padding: 2rem 0; }",
      ".cal-day { margin-bottom: 1.5rem; }",
      ".cal-day-header { font-weight: 600; font-size: 0.9rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.04em; padding-bottom: 0.5rem; border-bottom: 1px solid var(--border); margin-bottom: 0.5rem; }",
      ".cal-event { display: flex; gap: 1rem; padding: 0.5rem 0; cursor: pointer; border-radius: 6px; }",
      ".cal-event:hover { background: var(--bg-hover); }",
      ".cal-event-time { width: 60px; flex-shrink: 0; font-size: 0.9rem; color: var(--text-muted); }",
      ".cal-event-body { display: flex; flex-direction: column; gap: 0.15rem; }",
      ".cal-event-title { font-weight: 500; }",
      ".cal-event-loc { font-size: 0.9rem; color: var(--text-muted); }",
      ".cal-event-cal { font-size: 0.8rem; color: var(--primary); }",
      ".cal-cell[data-date] { cursor: pointer; }",
      ".cal-cell[data-date]:hover { background: rgba(108, 140, 255, 0.04); }",
      ".cal-cell--today:hover { background: rgba(108, 140, 255, 0.1); }",
      // Modal
      ".cal-modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.6); z-index: 100; display: flex; align-items: center; justify-content: center; }",
      ".cal-modal { background: var(--bg-surface); border: 1px solid var(--border); border-radius: 8px; padding: 1.25rem; width: 100%; max-width: 400px; }",
      ".cal-modal-header { font-weight: 600; font-size: 1.05rem; margin-bottom: 1rem; }",
      ".cal-modal-field { display: flex; flex-direction: column; gap: 0.2rem; margin-bottom: 0.75rem; }",
      ".cal-modal-field label { font-size: 0.85rem; color: var(--text-muted); }",
      ".cal-modal-row { display: flex; gap: 0.75rem; }",
      ".cal-modal-row .cal-modal-field { flex: 1; }",
      ".cal-modal-actions { display: flex; justify-content: flex-end; gap: 0.5rem; margin-top: 0.5rem; }",
      ".cal-modal-btn { background: transparent; border: 1px solid var(--border); color: var(--text); padding: 0.4rem 1rem; border-radius: 6px; cursor: pointer; font-size: 0.9rem; }",
      ".cal-modal-btn:hover { border-color: var(--text-muted); }",
      ".cal-modal-btn--primary { background: var(--primary); border-color: var(--primary); color: #fff; }",
      ".cal-modal-btn--primary:hover { background: var(--primary-hover); }",
      ".cal-modal-btn--danger { color: var(--danger); border-color: var(--danger); }",
      ".cal-modal-btn--danger:hover { background: rgba(240, 108, 108, 0.1); }",
      ".cal-modal-spacer { flex: 1; }",
      // Flatpickr dark theme overrides
      ".flatpickr-calendar { background: var(--bg-surface) !important; border-color: var(--border) !important; box-shadow: 0 4px 20px rgba(0,0,0,0.4) !important; }",
      ".flatpickr-months, .flatpickr-weekdays { background: var(--bg-surface) !important; }",
      ".flatpickr-month, .flatpickr-current-month .flatpickr-monthDropdown-months { background: var(--bg-surface) !important; color: var(--text) !important; }",
      "span.flatpickr-weekday { color: var(--text-muted) !important; background: var(--bg-surface) !important; }",
      ".flatpickr-day { color: var(--text) !important; }",
      ".flatpickr-day:hover { background: var(--bg-hover) !important; border-color: var(--bg-hover) !important; }",
      ".flatpickr-day.selected { background: var(--primary) !important; border-color: var(--primary) !important; color: #fff !important; }",
      ".flatpickr-day.today { border-color: var(--primary) !important; }",
      ".flatpickr-day.prevMonthDay, .flatpickr-day.nextMonthDay { color: var(--text-muted) !important; opacity: 0.4; }",
      ".flatpickr-months .flatpickr-prev-month, .flatpickr-months .flatpickr-next-month { fill: var(--text-muted) !important; color: var(--text-muted) !important; }",
      ".flatpickr-months .flatpickr-prev-month:hover, .flatpickr-months .flatpickr-next-month:hover { fill: var(--text) !important; color: var(--text) !important; }",
      ".numInputWrapper span { border-color: var(--border) !important; }",
      ".numInputWrapper span:hover { background: var(--bg-hover) !important; }",
      ".numInputWrapper span svg path { fill: var(--text-muted) !important; }",
      ".cal-modal-btn:disabled { opacity: 0.6; cursor: not-allowed; }",
    ].join("\n");
    document.head.appendChild(style);

    // Load data
    ctx.api.entries.list({ kind: "event" }).then((entries) => {
      events = entries;
      render();
    });

    el.innerHTML = '<p style="color: var(--text-muted); padding: 2rem;">Loading events...</p>';
  },

  unmount(el) {
    el.innerHTML = "";
    document.querySelector('style[data-app="calendar"]')?.remove();
  },
};

export default calendarApp;
