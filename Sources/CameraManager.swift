// CameraManager.swift – USB discovery + catalog via ImageCaptureCore
//
// Connect iPhone with a USB cable, unlock it, tap "Trust" if asked.
// Uses ICDeviceBrowser to find ICCameraDevice, opens a session,
// then flattens the camera catalog into PhotoItem[].

import AppKit
import ImageCaptureCore
import Combine

final class CameraManager: NSObject, ObservableObject {
    @Published var devices: [ICCameraDevice] = []
    @Published var items: [PhotoItem] = []
    @Published var statusMessage: String = "Connect an iPhone via USB, unlock it and tap Trust."
    @Published var isLoadingCatalog = false
    @Published var selectedDevice: ICCameraDevice? {
        didSet { reloadCatalog() }
    }

    private let browser = ICDeviceBrowser()
    /// Guards against concurrent requestOpenSession calls for one device —
    /// a duplicate request errors out and must not kill the catalog.
    private var openingSession = false

    override init() {
        super.init()
        browser.delegate = self
        // Camera-type devices only (iPhone/iPad over USB present as a camera).
        // Note: Xcode 15+ / macOS 14 SDK renamed this to browsedDeviceTypeMask.
        browser.browsedDeviceTypeMask = .camera
    }

    func start() {
        statusMessage = "Looking for USB cameras…"
        browser.start()
    }

    func stop() {
        browser.stop()
        for d in devices where d.hasOpenSession {
            d.requestCloseSession()
        }
    }

    /// Re-discovers USB cameras and re-opens the session/catalog.
    /// Use when reconnecting a phone shows nothing.
    func rescan() {
        statusMessage = "Rescanning for USB cameras…"
        openingSession = false
        browser.stop()
        browser.start()
        // Re-run the open/catalog flow for whatever is selected; newly
        // discovered devices arrive via deviceBrowser(didAdd:) below.
        reloadCatalog()
    }

    // MARK: - Catalog

    private func reloadCatalog() {
        guard let device = selectedDevice else {
            items = []
            return
        }
        if device.isAccessRestrictedAppleDevice {
            statusMessage = "iPhone is locked – unlock it and tap Trust, then reconnect USB."
            items = []
            return
        }
        if !device.hasOpenSession {
            guard !openingSession else { return } // open already in flight
            openingSession = true
            isLoadingCatalog = true
            statusMessage = "Opening session with \(device.name ?? "iPhone")…"
            device.requestOpenSession()
            return
        }
        buildItems(from: device)
    }

    private func buildItems(from device: ICCameraDevice) {
        isLoadingCatalog = true
        // mediaFiles is only fully populated after deviceDidBecomeReady.
        var flat: [ICCameraFile] = []
        collectFiles(device.mediaFiles, into: &flat)

        let deviceID = device.serialNumberString ?? device.uuidString ?? device.name ?? "device"
        var newItems: [PhotoItem] = []
        newItems.reserveCapacity(flat.count)
        for f in flat {
            let name = f.name ?? "IMG_\(newItems.count)"
            // Skip tiny sidecar/metadata files that aren't media? Keep everything that looks like media.
            let size = Int64(f.fileSize)
            let date = f.creationDate ?? f.modificationDate ?? Date()
            let uti = f.uti ?? (name as NSString).pathExtension
            let id = "\(deviceID)/\(name)-\(size)"
            newItems.append(PhotoItem(id: id, file: f, name: name, fileSize: size, creationDate: date, uti: uti, thumbnail: nil))
        }
        // Newest first — nicer for "import what's new".
        newItems.sort { $0.creationDate > $1.creationDate }

        DispatchQueue.main.async {
            self.items = newItems
            self.isLoadingCatalog = false
            self.statusMessage = newItems.isEmpty
                ? "No photos found on \(device.name ?? "iPhone"). Catalog may still be loading — wait a few seconds."
                : "\(newItems.count) items found on \(device.name ?? "iPhone")."
            // Kick off thumbnail requests (throttled to first 300 to stay responsive).
            // Videos excluded: on-device video thumbnails are expensive to render
            // and compete with downloads on the same PTP channel (their grid
            // cells already show a VIDEO badge instead).
            for item in newItems.prefix(300) where !item.isVideo {
                item.file.requestThumbnail()
            }
        }
    }

