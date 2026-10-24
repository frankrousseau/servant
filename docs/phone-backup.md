# Phone backup

**Every photo you take lands in Servant by itself: dated, in its album, ready to tag.**

Any WebDAV auto-upload app works: PhotoSync (iOS, Android), FolderSync (Android), or rclone on
a computer. A photo sent twice is updated, never duplicated.

**You need** a Servant that your phone reaches over HTTPS.

## 1. Create a token

In **Settings > API Tokens**, create a token with **Photos** set to **Read + write**, and copy
the `srv_...` value: it shows only once.

## 2. Connect the app

| Field | Value |
|-------|-------|
| URL | `https://<your-host>/dav/photos` |
| User | anything (ignored) |
| Password | your `srv_...` token |

Each folder under that URL is an album (`Camera`, `Camera/2026-08`). Give each phone its own
folder: two phones sending `IMG_0001.jpg` to the same album overwrite each other.

### PhotoSync (iOS and Android)

1. In **Configure > Autotransfer target > WebDAV**, enter the URL, any user name, and the token
   as password.
2. Pick a directory, for example `Camera`. The "create subdirectories" options work too.
3. Turn on autotransfer (new photos, background, Wi-Fi only: your call).

HEIC photos without a preview? Your server cannot decode HEIC (see
[Deployment](deploy.md#bare-metal-release)): set the transfer format to JPEG ("most
compatible").

### FolderSync (Android)

1. Add a **WebDAV** account with the values above.
2. Create a folder pair: local `DCIM/Camera`, any remote folder, sync type **To remote folder**.
3. Schedule it, for example daily, while charging, on Wi-Fi.

### rclone (computer)

```bash
rclone config                             # remote "servant", type webdav, url .../dav/photos
rclone copy ~/Pictures servant:Pictures
```

## Good to know

- Files up to 1 GB.
- For documents, use `/dav/files` with **Files** access: same steps.
- Windows Explorer cannot mount `/dav/photos` as a drive (no WebDAV locks).
- Dates, HEIC, videos and re-uploads in detail: [Phone sync](dav.md#files-and-photos-over-webdav).

> [!CAUTION]
> Deleting an album folder over WebDAV deletes all its photos, sub-albums included.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| **401** | Wrong or revoked token. The password is the full `srv_...` token, not your account password. |
| **403** | The token cannot write: set **Photos** to **Read + write**. |
| **404 on every request** | The URL lacks `/dav/photos`. |
| **Photos dated today** | No EXIF date in the files (screenshots, messaging apps) and no `X-OC-MTime` from the app: Servant uses the upload time. |
