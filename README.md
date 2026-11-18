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
- One setup shared by several Macs: keep the sync data in iCloud Drive, Dropbox or a shared
  drive, and every Mac knows what's already been synced.
- Pix-Star's 3,000-photos-per-album limit is handled by rolling over into `<album> 2`, `<album> 3`, ….
- Pix-Star album backup, with a list of the photos that aren't in a local folder.
- Updates itself from a folder you publish builds to: it finds a newer build, downloads and
  checks it, and installs it when you click **Install & Restart**.
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
3. Optional: **Settings…** in an account's ⋯ menu can downsize photos to a longest side
   and compress them (Light, Medium or Strong JPEG compression) before they're uploaded, per
   account. **Estimate Sizes** there adds up the albums that account syncs and shows roughly
   how big they'd be at each level. Settings apply to photos uploaded from then on.
4. **Sync All** (⇧⌘S). Each row shows what happened; the **Log** has the details.

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
| Google Photos | The official Photos Library API | Since March 2025 apps can only add to **albums they created**, so create the album from Photo Syncer and pick it on the frame. Needs your own OAuth client (below). Uploads count against your Google storage: turn on **Compress photos** (and downsizing) in the account's settings to upload smaller copies. |
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

**Sync data** (default `~/Documents/Photo Syncer`, changeable in **Settings**):

| File | What |
| --- | --- |
| `config.json` | Accounts, mappings, settings |
| `ledger/<mapping>.json` | What each mapping has pushed |
| `logs/<date> (<Mac>).log` | One log per day per Mac |
| `sync.lock` | Which Mac is syncing right now (only while it syncs) |

**This Mac only** (`~/Library/Application Support/Photo Syncer/`):

| File | What |
| --- | --- |
| `location.json` | Where the sync data folder is |
| `secrets.json` (mode 0600) | Google client secret and tokens |
| `md5-cache.json` | MD5s of source files, by path, size and date |
| `updates.json` | The release folder, whether to check automatically, and when it last checked |

Amazon and Pix-Star sign-ins live in WebKit's per-account data stores on each Mac, and are
removed with the account. The whole sync data folder is about 1 MB for ten thousand photos.
A downloaded update waits in `~/Library/Caches/Photo Syncer/Updates/` until it's installed.

### Using it on more than one Mac

1. On the first Mac, **Settings › Sync Data › Change…** and choose a folder every Mac can
   reach (iCloud Drive, Dropbox, a shared drive). The settings and history move there.
2. On each other Mac, install Photo Syncer, choose the same folder, and pick **Use the
   Settings There**. Then sign in to each account once (sign-ins aren't shared), and for
   Google, paste the client ID and secret into Google Photos setup again.

What makes this work:

- **Photos are recognised by their iCloud Photos id**, which is the same on every Mac using
  the library, so a photo synced from one Mac counts as synced on the others. Albums are found
  by iCloud id too, falling back to their path ("Frames › Family"). Without iCloud Photos, a
  Photos album's history only applies to the Mac that synced it (**Settings** says which).
- **Folder paths are stored relative to your home folder** (`~/Pictures/Frames`), so they work
  on a Mac with a different user name, as long as the folder is in the same place.
- **One Mac syncs at a time.** The syncing Mac writes `sync.lock` and touches it every minute;
  another Mac that tries to sync is told who's syncing, and can sync anyway (for a lock left by
  a Mac that crashed). A lock untouched for 10 minutes is ignored. With a cloud-synced folder
  the lock takes as long as the folder does to appear on the other Mac, so the ledgers also
  merge when saved: neither Mac can drop the other's progress.
- Settings changed on one Mac are picked up by the others when their window comes forward
  or they start a sync.

Set `PHOTO_SYNCER_HOME=<folder>` to run the app with everything (sync data and this Mac's
files) in one throwaway folder.

## Publishing and updating

If you build Photo Syncer yourself and run it on more than one Mac, the app can update itself
from a **release folder**: any folder every Mac can reach (iCloud Drive, Dropbox, a shared
drive), for example `~/Dropbox/Photo Syncer Releases`.

**Publish** (on the Mac you build on):

1. Create the folder, and tell the script where it is, once:
   `echo "~/Dropbox/Photo Syncer Releases" > .release-dir` in the repository (the file is
   gitignored), or set `RELEASE_DIR` each time.
2. Commit your changes, then run `scripts/publish.sh` (optionally
   `--notes "What changed"`). It builds the disk image, copies it to the folder, and then
   writes `latest.json` there:

   ```json
   {
     "build" : 42,
     "file" : "Photo-Syncer-1.2.0-42.dmg",
     "notes" : "What changed",
     "publishedAt" : "2026-01-02T03:04:05Z",
     "sha256" : "…",
     "version" : "1.2.0"
   }
   ```

   The **build** number is the git commit count, and it's what decides "newer"; the version
   (`VERSION=1.2.0 scripts/publish.sh`) is only shown. The script refuses to publish a build
   that isn't higher than the one already in `latest.json`, so commit before publishing again.

**Update** (on every Mac):

1. **Settings › Updates › Choose…** and pick the release folder. Each Mac remembers its own.
2. Photo Syncer reads `latest.json` when it opens, when it comes forward (at most once an
   hour), and on **Check Now**. When the build there is newer, it copies the disk image to
   this Mac (waiting for iCloud to download it if needed) and checks its SHA-256.
