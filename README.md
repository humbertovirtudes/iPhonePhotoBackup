# iPhone Photo Backup — native macOS app (USB, no iCloud)

Native SwiftUI macOS app that imports photos/videos from an iPhone connected via USB
to any folder on this Mac, including an external hard drive.

- Direct USB via Apple's **ImageCaptureCore** (`ICDeviceBrowser` / `ICCameraDevice`) — same tech as Image Capture.
- Organization: `<backup-root>/YYYY/MM-dd/<original-filename>` (e.g. `Backup/2026/10-04/IMG_1234.HEIC`)
- Modes: pick individual photos (thumbnails + search) **or** one-click **Import all new**
- Duplicates: files that already exist with the same byte size are skipped; name collisions get `_1`, `_2` suffixes
- Formats: everything as-is — HEIC, JPEG, PNG, MOV/MP4, Live Photo parts (sidecar files on)

## Requirements

- macOS 13 Ventura or later (arm64/Intel), tested conceptually for macOS 14/15
- **Xcode 15+** from the App Store (~15 GB) — this Mac doesn't have it yet
- iPhone + USB cable (USB-C/Lightning). Unlock + tap **Trust** when prompted.

> This Mac currently has **no Xcode / command-line tools**, so the project sources below
> are complete but have not been compiled here. Follow "Create the project" once Xcode is installed.

## Sources in `Sources/`

- `iPhonePhotoBackupApp.swift` — `@main` App entry
- `Models.swift` — `PhotoItem` + `BackupOrganizer` (Year/Month-Day + dedupe)
- `CameraManager.swift` — USB discovery, session, catalog flattening, thumbnails
- `ImportManager.swift` — sequential download queue straight to final folders
- `ContentView.swift` — device picker, backup-folder picker (external drives OK), grid, progress + log
- `iPhonePhotoBackup.entitlements` — sandbox + `user-selected.read-write` + `device.usb`

## Open and run (after installing Xcode)

1. Install Xcode from the App Store, open it once, then:
   ```bash
   sudo xcode-select --switch /Applications/Xcode.app
   xcodebuild -runFirstLaunch
   ```
2. Double-click `iPhonePhotoBackup.xcodeproj` in this folder.
3. Select target `iPhonePhotoBackup` → Signing & Capabilities → choose your Team (free Apple ID works for local run). Bundle ID `com.example.iPhonePhotoBackup` can stay or be renamed.
4. Press ⌘R. Connect iPhone via USB, unlock, tap Trust.

Entitlements (`Sources/iPhonePhotoBackup.entitlements`) and the `ImageCaptureCore.framework` link are already configured in the project.

## Use

1. Pick device (top-left, auto-selected).
2. **Choose backup folder…** — internal folder or external hard drive (e.g. `/Volumes/MyDrive/iPhoneBackup`). Remembered across launches via security-scoped bookmark.
3. Wait for catalog (`N items found`), thumbnails fill in.
4. Either tick photos → **Import selected**, or **Import all new** (skips existing automatically).
5. Watch progress + log at the bottom. Structure created: `YYYY/MM-dd/`.

## Troubleshooting

- `Could not open session / locked`: unlock iPhone, tap Trust, unplug/replug USB, wait 5s. Kill Apple's Image Capture if it grabbed the device.
- Empty catalog: wait for "complete content catalog" (large libraries take 10-30s), replug.
- External drive greyed out in picker: ensure it's mounted in Finder (`/Volumes/...`), format APFS/exFAT, and the app has Files permission (sandbox entitlement above).
- HEIC won't preview on old macOS: files still copy fine; open in Preview/Photos on Ventura+.
- Download error `-9928` etc.: cable issue — try another cable/port, keep iPhone awake (Settings → Display → Never during backup).

## Notes / limitations

- USB PTP only exposes the Camera Roll catalog — some custom Photos albums/smart folders aren't visible over USB (iOS limitation).
- Deletes are not offered (backup-only, safe).
- One download at a time (ImageCaptureCore is most reliable serially); byte-level progress isn't exposed, progress is per-file.
