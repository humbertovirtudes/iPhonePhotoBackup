// ImportManager.swift – sequential USB download into Year/Month-Day folders
//
// Downloads straight to the final destination (external drive OK):
//   <root>/YYYY/MM-dd/IMG_1234.HEIC
// Skips files that already exist with the same size (already backed up).

import Foundation
import ImageCaptureCore
import Combine

final class ImportManager: NSObject, ObservableObject {
    @Published var isImporting = false
    @Published var progress: Double = 0
    @Published var currentFileName = ""
    @Published var logLines: [String] = []
    @Published var importedCount = 0
    @Published var skippedCount = 0
    @Published var failedCount = 0

    @Published var currentFileFraction: Double = 0
    @Published var currentFileDownloadedBytes: Int64 = 0
    @Published var currentFileTotalBytes: Int64 = 0

    private var queue: [PhotoItem] = []
    private var totalCount = 0
    private var destinationRoot: URL?
    private var scheme: OrganizationScheme = .yearMonth
    private var cancelled = false

    /// Guards against late callbacks from abandoned (stalled) downloads.
    private var activeFile: ICCameraFile?
    private var transferGeneration = 0
    private var watchdog: Timer?
    /// Seconds without progress/completion before a download is declared stalled.
    private let watchdogInterval: TimeInterval = 120
    /// Shorter grace before the first byte (a healthy transfer starts fast).
    private let watchdogFirstByteInterval: TimeInterval = 60
    private var seenProgress = false
    private var lastLoggedMilestone = 0
    private var lockObserver: NSObjectProtocol?
    /// Fallback progress source: the destination file grows as bytes land,
    /// even when the phone sends no progress callbacks at all.
    private var pollTimer: Timer?
    private var lastPolledSize: Int64 = -1
    private var loggedTempNames: Set<String> = []
    /// Keeps the Mac awake (no system sleep) for the whole import run.
    private var powerAssertion: NSObjectProtocol?
    private var activeItem: PhotoItem?
    private var activeDest: URL?
    private var downloadStartTime = Date()
    private var retriedCurrent = false

    func cancel() {
        cancelled = true
        stopTransferTimers()
        endPowerAssertion()
        activeFile = nil
        // Dismiss the overlay right away; any late download callback for
        // the abandoned file is ignored via the activeFile check.
        isImporting = false
        currentFileName = ""
        currentFileDownloadedBytes = 0
        currentFileTotalBytes = 0
        log("Cancelled by user.")
    }

    // MARK: - Device lock

    override init() {
        super.init()
        lockObserver = NotificationCenter.default.addObserver(
            forName: .cameraAccessRestricted, object: nil, queue: .main) { [weak self] _ in
                self?.handleDeviceLock()
            }
    }

    deinit {
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
    }

    /// The iPhone locked mid-transfer: fail the in-flight file fast instead
    /// of waiting out the watchdog, then keep the queue moving.
    private func handleDeviceLock() {
        guard isImporting, !cancelled, activeFile != nil else { return }
        abandonActiveFile(reason: "iPhone locked mid-download — unlock it, then retry.")
    }

    /// Gives up on the current file (stall or lock) and advances the queue.
    /// Late callbacks for it are ignored via the activeFile check.
    private func abandonActiveFile(reason: String) {
        activeFile = nil
        activeItem = nil
        activeDest = nil
        stopTransferTimers()
        failedCount += 1
        log(reason)
        let done = totalCount - queue.count
        progress = Double(done) / Double(max(totalCount, 1))
        downloadNext()
    }

    func importItems(_ items: [PhotoItem], to root: URL, scheme: OrganizationScheme = .yearMonth) {
        guard !isImporting else { return }
        guard !items.isEmpty else {
            log("Nothing to import.")
            return
        }
        queue = items
        totalCount = items.count
        destinationRoot = root
        self.scheme = scheme
        cancelled = false
        isImporting = true
        endPowerAssertion()
        powerAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Importing photos from iPhone")
        progress = 0
        importedCount = 0
        skippedCount = 0
        failedCount = 0
        log("Starting backup of \(items.count) item(s) to \(root.path)")
        log("delegate selectors: \(NSStringFromSelector(#selector(ImportManager.didDownloadFile(_:error:options:contextInfo:)))) / \(NSStringFromSelector(#selector(ImportManager.didReceiveDownloadProgress(for:downloadedBytes:maxBytes:))))")
        downloadNext()
    }

    // MARK: - Private

