# Phone sync

**Your calendars and contacts on your phone, both ways. Your files and photos too.**

Add an event on your phone and it shows in Servant; fix a number in Servant and your phone gets
it. No Google or iCloud in between: standard CalDAV, CardDAV and WebDAV, tested with iOS and
DAVx5 (Android).

| Address | Syncs | Token access |
|---------|-------|--------------|
| `/dav` | Calendar and Contacts, both ways | **Calendar**, **Contacts** |
| `/dav/files` | Files | **Files** |
| `/dav/photos` | Photos, for camera uploads ([guide](phone-backup.md)) | **Photos** |

## Connect your phone

1. In **Settings > API Tokens**, create a token with **Calendar** and **Contacts** set to
   **Read + write** (**Read** for a one-way sync). Copy the `srv_...` value.
2. Add an account on the phone:

| | Android (DAVx5) | iOS |
|---|---|---|
| **Add** | **Login with URL and user name** | Settings > Calendar (or Contacts) > Accounts > Add CalDAV (or CardDAV) account |
| **Server** | `https://<your-host>/dav` | `<your-host>` |
| **User name** | anything | anything |
| **Password** | the `srv_...` token | the `srv_...` token |

One DAVx5 account syncs calendars and contacts; iOS finds the addresses by itself
(`/.well-known/caldav`, `/.well-known/carddav`).

> [!TIP]
> Use an API token rather than your login session: it lasts until you revoke it (or until its
> expiry date), while a session token dies after 30 days.

## What syncs

- **Calendars:** one per agenda (`Manual`, the calendars you created, the agendas your events
  use). **Contacts:** one `contacts` address book.
- **Only what you write.** Feeds polled by a source (iCal or vCard URLs) stay off the phone,
  or the next poll would erase your phone edits. Subscribe to them on the phone.
- **Phone extras survive:** alarms, attendees, complex repeats, photos and structured names
  stay intact, until you edit the item in Servant, which rebuilds it from the fields it knows.
- **Import an address book:** phones cannot move contacts between accounts, so drop a `.vcf`
  export on **Sources > Contacts (vCard) > Import**. The cards become your own contacts, kept
  as is (inline photos become avatars), and reach the phone at the next sync. They keep their
  UID: when the phone sends one back, Servant updates the contact instead of duplicating it.
- **Merging duplicates** (**Contacts > Duplicates**) gives the kept contact the phone identity
  (resource name, UID) of the merged one when it has none, so the phone sees an update, not a
  deletion.

## Files and photos over WebDAV

`/dav/files` and `/dav/photos` serve the same folders as the apps, both ways. Uploading an
existing name replaces the file. There are no locks and no `MOVE` or `COPY`: sync apps do not
need them, but Windows Explorer cannot mount these folders.

Each photo is stored, its EXIF read and its thumbnails made, then it shows in the Photos app
like any other (timeline, albums, face tagging):

- **Folders are albums:** `/dav/photos/Camera/IMG.jpg` lands in *Camera*, subfolders give
  `Camera/2026-08`. An empty album does not persist (`MKCOL` returns 201 anyway).
- **Re-uploads update** the photo and keep its tags and faces. One folder per device avoids
  name collisions.
- **Dates:** EXIF (or the MP4/MOV container), then the `X-OC-MTime` header (PhotoSync,
  rclone), then the upload time.
- **HEIC** needs libvips with libheif on the server ([Deployment](deploy.md#bare-metal-release)).
  Without it: no preview, and the date comes from `X-OC-MTime`. Set PhotoSync to JPEG.
- **Videos** play, without a preview image.

## Protocol notes

For client developers: subsets of CalDAV (RFC 4791) and CardDAV (RFC 6352), and WebDAV class 1
(`PROPFIND` depth 0 and 1, `GET`, `PUT`, `MKCOL`, recursive `DELETE`).

- `PROPFIND` returns every supported property, whatever the request asks for.
- The `calendar-query` and `addressbook-query` REPORTs return the whole collection; clients
  filter.
- No `sync-token` (RFC 6578): clients compare the ctag and the ETags. ETags derive from the
  entry content, the ctag from the ETags of the collection.