3. The status then says the version is ready. Nothing is installed until you click
   **Install & Restart** (not available during a sync): the app checks that the image holds
   the announced build of Photo Syncer with a valid code signature, quits, and a small helper
   swaps the app and opens it again. The old app is kept until the new one is in place, and is
   put back if anything fails; `~/Library/Caches/Photo Syncer/Updates/install.log` says what happened.

Things to know:

- **The app installs what it finds in that folder**, so use one only you can write to. The
  checksum guards against a half-synced or damaged file, not against someone who can change
  both the image and `latest.json`. When the running app is signed with an Apple certificate,
  the new build must be signed by the same team; ad hoc and self-signed builds have no team to check.
- Updates aren't notarized (that needs a Developer ID; see Building). The helper clears the
  quarantine flag on the app it installs, so it opens without a Gatekeeper warning.
- With ad hoc signing, macOS asks for Photos access again after every update, because each
  build has a new signature. Signing every build with the same certificate avoids that on the
  Mac that has it (`scripts/make-signing-cert.sh`).
- The app replaces itself wherever it is, so it must be somewhere you can write to (your own
  Applications folder is fine). If macOS says Photo Syncer was prevented from modifying apps,
  allow it under System Settings › Privacy & Security › App Management and click
  **Install & Restart** again.
- Old disk images stay in the release folder; delete them when you like (the app only reads
  the one `latest.json` names).

## Building

Needs the Xcode Command Line Tools (Xcode itself is optional) and macOS 14 or later.

| Command | What it does |
| --- | --- |
| `scripts/test.sh` | Runs the tests (Swift Testing). |
| `scripts/build-app.sh [--install] [--open]` | Builds `build/Photo Syncer.app`, optionally installs or opens it. |
| `scripts/make-dmg.sh` | Builds the app and `build/Photo-Syncer-<version>.dmg`. Arranging the DMG window needs permission to control Finder (asked once). |
| `scripts/publish.sh [--notes "…"]` | Runs `make-dmg.sh`, then publishes the image and `latest.json` to the release folder (`RELEASE_DIR` or `.release-dir`) for the app's updater. See Publishing and updating. |
| `scripts/make-signing-cert.sh` | Once per Mac without an Apple certificate: adds a self-signed code-signing certificate to your login keychain, so the Photos permission survives rebuilds. |

With only the Command Line Tools, the macOS 27 SDK's SwiftUI needs a macro plugin that ships
with Xcode, so the scripts build against the newest macOS 26 SDK instead (`choose_sdk` in
`scripts/common.sh`). Signing uses a Developer ID or Apple Development certificate if the
keychain has one, then the self-signed one `scripts/make-signing-cert.sh` creates, else ad hoc.
With ad hoc signing macOS asks for Photos access again after each rebuild; run
`scripts/make-signing-cert.sh` once to keep the permission across rebuilds.

`PHOTO_SYNCER_SNAPSHOT=<folder>` makes the app draw each pane (and the Sync pane after
syncing everything) into PNGs and quit, for checking the UI from a script; the updater does
nothing in that mode. To test the updater's installer from a script, run a scratch copy of the
app with `PHOTO_SYNCER_HOME` set and `PHOTO_SYNCER_UPDATE_AUTOINSTALL=1`: it then installs a
ready update without waiting for the click (the switch is ignored without `PHOTO_SYNCER_HOME`).

### Code

- `Sources/PhotoSyncerCore`: no UI.
  - `Models/Config.swift`: accounts, sources, destinations, mappings.
  - `Sources/`: folder and Photos-album sources (PhotoKit), and the upload payloads (JPEG conversion, downsizing).
  - `Services/`: one client per service, behind `RemoteService`.
  - `Sync/SyncPlanner.swift`: what's new, matched, or to upload (pure, tested).
  - `Sync/SyncEngine.swift`: runs a mapping, Pix-Star overflow, backups, the log.
  - `Store/`: where files live (`Storage`: sync data folder versus this Mac's folder, moving
    between them, the `SyncLock`), and the per-mapping `Ledger` (merged on save).
  - `Update/UpdateChecker.swift`: reading `latest.json` (`ReleaseInfo`), "is it newer", fetching
    the disk image through a `ReleaseSource` (today a folder; a URL source would fit the same
    protocol), the SHA-256 check, and this Mac's `UpdateSettings` (pure, tested).
- `Sources/PhotoSyncer`: the SwiftUI app, in-app sign-in (`Auth/WebSessions.swift`), Google OAuth hand-off,
  Settings (`Views/SettingsView.swift`), and `Updater.swift`: when to check, the Updates
  section's state, and `UpdateInstaller` (unpacks and checks the build, then hands the bundle
  swap to a helper script that runs after the app quits).
- `scripts/publish.sh`: the publishing half of the updater.
- `Tests/PhotoSyncerCoreTests`: matching, page and response parsing (fixtures modelled on
  pix-star.com markup and Amazon responses, with made-up ids), the engine end to end against a
  fake service, and the update checker against made-up releases in a temporary folder.

## Contributing

Issues and pull requests are welcome. Run `scripts/test.sh` before sending a change. If a
service changes its website, start by updating the test fixture to the new markup or
response, then the parser. Never commit real account ids, cookies, tokens or photos.

## License

[MIT](LICENSE)
