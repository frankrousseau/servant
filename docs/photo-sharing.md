# Sharing a photo feed by link

The Photos app can publish a **public link over one or more tags or people**:
anyone holding the link sees the photos carrying those tags or people (the
contacts named on a photo), in a read-only gallery,
without an account. The feed is computed when the link is opened, so photos
you tag later show up on their own, and untagging a photo removes it. That
is what makes it a feed rather than an album snapshot: tag the photos of an
ongoing trip as you go, share the link once.

## Creating a link

1. In **Photos**, click **Share** in the toolbar (the button appears once at
   least one photo carries a tag or a person).
2. Pick tags, people, or both. With several, choose whether the feed keeps
   photos carrying **any** of them (union) or **all** of them (intersection):
   "Alice + beach" is the beach photos Alice is on.
3. Optionally name the link (the name titles the public page; otherwise the
   tags do, and a people-only link reads "Shared photos", since the page never
   names anyone), then **Create link**. The URL is copied to the clipboard.

The same dialog lists the existing links, each with **Copy**, **Open** and
**Revoke**; **Settings > API Tokens > Shared photo links** lists them too,
with the same copy and revoke actions. Revoking a link cuts access at once:
the page and its files stop resolving.

## What a visitor gets

- The page at `/share/<token>`: a thumbnail grid, newest first, and a viewer
  with zoom, full-resolution and download. No delete, no in-app permalink,
  no sidebar, even for the logged-in owner (what they see is what a visitor
  gets).
- Per photo, only the title, the date, the media type and the files
  (original, thumbnail, display copy). EXIF location, camera, album, people
  and the other tags stay private.
- Files are served under `/share/<token>/files/…`, and only the files of a
  photo currently in the feed resolve there; the rest of your store is
  unreachable through the link.

## Security notes

- The token is the whole credential: 192 random bits in the URL, no session
  required. Treat the link like a password for those photos; anyone you
  forward it to can forward it further. Revoke it when the sharing is over.
- Tokens are stored as-is (not hashed) so the owner can copy a link again;
  a database backup therefore contains working links.
- Links are managed from a browser session only (`/api/photo_shares`); API
  tokens, whatever their scopes, cannot create or list them.
- The public JSON behind the page is `GET /api/shares/<token>` (documented
  at `/api/docs`), usable from a script or another site.
