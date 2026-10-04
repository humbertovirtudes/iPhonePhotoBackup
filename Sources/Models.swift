// Models.swift – shared model types

import AppKit
import ImageCaptureCore

/// A single photo / video / Live Photo part on the iPhone, as exposed over USB (PTP).
struct PhotoItem: Identifiable, Hashable {
    let id: String          // stable id: deviceID + file path
    let file: ICCameraFile  // retained by CameraManager.items so it stays alive
    let name: String
    let fileSize: Int64
    let creationDate: Date
    let uti: String
    var thumbnail: NSImage?

    var isVideo: Bool {
        let l = uti.lowercased()
        if l.contains("movie") || l.contains("video") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mov", "mp4", "m4v"].contains(ext)
    }

    var displaySize: String {
        if fileSize <= 0 { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: fileSize)
    }

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Destination layout: <root>/YYYY/MM-dd/<filename>
enum BackupOrganizer {
    static func destinationURL(for item: PhotoItem, root: URL) -> URL {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: item.creationDate)
        let year = String(format: "%04d", comps.year ?? 1970)
        let folder = String(format: "%02d-%02d", comps.month ?? 1, comps.day ?? 1)
        return root
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(item.name)
    }

    /// If a file already exists at `url`, return a unique sibling (IMG_1.HEIC, IMG_2.HEIC…).
    /// Returns `url` itself when nothing exists there.
    static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 1
        while i < 10000 {
            let candidate = dir
                .appendingPathComponent("\(base)_\(i)")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
        return url
    }

    /// True when destination already holds an identical-size file (treat as already backed up).
    static func isDuplicate(item: PhotoItem, at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return false }
        return size.int64Value == item.fileSize
    }
}
