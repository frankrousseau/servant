# Backing up your phone to Servant

A WebDAV auto-upload app can send your camera roll to the **Photos** app at `/dav/photos`.
For documents, use `/dav/files` with the same procedures and the `app:files:*` scopes. For the
server behavior (albums, dates, HEIC, re-uploads), see [dav.md](dav.md#photos-over-webdav-davphotos).

## What you need

- A Servant that the phone can reach over HTTPS (for example `https://servant.example.com`).
- An API token with write access to Photos.

## 1. Make the token

1. In Servant, open **Settings** and make an API token.
2. Give it the `app:photos:write` scope. If the upload app shows remote folders (most apps do),
   also give it `app:photos:read`.
3. Copy the `srv_...` value. Servant shows it only one time.

## 2. Configure the phone

Use this WebDAV target:

```
URL       https://<your-host>/dav/photos
User      any value (Servant ignores it)
Password  the srv_ token
```

To set the album, add a folder to the URL, for example `https://<your-host>/dav/photos/Camera`.
The album shows in the Photos app after the first upload. Use one folder for each device: if
two phones upload the same generic file name into the same album, one file replaces the other.

### PhotoSync (iOS and Android)

1. Install PhotoSync.
2. Open **Configure > Autotransfer target > WebDAV**.
3. Type the URL, a user name and the token as the password.
4. Select the directory (for example `Camera`).
5. Enable autotransfer. You can select new photos only, background transfer and Wi-Fi only.
6. On iOS, you can keep HEIC if the server libvips has libheif (see deploy.md). If HEIC photos
   show without a preview, the server does not have libheif. Then set the transfer format to
   JPEG ("most compatible").

The "create subdirectories" options of PhotoSync work. They give albums such as
`Camera/2026-08`.

### FolderSync (Android)

1. Add a **WebDAV** account with the URL and credentials above.
2. Make a folder pair:
   - local folder: `DCIM/Camera`;
   - remote folder: the folder that you select;
   - sync type: **To remote folder**.
3. Set a schedule (for example daily, during charge, Wi-Fi only).

### rclone (desktop, optional)

```
rclone config          # new remote, type webdav, url https://<host>/dav/photos
rclone copy ~/Pictures servant:Pictures
```

## Limits

- Maximum file size: 1 GB (same as the web upload).
- You cannot use `/dav/photos` as a Windows Explorer network drive (no locks).

> **CAUTION:** If you delete an album folder over WebDAV, Servant deletes all the photos in it,
> also in its sub-albums.

## Troubleshooting

| Symptom | Cause and remedy |
|---------|------------------|
| **401** | The token is incorrect or revoked. The password must be the full `srv_...` value, not your Servant account password. |
| **403** | The token does not have the `app:photos:write` scope. |
| **404 on all requests** | The URL does not contain `/dav/photos`. Examine the server field and the directory field of the app. |
| **The photos have the date of today** | The original files have no EXIF date (screenshots, images from messaging apps), and the app did not send `X-OC-MTime`. Servant uses the upload time. |
