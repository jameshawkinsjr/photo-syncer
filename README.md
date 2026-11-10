# Photo Syncer

A Mac app that pushes photos from **Photos albums** or **folders** to the albums your
picture frames show: **Amazon Photos**, **Google Photos**, **Pix-Star**, and plain
**folders** (for a home dashboard or anything else that reads files). Sign in to as many
accounts as you like, map each source to an album, and press **Sync All**: only photos
that haven't been pushed yet go up.

```
Photos › Frames › Family ──┬──▶ Amazon Photos / Family
                           ├──▶ Google Photos / Family         (album made by Photo Syncer)
                           ├──▶ Pix-Star (kitchen frame) / Family, Family 2, …
                           └──▶ Folder / Dashboard / Family
~/Pictures/Travel ─────────────▶ Pix-Star (hallway frame) / Travel
```

> **Unofficial.** Photo Syncer isn't affiliated with or endorsed by Amazon, Google or
> Pix-Star. Amazon Photos and Pix-Star have no public API, so it uses the same web
> requests their websites make, with your own sign-in; if a site changes, that part may stop
> working until the app is updated. Use it with your own accounts, at your own risk.

## Features

- Sources: any album in the Photos library (edits included, iCloud-only photos downloaded),
  or a folder and its sub-folders.
- Destinations: Amazon Photos, Google Photos, Pix-Star and local folders, with as many
  accounts per service as you like (for example two Pix-Star frames).
- Pushes only what's new, remembered per mapping; finds photos already in the destination on
  the first sync so nothing is uploaded twice.
- Pix-Star's 3,000-photos-per-album limit is handled by rolling over into `<album> 2`, `<album> 3`, ….
- Pix-Star album backup, with a list of the photos that aren't in a local folder.
- Never deletes anything from a service.

## Install

Open `Photo-Syncer-<version>.dmg` and drag **Photo Syncer** into Applications. The app is
signed ad hoc (no Apple Developer ID), so on a Mac other than the one that built it, right-click
it and choose **Open** the first time.

## Using it

1. **Accounts › +**: add each account. Amazon and Pix-Star open a sign-in window inside
   the app; Google opens your browser (after the one-time setup below); a Folder account is
   just a folder on disk. Add a second Pix-Star account the same way: each account keeps its
   own sign-in.
2. **Sync › +**: pick a source (a Photos album, or a folder and its sub-folders), an
   account, and an album there, or create a new album.
3. **Sync All** (⇧⌘S). Each row shows what happened; the **Log** has the details.

### What counts as "new"

Each mapping keeps a ledger of the photos it has pushed (`ledger/<mapping>.json`). A photo
in the ledger is never sent again by that mapping, even if you delete it from the service.

On a mapping's first sync, Photo Syncer looks for photos already in the album:

- **Amazon** keeps the exact bytes, so files are matched by **MD5**; a folder of photos
  that was uploaded by hand is recognised even under different names. Amazon also refuses
  duplicates account-wide; when a photo is already in the account, Photo Syncer links it
  into the album's folder instead of uploading it again.
- **Pix-Star** and **Google** are matched by **file name** (Pix-Star renames uploads to
  `My_Photo_1234.jpg`; that's undone before comparing).

If more than 50 photos are still unmatched, the first sync stops and asks:
**Upload N Photos**, or **They're Already There**, which records everything currently in
the source as synced, so only photos added from now on go up. Use that when the album
already has the photos but they can't be matched (for example, a Photos album as the source
when the service was filled from exported copies).

### Service notes

| Service | How it talks to it | Notes |
| --- | --- | --- |
| Amazon Photos | The web API amazon.com/photos uses, with the in-app sign-in's cookies | Albums made from a folder ("smart" albums) are filled by uploading into the folder. Other albums get a `Photo Syncer/<album>` folder. Originals are uploaded untouched. |
| Pix-Star | pix-star.com's web-album pages and uploader, with the in-app sign-in's cookies | **A frame syncs at most 3,000 photos per album.** When an album is full, Photo Syncer creates `<album> 2`, `<album> 3`, … and carries on; add those to the frame's slideshow. Photos are downsized to 2048 px before upload (Pix-Star keeps small copies anyway); change it per account. Albums managed by a multi-frame account can only be uploaded to from that account. **Back Up an Album…** downloads an album to disk and sets aside the photos that have no match in a local folder. |
| Google Photos | The official Photos Library API | Since March 2025 apps can only add to **albums they created**, so create the album from Photo Syncer and pick it on the frame. Needs your own OAuth client (below). |
| Folder | Copies files | One sub-folder per album, plus `index.json` (newest first) so a dashboard can read one file. |

