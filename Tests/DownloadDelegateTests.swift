// DownloadDelegateTests.swift – guards the ObjC selector mapping for the
// USB download delegate. If a Swift rename ever stops matching the selector
// the camera device calls, transfers hang with zero progress and no error —
// exactly the "stuck at zero" symptom. These run with no device attached.

import XCTest
import ImageCaptureCore
@testable import iPhonePhotoBackup

final class DownloadDelegateTests: XCTestCase {
    func testCompletionSelectorMatchesSDK() {
        XCTAssertEqual(
            NSStringFromSelector(#selector(ImportManager.didDownloadFile(_:error:options:contextInfo:))),
            "didDownloadFile:error:options:contextInfo:")
    }

    func testProgressSelectorMatchesSDK() {
        XCTAssertEqual(
            NSStringFromSelector(#selector(ImportManager.didReceiveDownloadProgress(for:downloadedBytes:maxBytes:))),
            "didReceiveDownloadProgressForFile:downloadedBytes:maxBytes:")
    }
}

final class HelperCLITests: XCTestCase {
    /// Runs the BUNDLED helper (also proves the copy phase works).
    private func runHelper(_ args: String...) throws -> Int32 {
        guard let helper = StorageManager.findHelper() else {
            throw XCTSkip("helper not bundled")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [helper] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// No device needed: argument validation happens before connecting.
    func testUsageErrorsExit2() throws {
        XCTAssertEqual(try runHelper(), 2)
        XCTAssertEqual(try runHelper("bogus"), 2)
        XCTAssertEqual(try runHelper("wipedata"), 2)
        XCTAssertEqual(try runHelper("uninstall"), 2)
    }

    func testSizeResponseWithPartsDecodes() throws {
        let json = #"{"id":"x","bytes":300,"parts":[{"path":"Documents","bytes":200},{"path":"Library","bytes":100}]}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(AppSizeResponse.self, from: json)
        XCTAssertEqual(r.bytes, 300)
        XCTAssertEqual(r.parts?.map(\.path), ["Documents", "Library"])
    }
}

final class StorageModelTests: XCTestCase {
    func testAppListDecodes() throws {
        let json = """
        {"apps": [
          {"id": "com.apple.Maps", "name": "Maps", "type": "System", "container": "/private/x", "version": "1.0"},
          {"id": "com.example.app", "name": "Example", "type": "User", "container": null, "version": "2.0"}
        ]}
        """.data(using: .utf8)!
        let list = try JSONDecoder().decode(AppListResponse.self, from: json)
        XCTAssertEqual(list.apps.count, 2)
        XCTAssertFalse(list.apps[0].isUserApp)
        XCTAssertTrue(list.apps[1].isUserApp)
        XCTAssertNil(list.apps[1].container)
    }

    func testSizeString() {
        XCTAssertEqual(StorageManager.sizeString(nil), "—")
        XCTAssertEqual(StorageManager.sizeString(-1), "—")
        XCTAssertFalse(StorageManager.sizeString(1_500_000_000).isEmpty)
    }
}

final class InFlightBytesTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func write(_ name: String, bytes: Int, modDate: Date? = nil) throws {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        if let modDate {
            try FileManager.default.setAttributes([.modificationDate: modDate], ofItemAtPath: url.path)
        }
    }

    func testCountsTargetHiddenTempAndFreshSidecars() throws {
        let since = Date()
        try write("IMG.MOV", bytes: 100)
        try write(".IMG.MOV.sb-1234", bytes: 50)
        try write("IMG.AAE", bytes: 10)
        let (bytes, temps) = ImportManager.inFlightBytes(in: dir, destName: "IMG.MOV", since: since)
        XCTAssertEqual(bytes, 160)
        XCTAssertEqual(Set(temps), [".IMG.MOV.sb-1234", "IMG.AAE"])
    }

    func testIgnoresOldUnrelatedFiles() throws {
        let since = Date()
        try write("IMG.MOV", bytes: 100)
        try write("older.HEIC", bytes: 9000, modDate: Date(timeIntervalSinceNow: -3600))
        let (bytes, _) = ImportManager.inFlightBytes(in: dir, destName: "IMG.MOV", since: since)
        XCTAssertEqual(bytes, 100)
    }

    func testMissingDirectoryIsZero() {
        let (bytes, temps) = ImportManager.inFlightBytes(
            in: dir.appendingPathComponent("nope"), destName: "x", since: Date())
        XCTAssertEqual(bytes, 0)
        XCTAssertTrue(temps.isEmpty)
    }
}
