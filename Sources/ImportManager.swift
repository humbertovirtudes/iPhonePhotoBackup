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

    private var queue: [PhotoItem] = []
    private var totalCount = 0
    private var destinationRoot: URL?
    private var scheme: OrganizationScheme = .yearMonth
    private var cancelled = false

    func cancel() {
        cancelled = true
        log("Cancelled by user.")
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
        progress = 0
        importedCount = 0
        skippedCount = 0
        failedCount = 0
        log("Starting backup of \(items.count) item(s) to \(root.path)")
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

            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: dest.deletingLastPathComponent(),
                .saveAsFilename: dest.lastPathComponent,
                .overwrite: true,
                .sidecarFiles: true
            ]
            device.requestDownloadFile(
                item.file,
                options: options,
                downloadDelegate: self,
                didDownloadSelector: #selector(ImportManager.didDownloadFile(_:error:options:contextInfo:)),
                contextInfo: nil
            )
        }
    }

    @objc func didDownloadFile(
        _ file: ICCameraFile,
        error: Error?,
        options: [String: Any],
        contextInfo: UnsafeMutableRawPointer?
    ) {
        DispatchQueue.main.async {
            let name = file.name ?? "file"
            if let error {
                self.failedCount += 1
                self.log("Failed \(name): \(error.localizedDescription)")
            } else {
                self.importedCount += 1
                self.log("Backed up: \(name)")
            }
            let done = self.totalCount - self.queue.count
            self.progress = Double(done) / Double(max(self.totalCount, 1))
            self.downloadNext()
        }
    }

    private func finish() {
        DispatchQueue.main.async {
            self.isImporting = false
            self.progress = 1
            self.currentFileName = ""
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