    private func collectFiles(_ catalog: [ICCameraItem]?, into out: inout [ICCameraFile]) {
        guard let catalog else { return }
        for entry in catalog {
            if let file = entry as? ICCameraFile {
                out.append(file)
            } else if let folder = entry as? ICCameraFolder {
                // ICCameraFolder exposes children via `contents`.
                collectFiles(folder.contents, into: &out)
            }
        }
    }

    private func mainDevice(named device: ICDevice) -> ICCameraDevice? {
        device as? ICCameraDevice
    }
}

// MARK: - ICDeviceBrowserDelegate

extension CameraManager: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = mainDevice(named: device) else { return }
        camera.delegate = self
        DispatchQueue.main.async {
            if !self.devices.contains(where: { $0 === camera }) {
                self.devices.append(camera)
            }
            if self.selectedDevice == nil {
                self.selectedDevice = camera // didSet → reloadCatalog
            } else {
                self.reloadCatalog() // e.g. rescan re-delivery: refresh
            }
            self.statusMessage = "Found \(camera.name ?? "camera") – opening…"
        }
        if camera.isAccessRestrictedAppleDevice {
            DispatchQueue.main.async {
                self.statusMessage = "iPhone is locked – unlock it and tap Trust."
            }
            return
        }
        // Session opening + catalog build are owned by reloadCatalog
        // (triggered by the selection below) — requesting here too would
        // fire a duplicate open whose error kills the catalog.
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        DispatchQueue.main.async {
            self.devices.removeAll { $0 === camera }
            if self.selectedDevice === camera {
                self.selectedDevice = self.devices.first
                if self.selectedDevice == nil {
                    self.items = []
                    self.statusMessage = "iPhone disconnected. Reconnect via USB."
                }
            }
        }
    }
}

// MARK: - ICCameraDeviceDelegate / ICDeviceDelegate

extension CameraManager: ICCameraDeviceDelegate {
    // MARK: ICDeviceDelegate @required

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        DispatchQueue.main.async { self.openingSession = false }
        if let error {
            // A duplicate open request can error while the session is
            // actually fine — only give up when there is truly no session.
            guard let camera = device as? ICCameraDevice, camera.hasOpenSession else {
                DispatchQueue.main.async {
                    self.isLoadingCatalog = false
                    self.statusMessage = "Could not open iPhone session: \(error.localizedDescription). Unlock + Trust, then replug USB or hit Rescan."
                }
                return
            }
        }
        guard let camera = device as? ICCameraDevice else { return }
        if camera === selectedDevice || selectedDevice == nil {
            DispatchQueue.main.async { self.selectedDevice = camera }
        }
        // Full catalog arrives via deviceDidBecomeReadyWithCompleteContentCatalog; build what we have meanwhile.
        buildItems(from: camera)
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        DispatchQueue.main.async {
            self.openingSession = false
            self.statusMessage = "Session closed."
            self.isLoadingCatalog = false
        }
    }

    func didRemove(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice else { return }
        DispatchQueue.main.async {
            self.devices.removeAll { $0 === camera }
            if self.selectedDevice === camera {
                self.selectedDevice = self.devices.first
                if self.selectedDevice == nil {
                    self.items = []
                    self.statusMessage = "iPhone disconnected. Reconnect via USB."
                }
            }
        }
    }

    // MARK: ICCameraDeviceDelegate @required

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        buildItems(from: device)
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        // User tapped Trust / unlocked.
        guard let camera = device as? ICCameraDevice else { return }
        DispatchQueue.main.async {
            self.statusMessage = "Access granted – opening \(camera.name ?? "iPhone")…"
            if self.selectedDevice == nil { self.selectedDevice = camera }
        }
        if !camera.hasOpenSession {
            camera.requestOpenSession()
        } else {
            buildItems(from: camera)
        }
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        DispatchQueue.main.async {
            self.statusMessage = "iPhone locked – unlock it to browse photos."
            self.items = []
            self.isLoadingCatalog = false
            // Fail any in-flight download fast (it would stall otherwise).
            NotificationCenter.default.post(name: .cameraAccessRestricted, object: nil)
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        buildItems(from: camera)
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        buildItems(from: camera)
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        buildItems(from: camera)
    }

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        guard let thumbnail, let file = item as? ICCameraFile else { return }
        let nsImage = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        let key = file.name ?? ""
        let size = Int64(file.fileSize)
        DispatchQueue.main.async {
            if let idx = self.items.firstIndex(where: { $0.name == key && $0.fileSize == size }) {
                self.items[idx].thumbnail = nsImage
            }
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {
    }
}
