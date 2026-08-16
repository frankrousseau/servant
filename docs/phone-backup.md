# Backing up your phone to Servant

Servant serves the Photos app over WebDAV at `/dav/photos`. Any
auto-upload app that speaks WebDAV can push your camera roll to your
Servant unattended: new photos land in the **Photos** app on their own,
with EXIF dates, thumbnails and albums, and re-uploads update the photo
instead of duplicating it. (For arbitrary documents rather than photos,
the Files app is served the same way at `/dav/files`; same recipes, with
the `app:files:*` scopes.)

## What you need

- Your Servant reachable from the phone over HTTPS (for example
  `https://servant.example.com`).
- An API token with write access to Photos.

## 1. Create the token

1. In Servant, open **Settings** and create an API token.
2. Give it the `app:photos:write` scope (add `app:photos:read` if the
   app also lists remote folders; most do).
3. Copy the `srv_...` value: it is shown once.

Tokens are revocable from Settings at any time and never expire; prefer
them over a session token (which dies after 30 days).

## 2. Configure the phone

The WebDAV target is always:

```
URL       https://<your-host>/dav/photos
User      anything (the name is ignored)
Password  the srv_ token
```

Add a folder to the URL to name the album, e.g.
`https://<your-host>/dav/photos/Camera`; the album appears in the
Photos app with the first upload. Use one folder per device (two phones
uploading the same generic file name into the same album would
overwrite each other).

### PhotoSync (iOS and Android)

1. Install PhotoSync, open **Configure > Autotransfer target > WebDAV**.
2. Enter the URL, any user name, and the token as password.
3. Pick the directory (e.g. `Camera`) and enable autotransfer
   (new photos, in the background, Wi-Fi only if you prefer).
4. On iOS you can keep HEIC as long as the server's libvips has libheif
   (see deploy.md): thumbnails and EXIF (capture date, GPS, camera) are
   extracted like for JPEG. If HEIC uploads show without a preview, the
   server lacks libheif; switch the transfer format to JPEG ("most
   compatible") in that case.

Date subfolders are fine: PhotoSync's "create subdirectories" options
produce albums like `Camera/2026-08`.

### FolderSync (Android)

1. Add an account of type **WebDAV** with the URL and credentials above.
2. Create a folder pair: local `DCIM/Camera`, remote the folder of your
   choice, sync type **To remote folder**.
3. Schedule it (daily, on charge, Wi-Fi only: your call).

### rclone (desktop, optional)

```
rclone config          # new remote, type webdav, url https://<host>/dav/photos
rclone copy ~/Pictures servant:Pictures
```

## What happens on the Servant side

- Every upload becomes a regular photo in the **Photos** app (source
  `webdav`), in the album matching the WebDAV folder. The capture date
  comes from EXIF (or the video container), so photos land at the right
  spot in the timeline even when backed up much later.
- Uploading the same name again updates the photo (no duplicates); the
  phone apps rely on this to re-sync safely. Tags and face annotations
  set in Servant survive the re-upload.
- Videos are stored and playable in the Photos app, without a
  server-generated preview image.
- Deleting an album folder over WebDAV deletes every photo in it,
  sub-albums included.

## Limits

- No locks and no MOVE/COPY: sync apps do not need them, but mounting
  `/dav/photos` as a network drive in Windows Explorer will not work.
- Maximum file size: 1 GB, same as the web upload.

## Troubleshooting

- **401**: wrong or revoked token; the password must be the full
  `srv_...` value (not your Servant account password).
- **403**: the token lacks `app:photos:write`.
- **404 on every request**: the URL is missing the `/dav/photos` path;
  check the server field and the directory field of the app.
- **Photos land under today's date**: the originals carry no EXIF date
  (screenshots, messaging-app images) and the app did not send
  `X-OC-MTime`; the upload time is used as a fallback.
