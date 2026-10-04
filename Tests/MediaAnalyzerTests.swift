// MediaAnalyzerTests.swift – locks in EXIF date/GPS parsing and folder sanitizing.

import XCTest
import ImageIO
@testable import iPhonePhotoBackup

final class MediaAnalyzerTests: XCTestCase {
    func testParseEXIFDate() {
        let d = MediaAnalyzer.parseEXIFDate("2026:10:04 12:34:56")
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 10)
        XCTAssertEqual(comps.day, 4)
        XCTAssertEqual(comps.hour, 12)
        XCTAssertEqual(comps.minute, 34)
        XCTAssertEqual(comps.second, 56)
    }

    func testParseEXIFDateWithSubseconds() {
        let a = MediaAnalyzer.parseEXIFDate("2026:10:04 12:00:00")!
        let b = MediaAnalyzer.parseEXIFDate("2026:10:04 12:00:00", subSecond: "500")!
        XCTAssertEqual(b.timeIntervalSince(a), 0.5, accuracy: 0.001)
    }

    func testParseEXIFDateRejectsGarbage() {
        XCTAssertNil(MediaAnalyzer.parseEXIFDate("not a date"))
        XCTAssertNil(MediaAnalyzer.parseEXIFDate("2026-10-04"))
    }

    func testExifCaptureDateFromProperties() {
        let props: [AnyHashable: Any] = [
            kCGImagePropertyExifDictionary as AnyHashable: [
                kCGImagePropertyExifDateTimeOriginal as AnyHashable: "2025:03:07 08:00:00"
            ] as [AnyHashable: Any]
        ]
        let d = MediaAnalyzer.exifCaptureDate(fromProperties: props)!
        XCTAssertEqual(Calendar.current.component(.year, from: d), 2025)
        XCTAssertEqual(Calendar.current.component(.month, from: d), 3)
    }

    func testExifCaptureDateMissingIsNil() {
        XCTAssertNil(MediaAnalyzer.exifCaptureDate(fromProperties: [:]))
    }

    func testGPSCoordinateNorthEast() {
        let props: [AnyHashable: Any] = [kCGImagePropertyGPSDictionary as AnyHashable: [
            kCGImagePropertyGPSLatitude as AnyHashable: 38.71,
            kCGImagePropertyGPSLatitudeRef as AnyHashable: "N",
            kCGImagePropertyGPSLongitude as AnyHashable: 9.13,
            kCGImagePropertyGPSLongitudeRef as AnyHashable: "W",
        ] as [AnyHashable: Any]]
        let c = MediaAnalyzer.gpsCoordinate(fromProperties: props)!
        XCTAssertEqual(c.latitude, 38.71, accuracy: 0.001)
        XCTAssertEqual(c.longitude, -9.13, accuracy: 0.001)
    }

    func testGPSCoordinateSouthWestSigns() {
        let props: [AnyHashable: Any] = [kCGImagePropertyGPSDictionary as AnyHashable: [
            kCGImagePropertyGPSLatitude as AnyHashable: 33.86,
            kCGImagePropertyGPSLatitudeRef as AnyHashable: "S",
            kCGImagePropertyGPSLongitude as AnyHashable: 151.20,
            kCGImagePropertyGPSLongitudeRef as AnyHashable: "E",
        ] as [AnyHashable: Any]]
        let c = MediaAnalyzer.gpsCoordinate(fromProperties: props)!
        XCTAssertEqual(c.latitude, -33.86, accuracy: 0.001)
        XCTAssertEqual(c.longitude, 151.20, accuracy: 0.001)
    }

    func testGPSCoordinateMissingIsNil() {
        XCTAssertNil(MediaAnalyzer.gpsCoordinate(fromProperties: [:]))
    }

    func testSanitizeFolderName() {
        XCTAssertEqual(MediaAnalyzer.sanitizeFolderName("New/York"), "New-York")
        XCTAssertEqual(MediaAnalyzer.sanitizeFolderName("São Paulo: Sé"), "São Paulo- Sé")
        XCTAssertEqual(MediaAnalyzer.sanitizeFolderName("  "), "Unknown")
    }

    func testCaptureDateFallsBackToFileDates() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("plain.bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
        let known = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: known, .modificationDate: known], ofItemAtPath: url.path)
        let got = MediaAnalyzer.captureDate(at: url)!
        XCTAssertEqual(got.timeIntervalSince1970, known.timeIntervalSince1970, accuracy: 2)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
