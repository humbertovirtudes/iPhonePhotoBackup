// Models.swift – shared model types, organization schemes, duplicate detection

import AppKit
import ImageCaptureCore
import ImageIO
import CoreLocation

/// Minimal description of something that can be backed up.
/// PhotoItem conforms; tests use a lightweight stub so no camera is needed.
protocol BackupSource {
    var name: String { get }
    var fileSize: Int64 { get }
    var creationDate: Date { get }
}

/// How backed-up files are laid out under the backup root.
enum OrganizationScheme: String, CaseIterable, Identifiable {
    case photosVideos  // <root>/Photos|Videos/<file> (reorganize default)
    case year          // <root>/2026/<file>
    case yearMonth     // <root>/2026/10/<file>  (import default)
    case yearMonthDay  // <root>/2026/10-04/<file> (legacy layout)
    case mediaType     // <root>/Photos|Videos/2026/10/<file>
    case location      // <root>/<Place>/2026/10/<file>

    var id: String { rawValue }

    /// Schemes offered for USB import (fast, offline — no network lookups).
    /// Location grouping lives in the Reorganize tool instead.
    static var importCases: [OrganizationScheme] {
        [.year, .yearMonth, .yearMonthDay, .photosVideos, .mediaType]
    }

    var title: String {
        switch self {
        case .photosVideos: return "Photos / Videos"
        case .year: return "Year"
        case .yearMonth: return "Year / Month"
        case .yearMonthDay: return "Year / Month-Day"
        case .mediaType: return "Photos / Videos + Date"
        case .location: return "Location"
        }
    }

    var example: String {
        switch self {
        case .photosVideos: return "Backup/Photos/IMG_1.HEIC"
        case .year: return "Backup/2026/IMG_1.HEIC"
        case .yearMonth: return "Backup/2026/10/IMG_1.HEIC"
        case .yearMonthDay: return "Backup/2026/10-04/IMG_1.HEIC"
        case .mediaType: return "Backup/Photos/2026/10/IMG_1.HEIC"
        case .location: return "Backup/Lisbon/2026/10/IMG_1.HEIC"
        }
    }
}

/// Filename/UTI-based media classification (single place both app and tests use).
enum MediaType {
    static func isVideo(uti: String, fileName: String) -> Bool {
        let l = uti.lowercased()
        if l.contains("movie") || l.contains("video") { return true }
        // iPhone .mp4 files report public.mpeg-4 over USB; exclude mpeg audio.
        if l.contains("mpeg") && !l.contains("audio") { return true }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["mov", "mp4", "m4v"].contains(ext)
    }

    /// Extension-based check for files already on disk (no UTI available).
    static func isVideoFile(fileName: String) -> Bool {
        isVideo(uti: "", fileName: fileName)
    }
}

/// A single photo / video / Live Photo part on the iPhone, as exposed over USB (PTP).
struct PhotoItem: Identifiable, Hashable, BackupSource {
    let id: String          // stable id: deviceID + file path
    let file: ICCameraFile  // retained by CameraManager.items so it stays alive
    let name: String
    let fileSize: Int64
    let creationDate: Date
    let uti: String
    var thumbnail: NSImage?

    var isVideo: Bool {
        MediaType.isVideo(uti: uti, fileName: name)
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

// MARK: - Reading metadata of files already on disk

/// What we know about a file already sitting in the backup folder.
struct LocalFileInfo {
    var exists: Bool
    var size: Int64
    /// When the photo was taken, from EXIF if readable, else nil.
    var captureDate: Date?
}

enum MediaAnalyzer {
    /// Best-effort capture date: EXIF DateTimeOriginal for images,
    /// otherwise the file's creation date, otherwise modification date.
    static func captureDate(at url: URL) -> Date? {
        if let exif = exifCaptureDate(at: url) { return exif }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
    }

    /// EXIF DateTimeOriginal (plus sub-seconds) for image files; nil for videos/unreadable.
    static func exifCaptureDate(at url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return exifCaptureDate(fromProperties: props as [AnyHashable: Any])
    }

    /// Pure helper so tests don't need real image files.
    static func exifCaptureDate(fromProperties props: [AnyHashable: Any]) -> Date? {
        let exif = props[kCGImagePropertyExifDictionary] as? [AnyHashable: Any]
        guard let raw = exif?[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        // Note: "SubSecTimeOriginal" as a literal — the typed constant is
        // missing from some SDKs, and EXIF dictionaries key by string value.
        return parseEXIFDate(raw, subSecond: exif?["SubSecTimeOriginal" as CFString] as? String)
    }

    /// Parses "2026:10:04 12:34:56" (+ optional fractional seconds).
    static func parseEXIFDate(_ s: String, subSecond: String? = nil) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        guard let base = f.date(from: s) else { return nil }
        if let subSecond, let frac = Double("0." + subSecond) {
            return base.addingTimeInterval(frac)
        }
        return base
    }

    /// GPS coordinate from EXIF, honoring N/S/E/W refs; nil when absent.
    static func gpsCoordinate(at url: URL) -> CLLocationCoordinate2D? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return gpsCoordinate(fromProperties: props as [AnyHashable: Any])
    }

    /// Pure helper so tests don't need real image files.
    static func gpsCoordinate(fromProperties props: [AnyHashable: Any]) -> CLLocationCoordinate2D? {
        guard let gps = props[kCGImagePropertyGPSDictionary] as? [AnyHashable: Any],
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N").uppercased()
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E").uppercased()
        return CLLocationCoordinate2D(
            latitude: latRef == "S" ? -lat : lat,
            longitude: lonRef == "W" ? -lon : lon)
    }

    /// Filesystem-safe folder name (strips / : and control chars).
    static func sanitizeFolderName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = s.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Unknown" : cleaned
    }

