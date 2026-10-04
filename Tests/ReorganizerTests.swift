// ReorganizerTests.swift – locks in folder reorganization:
// scan → move by scheme → prune empty folders, with dry-run previews.

import XCTest
@testable import iPhonePhotoBackup

final class ReorganizerTests: XCTestCase {
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

    private func seed(path: String, bytes: Int, date: Date) throws -> URL {
        let url = root.appendingPathComponent(path)
        try writeBytes(url, bytes: bytes)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    private func runAndWait(_ r: Reorganizer, scheme: OrganizationScheme, dryRun: Bool) {
        r.run(root: root, scheme: scheme, dryRun: dryRun)
        let exp = expectation(for: NSPredicate(block: { obj, _ in !(obj as! Reorganizer).isRunning }),
                              evaluatedWith: r, handler: nil)
        waitForExpectations(timeout: 15)
    }

    // MARK: - Planning

    func testAnalyzeGroupsByYearMonthUsingFileDates() throws {
        try seed(path: "inbox/a.HEIC", bytes: 10, date: fixtureDate(2026, 10, 4))
        try seed(path: "inbox/b.HEIC", bytes: 10, date: fixtureDate(2025, 3, 7))
        let plan = Reorganizer().analyze(root: root, scheme: .yearMonth)
        XCTAssertEqual(plan.moves.count, 2)
        XCTAssertEqual(plan.alreadyOrganized, 0)
        let dests = Set(plan.moves.map { $0.destination.lastPathComponent })
        XCTAssertEqual(dests, ["a.HEIC", "b.HEIC"])
        XCTAssertTrue(plan.moves.contains { $0.destination.path.hasSuffix("2026/10/a.HEIC") })
        XCTAssertTrue(plan.moves.contains { $0.destination.path.hasSuffix("2025/03/b.HEIC") })
    }

    func testAnalyzeSkipsAlreadyOrganized() throws {
        try seed(path: "2026/10/a.HEIC", bytes: 10, date: fixtureDate(2026, 10, 4))
        let plan = Reorganizer().analyze(root: root, scheme: .yearMonth)
        XCTAssertEqual(plan.moves.count, 0)
        XCTAssertEqual(plan.alreadyOrganized, 1)
    }

    func testAnalyzeReportsScanProgress() throws {
        for i in 0..<12 {
            try seed(path: "inbox/f\(i).HEIC", bytes: 10, date: fixtureDate(2026, 10, 4))
        }
        var calls = 0
        var lastSeen = 0
        _ = Reorganizer().analyze(root: root, scheme: .yearMonth) { seen, _ in
            calls += 1
            lastSeen = seen
        }
        XCTAssertGreaterThan(calls, 0, "scan should report progress, not sit silent")
        XCTAssertEqual(lastSeen, 10, "callback fires every 5 files")
    }

    // MARK: - Running

    func testRunMovesFilesAndPrunesEmptyFolders() throws {
        try seed(path: "old-layout/2026/10-04/a.HEIC", bytes: 10, date: fixtureDate(2026, 10, 4))
        try seed(path: "old-layout/b.MOV", bytes: 20, date: fixtureDate(2024, 5, 6))
        let r = Reorganizer()
        runAndWait(r, scheme: .yearMonth, dryRun: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026/10/a.HEIC").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2024/05/b.MOV").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("old-layout").path),
                       "empty source folders should be removed")
    }

    func testDryRunChangesNothing() throws {
        try seed(path: "mess/a.HEIC", bytes: 10, date: fixtureDate(2026, 10, 4))
        let r = Reorganizer()
        runAndWait(r, scheme: .year, dryRun: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("mess/a.HEIC").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026/a.HEIC").path))
        XCTAssertTrue(r.logLines.joined().contains("Preview done"))
    }

    func testPruneKeepsNonEmptyFolders() throws {
        try seed(path: "keep/a.HEIC", bytes: 10, date: fixtureDate(2026, 10, 4))
        try seed(path: "keep/sub/b.HEIC", bytes: 10, date: fixtureDate(2026, 10, 4))
        let r = Reorganizer()
        runAndWait(r, scheme: .year, dryRun: false)
        // Both land in 2026/, so keep/ and keep/sub/ empty out and vanish…
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026/a.HEIC").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026/b.HEIC").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep").path))
        // …but root itself is never deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - Location scheme

    func testLocationSchemeUsesResolverAndCaches() throws {
        let gps: [String: Any] = ["Latitude": 38.71, "LatitudeRef": "N",
                                  "Longitude": 9.13, "LongitudeRef": "W"]
        try writeJPEG(root.appendingPathComponent("g1.jpg"), gps: gps)
        try writeJPEG(root.appendingPathComponent("g2.jpg"), gps: gps)
        try seed(path: "nogps.jpg", bytes: 5, date: fixtureDate(2026, 1, 1))
        var calls = 0
        let r = Reorganizer()
        r.placeResolver.customLookup = { _, _ in calls += 1; return "Lisbon" }
        let plan = r.analyze(root: root, scheme: .location)
        XCTAssertEqual(calls, 1, "same spot should be looked up once")
        XCTAssertTrue(plan.moves.contains { $0.destination.path.contains("Lisbon/") })
        XCTAssertTrue(plan.moves.contains { $0.destination.path.contains("Unknown location/") })
    }
}
