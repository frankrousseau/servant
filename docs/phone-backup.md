# Backing up your phone to Servant

Servant serves your Files app over WebDAV at `/dav/files`. Any auto-upload
app that speaks WebDAV can push your camera roll (or any folder) to your
Servant unattended: new photos land in the Files app on their own, and
re-uploads replace the file instead of duplicating it.

## What you need

- Your Servant reachable from the phone over HTTPS (for example
  `https://servant.example.com`).
- An API token with write access to Files.

## 1. Create the token

1. In Servant, open **Settings** and create an API token.
2. Give it the `app:files:write` scope (add `app:files:read` if the app
   also lists remote folders; most do).
3. Copy the `srv_...` value: it is shown once.

Tokens are revocable from Settings at any time and never expire; prefer
them over a session token (which dies after 30 days).

## 2. Configure the phone

The WebDAV target is always:

```
URL       https://<your-host>/dav/files
User      anything (the name is ignored)
Password  the srv_ token
```

Add a subfolder to the URL to keep backups tidy, e.g.
`https://<your-host>/dav/files/Camera`; the app creates it on first
upload.

### PhotoSync (iOS and Android)

1. Install PhotoSync, open **Configure > Autotransfer target > WebDAV**.
2. Enter the URL, any user name, and the token as password.
3. Pick the directory (e.g. `Camera`) and enable autotransfer
   (new photos, in the background, Wi-Fi only if you prefer).

### FolderSync (Android)

1. Add an account of type **WebDAV** with the URL and credentials above.
2. Create a folder pair: local `DCIM/Camera`, remote the folder of your
   choice, sync type **To remote folder**.
3. Schedule it (daily, on charge, Wi-Fi only: your call).

### rclone (desktop, optional)

```
rclone config          # new remote, type webdav, url https://<host>/dav/files
rclone copy ~/Pictures servant:Pictures
```

## What happens on the Servant side

- Every upload becomes a regular file in the **Files** app (source
  `webdav`), in the folder matching the WebDAV path. Renames, moves and
  deletes done in the Files app apply to what the phone sees too.
- Uploading the same name again replaces the file (no duplicates); the
  phone apps rely on this to re-sync safely.
- Deleting a folder over WebDAV deletes everything below it.

## Limits

- No locks and no MOVE/COPY: sync apps do not need them, but mounting
  `/dav/files` as a network drive in Windows Explorer will not work.
- Maximum file size: 1 GB, same as the web upload.

## Troubleshooting

- **401**: wrong or revoked token; the password must be the full
  `srv_...` value.
- **403**: the token lacks `app:files:write`.
- **409 on upload**: the target folder does not exist and the app did not
  create it; add the folder first (most apps do this themselves).