    static func localInfo(at url: URL) -> LocalFileInfo {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return LocalFileInfo(exists: false, size: 0, captureDate: nil)
        }
        return LocalFileInfo(exists: true, size: size.int64Value, captureDate: exifCaptureDate(at: url))
    }
}

// MARK: - Duplicate detection (name + size + capture metadata)

enum DuplicateChecker {
    /// Same name (structural, via URL) + same byte size + same capture day
    /// (EXIF when readable). Falls back to name+size when no EXIF is available
    /// (videos, sidecars). Never calls two different photos a duplicate:
    /// same name+size but different capture day → not a duplicate.
    static func isDuplicate(sourceName: String, sourceSize: Int64, sourceDate: Date, local: LocalFileInfo) -> Bool {
        guard local.exists else { return false }
        guard local.size == sourceSize else { return false }
        guard let localDate = local.captureDate else { return true } // name+size fallback
        return Calendar.current.isDate(localDate, inSameDayAs: sourceDate)
    }
}

/// Destination layout + dedupe helpers.
enum BackupOrganizer {
    static func destinationURL(for item: any BackupSource, root: URL) -> URL {
        destinationURL(for: item, root: root, scheme: .photosVideos, placeName: nil, isVideo: nil)
    }

    static func destinationURL(for item: any BackupSource, root: URL,
                              scheme: OrganizationScheme, placeName: String? = nil,
                              isVideo: Bool? = nil) -> URL {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: item.creationDate)
        let year = String(format: "%04d", comps.year ?? 1970)
        var url = root
        switch scheme {
        case .photosVideos:
            let video = isVideo ?? MediaType.isVideo(uti: "", fileName: item.name)
            url.appendPathComponent(video ? "Videos" : "Photos", isDirectory: true)
        case .year:
            url.appendPathComponent(year, isDirectory: true)
        case .yearMonth:
            url.appendPathComponent(year, isDirectory: true)
            url.appendPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
        case .yearMonthDay:
            url.appendPathComponent(year, isDirectory: true)
            url.appendPathComponent(String(format: "%02d-%02d", comps.month ?? 1, comps.day ?? 1), isDirectory: true)
        case .mediaType:
            let video = isVideo ?? MediaType.isVideo(uti: "", fileName: item.name)
            url.appendPathComponent(video ? "Videos" : "Photos", isDirectory: true)
            url.appendPathComponent(year, isDirectory: true)
            url.appendPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
        case .location:
            url.appendPathComponent(MediaAnalyzer.sanitizeFolderName(placeName ?? "Unknown location"), isDirectory: true)
            url.appendPathComponent(year, isDirectory: true)
            url.appendPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
        }
        return url.appendingPathComponent(item.name)
    }

    /// How many of `items` are not yet backed up under `root`
    /// (missing, different size, or different capture day).
    static func newItemCount<S: BackupSource>(_ items: [S], root: URL, scheme: OrganizationScheme) -> Int {
        var n = 0
        for item in items {
            let dest = destinationURL(for: item, root: root, scheme: scheme)
            if !isDuplicate(item: item, at: dest) { n += 1 }
        }
        return n
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

    /// True when destination already holds the same photo: same name, same size,
    /// same capture day (EXIF-verified when readable).
    static func isDuplicate(item: any BackupSource, at url: URL) -> Bool {
        guard url.lastPathComponent == item.name else { return false }
        let local = MediaAnalyzer.localInfo(at: url)
        return DuplicateChecker.isDuplicate(
            sourceName: item.name, sourceSize: item.fileSize,
            sourceDate: item.creationDate, local: local)
    }
}
