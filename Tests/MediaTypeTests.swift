// MediaTypeTests.swift – locks in photo-vs-video classification:
// videos (incl. Live Photo .MOV parts) back up as-is, never converted.

import XCTest
@testable import iPhonePhotoBackup

final class MediaTypeTests: XCTestCase {
    func testMovieExtensionsAreVideo() {
        for name in ["a.mov", "a.MOV", "clip.mp4", "CLIP.MP4", "slow.m4v"] {
            XCTAssertTrue(MediaType.isVideo(uti: "public.data", fileName: name), name)
        }
    }

    func testMovieUTIsAreVideoRegardlessOfName() {
        for uti in ["public.movie", "public.video", "com.apple.quicktime-movie", "public.mpeg-4"] {
            XCTAssertTrue(MediaType.isVideo(uti: uti, fileName: "weirdname.bin"), uti)
        }
    }

    func testPhotosAreNotVideo() {
        for (uti, name) in [
            ("public.heic", "IMG_1.HEIC"),
            ("public.jpeg", "IMG_2.JPG"),
            ("public.png", "shot.PNG"),
            ("public.heif", "live.HEIF"),
        ] {
            XCTAssertFalse(MediaType.isVideo(uti: uti, fileName: name), "\(uti) \(name)")
        }
    }

    func testMpegAudioIsNotVideo() {
        XCTAssertFalse(MediaType.isVideo(uti: "public.mpeg-4-audio", fileName: "weirdname.bin"))
    }

    func testUnknownTypesDefaultToNotVideo() {
        XCTAssertFalse(MediaType.isVideo(uti: "public.data", fileName: "note.txt"))
        XCTAssertFalse(MediaType.isVideo(uti: "", fileName: "IMG_1.HEIC"))
    }
}
