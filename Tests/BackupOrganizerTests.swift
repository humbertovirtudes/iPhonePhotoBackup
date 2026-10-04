// BackupOrganizerTests.swift – locks in the backup folder rules:
//   <root>/YYYY/MM/<original filename> by default, dedupe by name + size +
//   capture date, _1/_2 suffixes on genuine collisions.

import XCTest
import ImageIO
@testable import iPhonePhotoBackup

/// Test stub: no camera needed.
struct Fixture: BackupSource {
    var name: String
    var fileSize: Int64
    var creationDate: Date
}

func fixtureDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d
    c.hour = 12 // noon avoids DST-boundary surprises
    return Calendar.current.date(from: c)!
}

func writeBytes(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0xAB, count: bytes).write(to: url)
}

/// 1x1 JPEG with optional EXIF (capture date and/or GPS).
func writeJPEG(_ url: URL, exifDate: String? = nil, gps: [String: Any]? = nil) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img = ctx.makeImage()!
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
        throw NSError(domain: "test", code: 1)
    }
    var props: [CFString: Any] = [:]
    var exif: [CFString: Any] = [:]
    if let exifDate { exif[kCGImagePropertyExifDateTimeOriginal] = exifDate }
    if !exif.isEmpty { props[kCGImagePropertyExifDictionary] = exif }
    if let gps {
        var g: [CFString: Any] = [:]
        for (k, v) in gps { g[k as CFString] = v }
        props[kCGImagePropertyGPSDictionary] = g
    }
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
}

