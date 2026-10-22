# CalDAV / CardDAV / WebDAV endpoint

Servant has a minimal DAV server at `/dav`, tested with iOS and DAVx5 (Android):

- `/dav`: two-way sync of the Calendar app (CalDAV, subset of RFC 4791) and the Contacts app
  (CardDAV, subset of RFC 6352);
- `/dav/files`: the Files app over plain WebDAV;
- `/dav/photos`: the Photos app over plain WebDAV, for camera-roll upload.

## Client setup

1. In Servant, open Settings and make an API token with the `app:calendar:write` scope, the
   `app:contacts:write` scope, or both. For a read-only sync, use the `:read` scopes.
2. On the phone:
   - **Android (DAVx5)**: add an account with "Login with URL and user name". Base URL:
     `https://<your-host>/dav`. User name: any value. Password: the `srv_` token. One
     account syncs the calendars and the contacts.
   - **iOS**: Settings > Calendar (or Contacts) > Accounts > Add CalDAV (or CardDAV) account.
     Server: `<your-host>`. User name: any value. Password: the `srv_` token. Discovery uses
     `/.well-known/caldav` and `/.well-known/carddav`.

A session token also works as the Basic password, but it expires after 30 days. Use an API
token: it does not expire, and you can revoke it in Settings.

## What syncs

- **Calendars**: one CalDAV collection for each calendar ("agenda"). This includes the
  `Manual` calendar, each calendar made in the app, and each agenda name that your events use.
- **Contacts**: one `contacts` address book.
- Servant shows only the entries that a user writes (source `manual`, `caldav` or `carddav`).
  It does not show feeds that a connector polls (iCal URLs, vCard URLs): the next poll would
  delete the phone edits. Subscribe to these feeds directly on the phone.
- **Address book import**: a `.vcf` file that you drop on the vCard connector (Sources >
  Contacts (vCard) > Import) is a one-time import, not a feed. Its contacts become `manual`
  contacts, and the phone gets them at the next sync.
  - Servant keeps each card as it is, so photos and structured names stay.
  - Servant also decodes an inline (base64) photo into a file, and the app uses it as the
    contact avatar.
  - If you edit the contact in Servant, Servant makes the card again from the app fields. The
    data that the app does not know is lost, as for a contact made on the phone.

  Use this import to move an existing address book into Servant: iOS and Android cannot move
  a contact from one account to a different account.
- Items made on the phone keep their raw ICS or vCard data. Thus alarms, attendees, complex
  RRULEs, photos and structured names stay after a sync, also if the apps show only the
  simple fields. If you edit the item in Servant, Servant makes the data again from these
  fields, and the extra data is lost.
- **Duplicate merge** (Contacts > Duplicates): if the kept contact has no phone resource name
  and UID, it gets them from the merged contact. Thus the phone sees an updated contact, not a
  deleted one. If the phone sends a card with the UID of an existing contact (an imported card
  keeps its UID), Servant updates that contact and does not make a second one.

## Files over WebDAV (`/dav/files`)

Servant serves the Files app tree as a subset of WebDAV class 1: `PROPFIND` (depth 0 and 1),
`GET`, `PUT`, `MKCOL` and `DELETE` (recursive on folders). The folders are Files app folders,
and the names are the file names. A file uploaded here shows in the Files app (source
`webdav`), and the opposite is also true.

- Token scope: `app:files:read` or `app:files:write` (or `data:*`).
- If you upload a file with an existing name, Servant replaces the file. It does not make a
  duplicate.
- There are no locks (class 2) and no `MOVE` or `COPY`. Sync apps do not need them. Windows
  Explorer needs `LOCK`, so you cannot use `/dav/files` as a Windows network drive.

## Photos over WebDAV (`/dav/photos`)

Servant serves the Photos app with the same class 1 subset. The folders are albums. For each
`PUT`, the server:

1. stores the image,
2. reads the EXIF data (date taken, GPS, camera),
3. makes the thumbnails,
4. makes a usual `photo` entry (source `webdav`).

The photo then shows in the Photos app, with the timeline, albums and face tagging. For the setup of
auto-upload apps (PhotoSync, FolderSync, rclone…), see [phone-backup.md](phone-backup.md).

- Token scope: `app:photos:read` or `app:photos:write` (or `data:*`).
- The first folder level is the album: `/dav/photos/Camera/IMG.jpg` goes into the album
  `Camera`. Deeper folders give album names with slashes (`Camera/2026-08`), so date
  subfolders work. An album exists only when it contains a photo: `MKCOL` returns 201, but
  the album stays only after the first photo.
- If you upload the same name into the same album again, Servant updates the existing photo.
  The tags and face annotations stay. Use one folder for each device: if two devices upload
  the same generic name into the same album, one file replaces the other.
- The capture date comes from the EXIF data (or the MP4/MOV container for videos). If there
  is no date, Servant uses the `X-OC-MTime` header (sent by PhotoSync and rclone), then the
  upload time.
- HEIC support needs a server libvips with libheif (usual for a system libvips, see
  deploy.md). With libheif, thumbnails, viewing and EXIF (date, GPS, camera) work. Without
  libheif, Servant keeps the file without a preview, and the date comes from `X-OC-MTime`. In
  this case, set PhotoSync to JPEG.
- Servant stores videos and you can play them, but the server makes no preview image for
  them.

## Protocol notes (implementation)

- `PROPFIND` does not read the requested property list. It always returns all the supported
  properties for the resource type. Clients ignore the extra properties.
- The `calendar-query` and `addressbook-query` REPORTs return all the collection. The server
  does not filter; the clients filter.
- There is no `sync-token` (RFC 6578). Clients compare the ctag and the etags. This is
  sufficient for personal use.
- The ETags come from the entry content. The ctags come from the etags of the collection.
