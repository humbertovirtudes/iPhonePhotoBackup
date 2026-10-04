// iPhonePhotoBackupApp.swift
// Native macOS app entry point – SwiftUI, macOS 13+

import SwiftUI

@main
struct iPhonePhotoBackupApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}
