# CalDAV endpoint

Servant exposes a minimal CalDAV server at `/dav` so a phone can sync the
Calendar app two ways (RFC 4791 subset, tested against the discovery and
sync flows used by iOS Calendar and DAVx5 on Android).

## Client setup

1. In Servant, go to Settings and create an API token with the
   `app:calendar:write` scope (use `app:calendar:read` for a read-only
   subscription).
2. On the phone:
   - **Android (DAVx5)**: add account, "Login with URL and user name",
     base URL `https://<your-host>/dav`, any user name, and the `srv_`
     token as password.
   - **iOS**: Settings > Calendar > Accounts > Add CalDAV account, server
     `<your-host>`, any user name, the `srv_` token as password
     (discovery goes through `/.well-known/caldav`).

A session token also works as the Basic password, but it expires after 30
days; API tokens are revocable from Settings and never expire, so prefer
them.

## What syncs

- One CalDAV collection per calendar ("agenda"): the ever-present
  `Manual` plus each calendar created in the app.
- Only user-authored events (source `manual` or `caldav`) are exposed.
  Connector-synced events (iCal feeds, ...) are wholesale-replaced on
  every sync, so phone edits to them would be lost; subscribe to those
  feeds directly on the phone instead.
- Events created on the phone keep their raw ICS payload, so alarms,
  attendees and complex RRULEs survive round-trips even though the app
  only understands its simple fields (bare weekly/monthly/yearly
  recurrence, location, description).

## Protocol notes (implementation)

- `PROPFIND` ignores the requested property list and always returns the
  full supported set for the resource type; clients ignore extras.
- `calendar-query` REPORTs return the whole collection (no server-side
  time-range filtering); clients filter locally.
- No `sync-token` (RFC 6578); clients fall back to ctag + etag
  comparison, which is fine at personal scale.
- ETags derive from entry content, ctags from the collection's etags.