    private func downloadNext() {
        DispatchQueue.main.async {
            guard !self.cancelled else {
                self.finish()
                return
            }
            guard !self.queue.isEmpty, let root = self.destinationRoot else {
                self.finish()
                return
            }
            let item = self.queue.removeFirst()
            let done = self.totalCount - self.queue.count
            self.progress = Double(done - 1) / Double(max(self.totalCount, 1))
            self.currentFileName = item.name
            self.currentFileFraction = 0
            self.currentFileDownloadedBytes = 0
            self.currentFileTotalBytes = item.fileSize
            self.retriedCurrent = false
            self.stopTransferTimers()

            // Resolve final destination (Year/Month by default).
            var dest = BackupOrganizer.destinationURL(for: item, root: root, scheme: self.scheme, isVideo: item.isVideo)

            // Skip exact duplicates (same name + same byte size).
            if BackupOrganizer.isDuplicate(item: item, at: dest) {
                self.skippedCount += 1
                self.log("Skipped (already backed up): \(dest.path)")
                self.downloadNext()
                return
            }
            // Same name but different content → keep both with _1, _2 suffix.
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = BackupOrganizer.uniqueURL(for: dest)
            }

            do {
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                self.failedCount += 1
                self.log("Failed to create folder: \(error.localizedDescription)")
                self.downloadNext()
                return
            }

            guard let device = item.file.device else {
                self.failedCount += 1
                self.log("Failed (no device): \(item.name)")
                self.downloadNext()
                return
            }

            self.startDownload(item: item, dest: dest, device: device)
        }
    }

    /// Issues one download request (initial attempt or single retry).
    private func startDownload(item: PhotoItem, dest: URL, device: ICCameraDevice) {
        DispatchQueue.main.async {
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: dest.deletingLastPathComponent(),
                .saveAsFilename: dest.lastPathComponent,
                .overwrite: true,
                .sidecarFiles: true
            ]
            self.activeFile = item.file
            self.activeItem = item
            self.activeDest = dest
            self.transferGeneration += 1
            self.seenProgress = false
            self.lastLoggedMilestone = 0
            self.lastPolledSize = -1
            self.loggedTempNames = []
            self.downloadStartTime = Date()
            let sizeString: String = {
                let f = ByteCountFormatter()
                f.countStyle = .file
                return f.string(fromByteCount: item.fileSize)
            }()
            self.log("Downloading \(item.name) (\(sizeString)) → \(dest.path)")
            device.requestDownloadFile(
                item.file,
                options: options,
                downloadDelegate: self,
                didDownloadSelector: #selector(ImportManager.didDownloadFile(_:error:options:contextInfo:)),
                contextInfo: nil
            )
            self.startWatchdog(generation: self.transferGeneration, fileName: item.name)
            self.startPoll()
        }
    }

    /// Re-issues the in-flight request once; returns false when the single
    /// retry was already used (caller should fail the file).
    private func retryActiveDownload() -> Bool {
        guard !retriedCurrent,
              let item = activeItem,
              let dest = activeDest,
              let device = item.file.device else { return false }
        retriedCurrent = true
        log("Retrying: \(item.name)")
        startDownload(item: item, dest: dest, device: device)
        return true
    }

    // MARK: - Stall watchdog

    private func startWatchdog(generation: Int, fileName: String) {
        stopWatchdog()
        // Tighter grace before the first byte; once bytes flow, allow gaps.
        let interval = seenProgress ? watchdogInterval : watchdogFirstByteInterval
        watchdog = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.transferGeneration == generation, self.isImporting, !self.cancelled else { return }
            if self.retryActiveDownload() {
                // Retry gets its own full grace period (new watchdog inside).
            } else {
                self.abandonActiveFile(reason: "Stalled (no progress for \(Int(interval))s, retry used), skipping: \(fileName). Replug USB if this repeats.")
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func stopTransferTimers() {
        stopWatchdog()
        stopPoll()
    }

    /// Watches the destination file itself grow. Works even when the phone
    /// sends no progress callbacks: any growth resets the stall watchdog,
    /// and the byte counter in the UI follows the real file size.
    private func startPoll() {
        stopPoll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollDownload()
        }
    }

    private func stopPoll() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func endPowerAssertion() {
        if let a = powerAssertion {
            ProcessInfo.processInfo.endActivity(a)
            powerAssertion = nil
        }
    }

    private func pollDownload() {
        guard isImporting, !cancelled,
              activeFile != nil, let dest = activeDest else {
            stopPoll()
            return
        }
        // Bytes may land in the final file, a hidden temp file, or sidecars —
        // count everything in the folder written since this transfer started.
        let (bytes, temps) = Self.inFlightBytes(
            in: dest.deletingLastPathComponent(),
            destName: dest.lastPathComponent,
            since: downloadStartTime)
        for t in temps where !loggedTempNames.contains(t) {
            loggedTempNames.insert(t)
            log("Buffering via \(t)…")
        }
        guard bytes != lastPolledSize else { return } // no growth; watchdog decides stalls
        lastPolledSize = bytes
        currentFileDownloadedBytes = bytes
        let total = max(currentFileTotalBytes, 1)
        currentFileFraction = min(1, Double(bytes) / Double(total))
        let done = totalCount - queue.count
        progress = (Double(done - 1) + currentFileFraction) / Double(max(totalCount, 1))
        startWatchdog(generation: transferGeneration, fileName: activeFile?.name ?? "file")
    }

    /// Bytes attributable to the in-flight transfer: the destination file
    /// itself plus hidden temp files and sidecars written since `since`.
    /// Older unrelated files in the same folder are ignored.
    static func inFlightBytes(in dir: URL, destName: String, since: Date) -> (bytes: Int64, tempNames: [String]) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return (0, []) }
        var bytes: Int64 = 0
        var temps: [String] = []
        for n in items {
            let u = dir.appendingPathComponent(n)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
                  let size = attrs[.size] as? NSNumber else { continue }
            if n == destName {
                bytes += size.int64Value
                continue
            }
            let mod = attrs[.modificationDate] as? Date
            guard n.hasPrefix(".") || (mod.map { $0 >= since } ?? false) else { continue }
            bytes += size.int64Value
            temps.append(n)
        }
        return (bytes, temps)
    }

    @objc func didDownloadFile(
        _ file: ICCameraFile,
        error: Error?,
        options: [String: Any],
        contextInfo: UnsafeMutableRawPointer?
    ) {
        DispatchQueue.main.async {
            // Ignore late callbacks from downloads abandoned by the watchdog.
            guard file === self.activeFile else { return }
            self.activeFile = nil
            self.stopTransferTimers()
            let name = file.name ?? "file"
            let elapsed = Date().timeIntervalSince(self.downloadStartTime)
            let elapsedString = String(format: "%.1fs", elapsed)
            if let error {
                self.failActiveFile("Failed \(name) (\(elapsedString)): \(error.localizedDescription)")
                return
            }
            // Verify the landed file: catches partial/corrupt transfers.
            if let dest = self.activeDest,
               let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size]) as? NSNumber,
               size.int64Value == Int64(file.fileSize) {
                self.activeItem = nil
                self.activeDest = nil
                self.importedCount += 1
                self.log("Backed up: \(name) (\(elapsedString))")
                let done = self.totalCount - self.queue.count
                self.progress = Double(done) / Double(max(self.totalCount, 1))
                self.downloadNext()
            } else if self.retryActiveDownload() {
                // Single retry re-issued; its completion continues the queue.
            } else {
                self.failActiveFile("Failed \(name): downloaded file missing or wrong size after retry.")
            }
        }
    }

    private func failActiveFile(_ message: String) {
        activeItem = nil
        activeDest = nil
        failedCount += 1
        log(message)
        let done = totalCount - queue.count
        progress = Double(done) / Double(max(totalCount, 1))
        downloadNext()
    }

    // Note: off_t imports as Int64 (not Int) — using Int here compiles but
    // silently never matches the protocol witness, so progress is never called.
    func didReceiveDownloadProgress(for file: ICCameraFile, downloadedBytes: Int64, maxBytes: Int64) {
        DispatchQueue.main.async {
            guard file === self.activeFile, maxBytes > 0 else { return }
            self.seenProgress = true
            self.currentFileDownloadedBytes = downloadedBytes
            self.currentFileTotalBytes = maxBytes
            self.currentFileFraction = min(1, Double(downloadedBytes) / Double(maxBytes))
            let done = self.totalCount - self.queue.count
            self.progress = (Double(done - 1) + self.currentFileFraction) / Double(max(self.totalCount, 1))
            let pct = Int(self.currentFileFraction * 100)
            if pct >= self.lastLoggedMilestone + 25 {
                self.lastLoggedMilestone = pct - (pct % 25)
                let f = ByteCountFormatter()
                f.countStyle = .file
                self.log("\(file.name ?? "file"): \(pct)% (\(f.string(fromByteCount: Int64(downloadedBytes))) of \(f.string(fromByteCount: Int64(maxBytes)))")
            }
            // Any sign of life resets the stall watchdog.
            self.startWatchdog(generation: self.transferGeneration, fileName: file.name ?? "file")
        }
    }

    private func finish() {
        DispatchQueue.main.async {
            self.endPowerAssertion()
            // A fresh import may already be running after a cancel; only
            // summarize the run that actually completed.
            guard !self.cancelled else {
                self.isImporting = false
                return
            }
            self.isImporting = false
            self.progress = 1
            self.currentFileName = ""
            self.currentFileDownloadedBytes = 0
            self.currentFileTotalBytes = 0
            self.log("Done. Imported: \(self.importedCount), skipped: \(self.skippedCount), failed: \(self.failedCount).")
        }
    }

    private func log(_ line: String) {
        DispatchQueue.main.async {
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.logLines.append("[\(stamp)] \(line)")
            if self.logLines.count > 300 {
                self.logLines.removeFirst(self.logLines.count - 300)
            }
        }
    }
}

// ICCameraDeviceDownloadDelegate conformance (methods are @objc-optional,
// implemented above). Declared explicitly so the selector dispatch works.
extension ImportManager: ICCameraDeviceDownloadDelegate {}

extension Notification.Name {
    /// Posted when the iPhone locks mid-session (media access revoked).
    static let cameraAccessRestricted = Notification.Name("cameraAccessRestricted")
}
