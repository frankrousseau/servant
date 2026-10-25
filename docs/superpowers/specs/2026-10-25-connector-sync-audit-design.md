# Connector sync audit

Make a connector sync explainable after the fact. Today a run leaves one `sync_logs`
row: a status, the number of entries inserted, a one-line error, start and end. A
failure says neither which step nor which request broke, and a crash loses its
stacktrace; a success does not say what it fetched, what was new or what was already
known. Logs are never pruned: a continuous source writes thousands of rows a day.

Two needs, in this order: understand a failure, see what a success brought. The
health overview across sources and alerts stay out of scope.

## Approach

Automatic capture in the worker, no connector touched. `Servant.Connectors.Worker`
runs every sync in its own process, so a trace held in that process's dictionary
for the duration of a run collects everything the sync does:

- HTTP calls, from Finch telemetry (Req 0.7 runs on `Finch.stream_while`; the
  handlers run in the calling process)
- log lines, from a `:logger` handler (handlers also run in the calling process)
- counts, new entries and the crash stacktrace, from the worker itself

A connector that wants to report a step ("page 3 of 7", "cursor 123 to 456") calls
`Logger.info`; there is no tracing API to learn. Work a connector hands to a separate
`Task` is not captured (today only `invoice_scraper_connector.ex`).

## Capture: `Servant.Connectors.SyncTrace`

| function | role |
|----------|------|
| `start/0` | opens a trace in the process dictionary |
| `finish/0` | closes it, returns the collected map |
| `active?/0` | whether the current process holds a trace |
| `attach/0` | attaches the telemetry handlers; called from `Servant.Application` |

Outside an open trace both handlers do nothing.

**HTTP.** `[:finch, :recv, :stop]` carries the response status (stored as the
status of the request in flight); `[:finch, :request, :stop]` carries the request
and the total duration, and closes the call:

| key | value |
|-----|-------|
| `method` | `GET`, `POST`, ... |
| `host` | request host |
| `path` | request path, **query string dropped** (it can hold an API key) |
| `status` | HTTP status, `null` when unknown (HTTP/2 without a recv event) |
| `ms` | duration in milliseconds |
| `error` | network error message, when the request failed |

No headers, no bodies. Req retries show up as separate calls.

**Logs.** A `:logger` handler (`:servant_sync_trace`, modelled on
`Servant.Audit.ErrorLogHandler`) appends `%{at, level, message}` for every event the
tracing process emits, message cut at 2000 characters.

**Caps.** 100 HTTP calls and 200 log lines per run; past that, `http_omitted` and
`logs_omitted` count what was dropped.

**Safety.** Both handlers wrap their body in `catch`; a failure there never reaches
the sync. The worker closes the trace in an `after`, so a crashed run leaves nothing
behind for the next one.

## Worker

Around each run: `SyncTrace.start/0`, the sync, then `SyncTrace.finish/0`. The worker
computes:

- `fetched_count`: entries returned by `sync/1`
- `entries_count` (unchanged meaning): entries actually inserted, the new ones.
  Already known = fetched minus new
- `kinds`: fetched entries counted by kind
- `new_entries`: `id`, `kind`, `title` of up to 20 inserted entries.
  `Data.create_entries/3` gains a `returning: true` option that adds
  `RETURNING id, kind, title` to the insert; with `ON CONFLICT DO NOTHING` the
  conflicting rows are not returned, so the result is exactly the new entries
- `stacktrace`: `Exception.format/3` output when the run raises

File imports (`Connectors.import_file`) also write sync logs: they fill the same
counts (`fetched_count` = total rows, `entries_count` = imported).

## Storage

Migration on `sync_logs`:

| column | type | |
|--------|------|-|
| `fetched_count` | integer, default 0 | backfilled from `entries_count` for the existing rows |
| `http_count` | integer, default 0 | calls made, omitted ones included |
| `http_failed_count` | integer, default 0 | status >= 400 or network error |
| `log_count` | integer, default 0 | lines logged, omitted ones included |
| `details` | map (JSON), nullable | `kinds`, `new_entries`, `http`, `http_omitted`, `logs`, `logs_omitted`, `stacktrace` |

The counts are columns rather than read from `details`: the history list then
never loads the bulky JSON, and a run keeps its summary ("2 of 37 calls failed")
after its details are pruned.

If writing `details` fails, the run still records its status and counts.

**Retention**, applied each time a run opens (`create_sync_log/1`, which covers
the syncs and the imports), per source: keep the 500 most recent runs; keep
`details` only on the 50 most recent.

## API

`GET /api/connectors/:id/logs` (exists) stays a light list. Each run gains:
`fetched_count`, `known_count`, `http_count`, `http_failed_count` (status >= 400 or
network error), `log_count`, `has_details`.

`GET /api/connectors/:id/logs/:log_id` (new) returns the run with its full
`details`. 404 when the source is not the user's or the run is not the source's.

Same pipeline and scopes as the existing route; OpenApiSpex schemas for both.

## Frontend

`ConnectorDetailView.vue`, Sync History section.

**Row summary:** status, then "12 new · 140 already known" (or "Nothing new · 140
already known"), a "2 of 37 calls failed" badge when calls failed, duration,
relative time.

**Disclosure:** each finished row is a button with `aria-expanded`; the first
opening fetches the details, then they are cached per run. Only non-empty sections
render, in this order:

1. **Error**: message, collapsible stacktrace in a mono block, the existing copy
   button
2. **New entries**: kind icon, title, link through `lib/entryRoute.ts`
   (`entryRoute` widened to `Pick<Entry, 'id' | 'kind'>`), "+ N more" past 20
3. **By kind**: counts named with `kindLabel` ("Bank transactions 140")
4. **HTTP calls**: table of status, method, host and path, duration, in call
   order; failed calls in `--danger`
5. **Log**: mono lines, time, level, message; warnings and errors colored

A run without details (past the 50 most recent, or older than this feature) opens
on "Details are kept for the 50 most recent runs." A running sync does not expand.

## Testing

- `SyncTrace`: telemetry events and log lines emitted inside a trace are captured,
  none outside; caps and omitted counters; the query string never reaches the trace
  (events emitted with `:telemetry.execute/3`, as `Req.Test` bypasses Finch)
- Worker, with a fake connector: a success records fetched, new and known counts,
  kinds, new entries and the logs it emitted; a raise records the stacktrace;
  retention keeps 500 runs and details on 50
- `Data.create_entries/3` with `returning: true` returns only the inserted rows
- Controller: the detail endpoint returns the run; another source's or another
  user's run is a 404; the list carries the new fields
- Frontend: a row expands and loads its details once; empty sections stay hidden

## Out of scope

- Health overview across sources (failure streaks, success rate, mean duration)
- Alerts on repeated failures
- HTTP response bodies (reaching them means reading Req internals)
- Work a connector runs in a separate `Task`
