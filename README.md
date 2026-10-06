# iPhone Photo Backup — native macOS app (USB, no iCloud)

Native SwiftUI macOS app that imports photos/videos from an iPhone connected via USB
to any folder on this Mac, including an external hard drive.

- Direct USB via Apple's **ImageCaptureCore** (`ICDeviceBrowser` / `ICCameraDevice`) — same tech as Image Capture.
- Organization: `<backup-root>/Photos|Videos/<original-filename>` by default (e.g. `Backup/Photos/IMG_1234.HEIC`),
  with Year, Year/Month and Year/Month-Day layouts available per import.
- Modes: pick individual photos (thumbnails + search) **or** one-click **Import all new (N)** with a live count.
- Duplicates: matched by filename + byte size + capture date (EXIF-verified for photos when readable);
  genuine collisions keep both via `_1`, `_2` suffixes.
- **Reorganize** any existing backup folder into a new layout (year, year/month, year/month/day,
  photos/videos, or GPS location) — moves files, then deletes emptied folders. Dry-run preview included.
- Formats: everything as-is — HEIC, JPEG, PNG, MOV/MP4, Live Photo parts (sidecar files on).

## Requirements

- macOS 13 Ventura or later (arm64/Intel)
- **Xcode 15+** (project + 47-test suite build with `xcodebuild`)
- iPhone + USB cable (USB-C/Lightning). Unlock + tap **Trust** when prompted.
- Storage tab only: Python 3 with pymobiledevice3 (`/usr/bin/python3 -m pip install --user pymobiledevice3`).
  The app is intentionally **not sandboxed** (USB system socket + helper subprocesses).

## Sources

- `Sources/` — app code (`CameraManager`, `ImportManager`, `Reorganizer`, `Models`, UI, entitlements)
- `Assets.xcassets` — AppIcon (generated: blue photo tile + green import badge)
- `Tests/` — XCTest suite: folder layouts, dupe rules, EXIF/GPS parsing, reorganize moves
- `iPhonePhotoBackup.xcodeproj` — app + `iPhonePhotoBackupTests` targets, shared scheme

## Open and run

1. Double-click `iPhonePhotoBackup.xcodeproj`.
2. Select target `iPhonePhotoBackup` → Signing & Capabilities → choose your Team (free Apple ID works for local run, or build ad-hoc — hardened runtime is then off).
3. Press ⌘R. Connect iPhone via USB, unlock, tap Trust.

Entitlements (`device.usb`, `user-selected.read-write`, `network.client` for location lookup) and the
`ImageCaptureCore.framework` link are already configured.

## Tests

```bash
xcodebuild test -project iPhonePhotoBackup.xcodeproj -scheme iPhonePhotoBackup \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-"
```

## Use

1. Pick device (top-left, auto-selected).
2. **Choose backup folder…** — internal folder or external hard drive (e.g. `/Volumes/MyDrive/iPhoneBackup`). Remembered across launches via security-scoped bookmark.
3. Pick a layout (Year / Year-Month / Year-Month-Day / Photos-Videos). Wait for catalog, thumbnails fill in.
4. Either tick photos → **Import selected**, or **Import all new (N)** — N counts what's actually missing.
5. Watch progress + log at the bottom.
6. **Reorganize folder** (sidebar): point at any backup, pick a target layout (incl. Location via EXIF GPS),
   Preview (dry run) first, then Reorganize. Empty folders are removed afterwards.
7. **Storage tab**: list installed apps with container sizes (user apps), search, and delete
   what you don't need (incl. removable Apple apps like Maps). Deletions are permanent;
   protected system apps fail with a device error.

## Troubleshooting

- `Could not open session / locked`: unlock iPhone, tap Trust, unplug/replug USB, wait 5s. Kill Apple's Image Capture if it grabbed the device.
- Empty catalog: wait for "complete content catalog" (large libraries take 10-30s), replug.
- External drive greyed out in picker: ensure it's mounted in Finder (`/Volumes/...`), format APFS/exFAT, and the app has Files permission (sandbox entitlement above).
- Location layout shows "Unknown location": those files have no EXIF GPS (or no network for reverse-geocoding).
- HEIC won't preview on old macOS: files still copy fine; open in Preview/Photos on Ventura+.
- Download error `-9928` etc.: cable issue — try another cable/port, keep iPhone awake (Settings → Display → Never during backup).
- Stalled download (`Stalled (no progress for 120s), skipping`): a hung transfer is failed automatically so the queue keeps moving; replug USB if it repeats.

## Notes / limitations

- USB PTP only exposes the Camera Roll catalog — some custom Photos albums/smart folders aren't visible over USB (iOS limitation).
- Deletes are not offered during import (backup-only, safe); reorganize only deletes folders it emptied.
- One download at a time (ImageCaptureCore is most reliable serially); byte-level progress isn't exposed, progress is per-file.
- Video capture dates come from file dates (no EXIF); dupe checks for videos fall back to name + size.
