# Sharing a photo feed by link

The Photos app can make a **public link for one or more tags or people** (people are the
contacts named on a photo). A person with the link sees the photos with these tags or people in
a read-only gallery. This person does not need an account.

Servant calculates the feed each time a person opens the link. Thus a photo that you tag later
shows in the feed, and a photo that you untag goes out of it.

## Make a link

1. In **Photos**, click **Share** in the toolbar. The button shows when one or more photos have
   a tag or a person.
2. Select tags, people, or both. With more than one, select how the feed keeps the photos:
   - **any**: photos with one or more of them (union);
   - **all**: photos with all of them (intersection). For example, "Alice + beach" gives the
     beach photos with Alice.
3. Optional: type a name for the link. The name is the title of the public page. Without a
   name, the tags are the title. A link with only people has the title "Shared photos",
   because the page never shows names of people.
4. Click **Create link**. Servant copies the URL to the clipboard.

The same dialog shows the existing links, each with **Copy**, **Open** and **Revoke**.
**Settings > API Tokens > Shared photo links** also shows them, with Copy and Revoke. When you
revoke a link, access stops immediately: the page and its files do not resolve.

## Add a caption to a photo

Open a photo, click **Info** and type text in the **Note** field. Servant saves the note when
the field loses focus. The note shows as a caption under the photo, in the app and on each
share link that contains the photo.

## What a visitor sees

- The page `/share/<token>`: a grid of thumbnails (newest first) and a viewer with zoom,
  full resolution and download. There is no delete, no in-app permalink and no sidebar. The
  owner sees the same page as a visitor.
- For each photo, only: the title, the date, the media type, the files (original, thumbnail,
  display copy) and the note. The viewer shows the note as a caption, so write it for the
  persons with the link. The EXIF location, camera, album, people and other tags stay private.
- Servant serves the files under `/share/<token>/files/…`. Only the files of a photo that is
  in the feed now resolve there. The link gives no access to the other files.

## Security notes

- The token is the only credential: 192 random bits in the URL, no session. Keep the link
  safe, as a password for these photos. A person with the link can send it to other persons.
  When the sharing is complete, revoke the link.
- Servant stores the tokens as they are (not hashed), so the owner can copy a link again. Thus
  a database backup contains links that work.
- Only a browser session can manage links (`/api/photo_shares`). API tokens cannot make or
  list links, with all scopes.
- The page uses the public JSON route `GET /api/shares/<token>` (documented at `/api/docs`).
  A script or a different site can also use it.