final class BackupOrganizerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - destinationURL (default: year/month)

    func testDestinationUsesYearMonthFoldersAndKeepsFilename() {
        let item = Fixture(name: "IMG_1234.HEIC", fileSize: 1_000, creationDate: fixtureDate(2026, 10, 4))
        let dest = BackupOrganizer.destinationURL(for: item, root: root)
        XCTAssertEqual(dest.path, root.appendingPathComponent("2026/10/IMG_1234.HEIC").path)
    }

    func testDestinationZeroPadsMonth() {
        let item = Fixture(name: "P.mov", fileSize: 1, creationDate: fixtureDate(2025, 3, 7))
        let dest = BackupOrganizer.destinationURL(for: item, root: root)
        XCTAssertTrue(dest.path.hasSuffix("2025/03/P.mov"), dest.path)
    }

    func testYearScheme() {
        let item = Fixture(name: "A.JPG", fileSize: 1, creationDate: fixtureDate(2024, 1, 2))
        let dest = BackupOrganizer.destinationURL(for: item, root: root, scheme: .year)
        XCTAssertTrue(dest.path.hasSuffix("2024/A.JPG"), dest.path)
    }

    func testYearMonthDaySchemeIsLegacyLayout() {
        let item = Fixture(name: "A.JPG", fileSize: 1, creationDate: fixtureDate(2026, 10, 4))
        let dest = BackupOrganizer.destinationURL(for: item, root: root, scheme: .yearMonthDay)
        XCTAssertTrue(dest.path.hasSuffix("2026/10-04/A.JPG"), dest.path)
    }

    func testMediaTypeSchemeSplitsPhotosAndVideos() {
        let photo = Fixture(name: "A.HEIC", fileSize: 1, creationDate: fixtureDate(2026, 10, 4))
        let video = Fixture(name: "B.MOV", fileSize: 1, creationDate: fixtureDate(2026, 10, 4))
        XCTAssertTrue(BackupOrganizer.destinationURL(for: photo, root: root, scheme: .mediaType, isVideo: false).path.contains("/Photos/2026/10/"))
        XCTAssertTrue(BackupOrganizer.destinationURL(for: video, root: root, scheme: .mediaType, isVideo: true).path.contains("/Videos/2026/10/"))
    }

    func testLocationSchemeUsesPlaceName() {
        let item = Fixture(name: "A.HEIC", fileSize: 1, creationDate: fixtureDate(2026, 10, 4))
        let dest = BackupOrganizer.destinationURL(for: item, root: root, scheme: .location, placeName: "Lisbon")
        XCTAssertTrue(dest.path.hasSuffix("Lisbon/2026/10/A.HEIC"), dest.path)
    }

    func testLocationSchemeFallsBackWithoutPlace() {
        let item = Fixture(name: "A.HEIC", fileSize: 1, creationDate: fixtureDate(2026, 10, 4))
        let dest = BackupOrganizer.destinationURL(for: item, root: root, scheme: .location)
        XCTAssertTrue(dest.path.contains("Unknown location/2026/10/"), dest.path)
    }

    // MARK: - isDuplicate (name + size + capture date)

    func testMissingFileIsNotDuplicate() {
        let item = Fixture(name: "A.HEIC", fileSize: 100, creationDate: .now)
        XCTAssertFalse(BackupOrganizer.isDuplicate(item: item, at: root.appendingPathComponent("A.HEIC")))
    }

    func testSameSizeFileWithoutEXIFFallsBackToDuplicate() throws {
        let item = Fixture(name: "B.HEIC", fileSize: 512, creationDate: .now)
        let url = root.appendingPathComponent("B.HEIC")
        try writeBytes(url, bytes: 512)
        XCTAssertTrue(BackupOrganizer.isDuplicate(item: item, at: url))
    }

    func testDifferentSizeFileIsNotDuplicate() throws {
        let item = Fixture(name: "C.HEIC", fileSize: 512, creationDate: .now)
        let url = root.appendingPathComponent("C.HEIC")
        try writeBytes(url, bytes: 100)
        XCTAssertFalse(BackupOrganizer.isDuplicate(item: item, at: url))
    }

    func testSameNameSizeButDifferentCaptureDayIsNotDuplicate() throws {
        // Local file "taken" Oct 4, incoming file from Oct 5 → keep both.
        let url = root.appendingPathComponent("D.JPG")
        try writeJPEG(url, exifDate: "2026:10:04 12:00:00")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
        let incoming = Fixture(name: "D.JPG", fileSize: size, creationDate: fixtureDate(2026, 10, 5))
        XCTAssertFalse(BackupOrganizer.isDuplicate(item: incoming, at: url))
    }

    func testSameNameSizeAndCaptureDayIsDuplicate() throws {
        let url = root.appendingPathComponent("E.JPG")
        try writeJPEG(url, exifDate: "2026:10:04 12:00:00")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
        let incoming = Fixture(name: "E.JPG", fileSize: size, creationDate: fixtureDate(2026, 10, 4))
        XCTAssertTrue(BackupOrganizer.isDuplicate(item: incoming, at: url))
    }

    func testDifferentFilenameIsNotDuplicate() throws {
        let url = root.appendingPathComponent("F_1.HEIC")
        try writeBytes(url, bytes: 50)
        let item = Fixture(name: "F.HEIC", fileSize: 50, creationDate: .now)
        XCTAssertFalse(BackupOrganizer.isDuplicate(item: item, at: url))
    }

    // MARK: - uniqueURL (same name, different content → keep both)

    func testUniqueURLReturnsOriginalWhenFree() {
        let url = root.appendingPathComponent("G.HEIC")
        XCTAssertEqual(BackupOrganizer.uniqueURL(for: url), url)
    }

    func testUniqueURLAppendsCounterAndKeepsExtension() throws {
        let url = root.appendingPathComponent("IMG_9.HEIC")
        try writeBytes(url, bytes: 10)
        try writeBytes(root.appendingPathComponent("IMG_9_1.HEIC"), bytes: 20)
        let unique = BackupOrganizer.uniqueURL(for: url)
        XCTAssertEqual(unique.lastPathComponent, "IMG_9_2.HEIC")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unique.path))
    }

    // MARK: - newItemCount

    func testNewItemCount() throws {
        let old = Fixture(name: "H.HEIC", fileSize: 30, creationDate: fixtureDate(2026, 10, 1))
        let dest = BackupOrganizer.destinationURL(for: old, root: root)
        try writeBytes(dest, bytes: 30) // already backed up (no EXIF → size fallback)
        let fresh = Fixture(name: "I.HEIC", fileSize: 40, creationDate: fixtureDate(2026, 10, 2))
        XCTAssertEqual(BackupOrganizer.newItemCount([old, fresh], root: root, scheme: .yearMonth), 1)
    }
}