Amazon and Pix-Star have no public API; if either changes its website, uploads may stop
working until the app is updated. Nothing is ever deleted from a service: Photo Syncer only adds.

### Google Photos setup (once)

Google only lets apps upload with an OAuth client registered to someone, so you make your own:

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project.
2. **APIs & Services › Library**: enable the **Photos Library API**.
3. **Google Auth Platform › Branding**: app name, support email and developer contact.
   **Audience**: External.
4. Choose how the app runs:
   - **Testing** (simplest): under **Audience › Test users**, add the Google account whose
     Photos you'll upload to. Google expires the sign-in every 7 days; Photo Syncer then says
     it's not signed in, and you click **Sign In…** again.
   - **In production**: Google requires a homepage and privacy-policy URL on a domain you
     own (Branding) before **Publish app** works. The sign-in then lasts.
5. **Clients › Create client**, type **Desktop app**. Copy the client ID and secret into
   **Accounts › Google Photos setup** in Photo Syncer. Google shows the secret only once; if
   it's lost, add a new one on the client's page.
6. Add a Google account and sign in. Google warns the app isn't verified (it's your own
   client): continue past the warning. *"Access blocked: … has not completed the Google
   verification process"* means the account isn't a test user (step 4).

Albums you made in Google Photos itself won't appear in Photo Syncer: create the album from
the mapping editor (**Create**), then choose it on your frame.

## Where things are kept

`~/Library/Application Support/Photo Syncer/`:

| File | What |
| --- | --- |
| `config.json` | Accounts, mappings, settings |
| `ledger/<mapping>.json` | What each mapping has pushed |
| `secrets.json` (mode 0600) | Google client secret and tokens |
| `md5-cache.json` | MD5s of source files, by path, size and date |
| `logs/<date>.log` | One log per day |

Amazon and Pix-Star sign-ins live in WebKit's per-account data stores, and are removed with
the account. Set `PHOTO_SYNCER_HOME=<folder>` to run the app against other settings.

## Building

Needs the Xcode Command Line Tools (Xcode itself is optional) and macOS 14 or later.

| Command | What it does |
| --- | --- |
| `scripts/test.sh` | Runs the tests (Swift Testing). |
| `scripts/build-app.sh [--install] [--open]` | Builds `build/Photo Syncer.app`, optionally installs or opens it. |
| `scripts/make-dmg.sh` | Builds the app and `build/Photo-Syncer-<version>.dmg`. Arranging the DMG window needs permission to control Finder (asked once). |

With only the Command Line Tools, the macOS 27 SDK's SwiftUI needs a macro plugin that ships
with Xcode, so the scripts build against the newest macOS 26 SDK instead (`choose_sdk` in
`scripts/common.sh`). Signing uses a Developer ID or Apple Development certificate if the
keychain has one, else ad hoc; with ad hoc signing macOS asks for Photos access again after
each rebuild.

`PHOTO_SYNCER_SNAPSHOT=<folder>` makes the app draw each pane (and the Sync pane after
syncing everything) into PNGs and quit, for checking the UI from a script.

### Code

- `Sources/PhotoSyncerCore`: no UI.
  - `Models/Config.swift`: accounts, sources, destinations, mappings.
  - `Sources/`: folder and Photos-album sources (PhotoKit), and the upload payloads (JPEG conversion, downsizing).
  - `Services/`: one client per service, behind `RemoteService`.
  - `Sync/SyncPlanner.swift`: what's new, matched, or to upload (pure, tested).
  - `Sync/SyncEngine.swift`: runs a mapping, Pix-Star overflow, backups, the log.
- `Sources/PhotoSyncer`: the SwiftUI app, in-app sign-in (`Auth/WebSessions.swift`), Google OAuth hand-off.
- `Tests/PhotoSyncerCoreTests`: matching, page and response parsing (fixtures modelled on
  pix-star.com markup and Amazon responses, with made-up ids), the engine end to end against a
  fake service.

## Contributing

Issues and pull requests are welcome. Run `scripts/test.sh` before sending a change. If a
service changes its website, start by updating the test fixture to the new markup or
response, then the parser. Never commit real account ids, cookies, tokens or photos.

## License

[MIT](LICENSE)
