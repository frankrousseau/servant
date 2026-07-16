# CalDAV / CardDAV endpoint

Servant exposes a minimal DAV server at `/dav` so a phone can sync the
Calendar app (CalDAV, RFC 4791 subset) and the Contacts app (CardDAV,
RFC 6352 subset) two ways, tested against the discovery and sync flows
used by iOS and DAVx5 on Android.

## Client setup

1. In Servant, go to Settings and create an API token with the
   `app:calendar:write` and/or `app:contacts:write` scopes (use the
   `:read` variants for a read-only subscription).
2. On the phone:
   - **Android (DAVx5)**: add account, "Login with URL and user name",
     base URL `https://<your-host>/dav`, any user name, and the `srv_`
     token as password. One account syncs both calendars and contacts.
   - **iOS**: Settings > Calendar (or Contacts) > Accounts > Add CalDAV
     (or CardDAV) account, server `<your-host>`, any user name, the
     `srv_` token as password (discovery goes through
     `/.well-known/caldav` and `/.well-known/carddav`).

A session token also works as the Basic password, but it expires after 30
days; API tokens are revocable from Settings and never expire, so prefer
them.

## What syncs

- **Calendars**: one CalDAV collection per calendar ("agenda"): the
  ever-present `Manual`, each calendar created in the app, and each
  agenda name your own events reference (agendas without an entity).
- **Contacts**: a single `contacts` address book.
- Only user-authored entries are exposed (source `manual`, `caldav` or
  `carddav`). Connector-synced events and contacts (iCal feeds, vCard
  imports) are excluded: they are re-fetched on a schedule and don't keep a
  phone's raw ICS/vCard payload, so editing them over DAV would drop that
  payload on the next sync. Subscribe to those feeds directly on the phone.
- Items created on the phone keep their raw ICS/vCard payload, so
  alarms, attendees, complex RRULEs, photos and structured names survive
  round-trips even though the apps only understand their simple fields.
  Editing an item in Servant regenerates the payload from those fields
  (and drops the extras).

## Protocol notes (implementation)

- `PROPFIND` ignores the requested property list and always returns the
  full supported set for the resource type; clients ignore extras.
- `calendar-query` / `addressbook-query` REPORTs return the whole
  collection (no server-side filtering); clients filter locally.
- No `sync-token` (RFC 6578); clients fall back to ctag + etag
  comparison, which is fine at personal scale.
- ETags derive from entry content, ctags from the collection's etags.
