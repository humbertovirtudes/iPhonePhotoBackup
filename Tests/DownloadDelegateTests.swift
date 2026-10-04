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
