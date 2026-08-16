# CalDAV / CardDAV / WebDAV endpoint

Servant exposes a minimal DAV server at `/dav` so a phone can sync the
Calendar app (CalDAV, RFC 4791 subset) and the Contacts app (CardDAV,
RFC 6352 subset) two ways, tested against the discovery and sync flows
used by iOS and DAVx5 on Android. The Files app is also reachable over
plain WebDAV at `/dav/files` (see below), which is the recommended way
to auto-upload a phone's camera roll.

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
  `carddav`). Feeds polled on a schedule (iCal URLs, vCard URLs) are
  excluded: the next sync would undo whatever the phone edited. Subscribe to
  those feeds directly on the phone.
- **Importing an address book**: a `.vcf` dropped on the vCard connector
  (Sources > Contacts (vCard) > Import) is a one-shot hand-off, not a feed,
  so its contacts land as `manual` ones and show up on the phone at the next
  sync. Each card is stored verbatim, so photos and structured names survive,
  and an inline (base64) photo is also decoded into a stored file so it becomes
  the contact's avatar in the app; editing such a contact in Servant
  regenerates its card from the app's fields and drops the extras the app
  doesn't model, same as for a contact created on the phone. This is the
  way to move an existing address book in, since neither iOS nor Android can
  move a contact from one account to another.
- Items created on the phone keep their raw ICS/vCard payload, so
  alarms, attendees, complex RRULEs, photos and structured names survive
  round-trips even though the apps only understand their simple fields.
  Editing an item in Servant regenerates the payload from those fields
  (and drops the extras).

## Files over WebDAV (`/dav/files`)

The Files app tree is served as a WebDAV class 1 subset: `PROPFIND`
(depth 0/1), `GET`, `PUT`, `MKCOL` and `DELETE` (recursive on folders).
Folders map to Files-app folders, names resolve on the file name, and
anything uploaded here appears in the Files app (source `webdav`) and
vice versa.

- Token scope: `app:files:read` / `app:files:write` (or the transversal
  `data:*`).
- Auto-upload apps (PhotoSync, FolderSync, rclone…) pointed at
  `https://<your-host>/dav/files/<folder>` with the `srv_` token as Basic
  password can back up a camera roll unattended. Re-uploading an existing
  name replaces the file rather than duplicating it.
- No locks (class 2), no `MOVE`/`COPY`: fine for sync apps; mounting as a
  network drive in Windows Explorer (which demands `LOCK`) is out of
  scope.

## Protocol notes (implementation)

- `PROPFIND` ignores the requested property list and always returns the
  full supported set for the resource type; clients ignore extras.
- `calendar-query` / `addressbook-query` REPORTs return the whole
  collection (no server-side filtering); clients filter locally.
- No `sync-token` (RFC 6578); clients fall back to ctag + etag
  comparison, which is fine at personal scale.
- ETags derive from entry content, ctags from the collection's etags.
