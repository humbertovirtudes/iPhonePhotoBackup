// Reorganizer.swift – reorganize an existing backup folder by scheme.
//
// Scans <root> recursively, moves every file into the chosen layout
// (year / year-month / year-month-day / media-type / location),
// then deletes folders left empty. Supports dry-run previews.

import Foundation
import CoreLocation
import Combine

struct ReorganizeMove {
    let source: URL
    let destination: URL
}

/// Reverse-geocode + cache. Production path uses CLGeocoder (needs network);
/// tests inject `customLookup` so no network is touched.
final class PlaceResolver {
    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]
    private let lock = NSLock()
    var customLookup: ((Double, Double) -> String?)?

    /// Synchronous (call off the main thread). Rounds coordinates to ~1km so
    /// photos from the same spot share one lookup.
    func placeName(for coord: CLLocationCoordinate2D) -> String? {
        let key = String(format: "%.2f,%.2f", coord.latitude, coord.longitude)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let name: String?
        if let customLookup {
            name = customLookup(coord.latitude, coord.longitude)
        } else {
            name = reverseGeocode(coord)
        }
        if let name {
            lock.lock(); cache[key] = name; lock.unlock()
        }
        return name
    }

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) -> String? {
        var result: String?
        let sema = DispatchSemaphore(value: 0)
        geocoder.reverseGeocodeLocation(CLLocation(latitude: coord.latitude, longitude: coord.longitude)) { marks, _ in
            result = marks?.first.flatMap {
                $0.locality ?? $0.subAdministrativeArea ?? $0.administrativeArea ?? $0.country
            }
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 20)
        return result
    }
}

final class Reorganizer: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var statusLine = ""
    @Published var logLines: [String] = []

    private var cancelled = false
    var placeResolver = PlaceResolver()

    func cancel() {
        cancelled = true
    }

    struct Plan {
        var moves: [ReorganizeMove] = []
        var alreadyOrganized = 0
    }

    /// Scan + compute destinations without moving anything.
    func analyze(root: URL, scheme: OrganizationScheme) -> Plan {
        var plan = Plan()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return plan }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if url.lastPathComponent.hasPrefix(".") { continue }
            let date = MediaAnalyzer.captureDate(at: url) ?? Date.distantPast
            let stub = MoveStub(name: url.lastPathComponent, fileSize: 0, creationDate: date)
            let video = MediaType.isVideoFile(fileName: url.lastPathComponent)
            let place = scheme == .location ? placeName(forFileAt: url) : nil
            var dest = BackupOrganizer.destinationURL(for: stub, root: root, scheme: scheme, placeName: place, isVideo: video)
            if dest.standardizedFileURL == url.standardizedFileURL {
                plan.alreadyOrganized += 1
                continue
            }
            // Don't "move" onto an identical file; skip exact dupes at destination.
            if fm.fileExists(atPath: dest.path),
               let a = try? fm.attributesOfItem(atPath: url.path),
               let b = try? fm.attributesOfItem(atPath: dest.path),
               (a[.size] as? NSNumber)?.int64Value == (b[.size] as? NSNumber)?.int64Value {
                plan.alreadyOrganized += 1
                continue
            }
            if fm.fileExists(atPath: dest.path) {
                dest = BackupOrganizer.uniqueURL(for: dest)
            }
            plan.moves.append(ReorganizeMove(source: url, destination: dest))
        }
        return plan
    }

    func run(root: URL, scheme: OrganizationScheme, dryRun: Bool) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        cancelled = false
        logLines = []
        log(dryRun ? "Previewing reorganize of \(root.path) → \(scheme.title)…" : "Reorganizing \(root.path) → \(scheme.title)…")
        DispatchQueue.global(qos: .utility).async {
            let plan = self.analyze(root: root, scheme: scheme)
            let total = plan.moves.count
            var moved = 0, failed = 0
            if total == 0 {
                self.log("Nothing to move — \(plan.alreadyOrganized) file(s) already organized.")
            }
            for (i, m) in plan.moves.enumerated() {
                if self.cancelled { self.log("Cancelled."); break }
                DispatchQueue.main.async {
                    self.progress = Double(i) / Double(max(total, 1))
                    self.statusLine = m.source.lastPathComponent
                }
                if dryRun {
                    self.log("Would move: \(m.source.path) → \(m.destination.path)")
                    moved += 1
                    continue
                }
                do {
                    try FileManager.default.createDirectory(
                        at: m.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Re-check collision at move time (two sources → same target).
                    let dest = FileManager.default.fileExists(atPath: m.destination.path)
                        ? BackupOrganizer.uniqueURL(for: m.destination) : m.destination
                    try FileManager.default.moveItem(at: m.source, to: dest)
                    moved += 1
                } catch {
                    failed += 1
                    self.log("Failed \(m.source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            var pruned = 0
            if !dryRun && !self.cancelled {
                pruned = Self.pruneEmptyFolders(under: root)
            }
            DispatchQueue.main.async {
                self.progress = 1
                self.statusLine = ""
                self.isRunning = false
            }
            if dryRun {
                self.log("Preview done: \(total) file(s) would move, \(plan.alreadyOrganized) already organized.")
            } else {
                self.log("Done: moved \(moved), failed \(failed), \(plan.alreadyOrganized) already organized, removed \(pruned) empty folder(s).")
            }
        }
    }

    /// Removes empty subfolders deepest-first. Never removes `root` itself.
    @discardableResult
    static func pruneEmptyFolders(under root: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [.skipsHiddenFiles]) else { return 0 }
        var dirs: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            dirs.append(url)
        }
        var removed = 0
        for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            guard dir.standardizedFileURL != root.standardizedFileURL else { continue }
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? fm.removeItem(at: dir)
                removed += 1
            }
        }
        return removed
    }

    private func placeName(forFileAt url: URL) -> String? {
        guard let coord = MediaAnalyzer.gpsCoordinate(at: url) else { return nil }
        return placeResolver.placeName(for: coord)
    }

    private func log(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        DispatchQueue.main.async {
            self.logLines.append("[\(stamp)] \(line)")
            if self.logLines.count > 300 {
                self.logLines.removeFirst(self.logLines.count - 300)
            }
        }
    }
}

/// BackupSource-conforming stub for planning moves of on-disk files.
private struct MoveStub: BackupSource {
    var name: String
    var fileSize: Int64
    var creationDate: Date
}
