// StorageManager.swift – iPhone app storage over USB.
//
// Shells out to the bundled pymobiledevice3 helper (pmd_helpers/iphone_tools.py)
// for app listing, per-app container sizes and uninstalls. Requires a Python 3
// with pymobiledevice3 installed, e.g.:
//     /usr/bin/python3 -m pip install --user pymobiledevice3
// The app itself is intentionally unsandboxed: usbmux + subprocesses
// are unreachable from the app sandbox.

import Foundation
import Combine

struct StoredApp: Identifiable, Hashable, Decodable {
    var id: String   // CFBundleIdentifier
    var name: String
    var type: String // "User" | "System" | ...
    var version: String
    var container: String?

    var isUserApp: Bool { type == "User" }

    enum CodingKeys: String, CodingKey {
        case id, name, type, version, container
    }
}

struct AppListResponse: Decodable {
    var apps: [StoredApp]
}

struct AppPart: Decodable, Hashable {
    var path: String
    var bytes: Int64
}

struct AppSizeResponse: Decodable {
    var id: String
    var bytes: Int64?
    var parts: [AppPart]?
    var warning: String?
}

enum StorageError: LocalizedError {
    case noPython(String)
    case noHelper
    case timedOut(String)
    case failed(exit: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .noPython(let hint):
            return "Python with pymobiledevice3 not found. Run:\n\(hint)"
        case .noHelper:
            return "Bundled iPhone helper not found (pmd_helpers/iphone_tools.py)."
        case .timedOut(let what):
            return "\(what) timed out — is the iPhone connected and unlocked?"
        case .failed(let exit, let message):
            return "Helper failed (exit \(exit)): \(message)"
        }
    }
}

final class StorageManager: NSObject, ObservableObject {
    @Published var apps: [StoredApp] = []
    @Published var sizes: [String: Int64] = [:]
    @Published var sizeParts: [String: [AppPart]] = [:]
    /// Why a size couldn't be measured (e.g. locked iPhone) — shown in the row.
    @Published var sizeWarnings: [String: String] = [:]
    @Published var sizingInFlight = false
    @Published var isLoadingList = false
    @Published var statusMessage = "Connect an iPhone via USB, then Refresh."
    @Published var pythonReady: Bool?
    @Published var installingDeps = false

    struct WipeResponse: Decodable {
        var id: String
        var freed: Int64
        var removed: Int
    }

    static let pythonSetupHint = "/usr/bin/python3 -m pip install --user pymobiledevice3"

    static func sizeString(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    // MARK: - Tool discovery

    /// python3 that can `import pymobiledevice3`, or nil.
    static func findPython() -> String? {
        for candidate in ["/usr/bin/python3",
                          "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"] {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: candidate)
            p.arguments = ["-c", "import pymobiledevice3"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 { return candidate }
            } catch {
                continue
            }
        }
        return nil
    }

    /// Helper script: inside the built app bundle first, repo checkout as fallback.
    static func findHelper() -> String? {
        let fm = FileManager.default
        if let res = Bundle.main.resourcePath {
            let inBundle = (res as NSString).appendingPathComponent("pmd_helpers/iphone_tools.py")
            if fm.isReadableFile(atPath: inBundle) { return inBundle }
        }
        let dev = (NSHomeDirectory() as NSString).appendingPathComponent("iPhonePhotoBackup/pmd_helpers/iphone_tools.py")
        if fm.isReadableFile(atPath: dev) { return dev }
        return nil
    }

    // MARK: - Python dependency (one-click install)

    func checkDependencies() {
        statusMessage = "Checking Python setup…"
        DispatchQueue.global(qos: .utility).async {
            let ok = Self.findPython() != nil
            DispatchQueue.main.async {
                self.pythonReady = ok
                self.statusMessage = ok
                    ? "Connect an iPhone via USB, then Refresh."
                    : "Needs the Python package to talk to the iPhone — one tap to install."
            }
        }
    }

    /// `pip install --user pymobiledevice3` with the first working python.
    func installDependencies() {
        guard !installingDeps else { return }
        installingDeps = true
        statusMessage = "Installing pymobiledevice3 (needs network, ~1 min)…"
        DispatchQueue.global(qos: .utility).async {
            var finished = false
            let done: (Bool) -> Void = { ok in
                DispatchQueue.main.async {
                    guard !finished else { return }
                    finished = true
                    self.installingDeps = false
                    if ok {
                        self.pythonReady = true
                        self.statusMessage = "Installed — reading apps…"
                        self.refreshApps { _ in self.loadSizes() }
                    } else {
                        self.pythonReady = false
                        self.statusMessage = "Install failed. Try in Terminal:\n\(Self.pythonSetupHint)"
                    }
                }
            }
            for py in ["/usr/bin/python3",
                       "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
                where FileManager.default.isExecutableFile(atPath: py) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: py)
                p.arguments = ["-m", "pip", "install", "--user", "pymobiledevice3"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { continue }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: killer)
                p.waitUntilExit()
                killer.cancel()
                if p.terminationStatus == 0, Self.findPython() != nil {
                    done(true)
                    return
                }
            }
            done(false)
        }
    }

    // MARK: - Running the helper

    private func runHelper(_ args: [String], timeout: TimeInterval,
                           completion: @escaping (Result<Data, StorageError>) -> Void) {
        guard let python = Self.findPython() else {
            completion(.failure(.noPython(Self.pythonSetupHint)))
            return
        }
        guard let helper = Self.findHelper() else {
            completion(.failure(.noHelper))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [helper] + args
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            var finished = false
            let finish: (Result<Data, StorageError>) -> Void = { result in
                DispatchQueue.main.async {
                    guard !finished else { return }
                    finished = true
                    completion(result)
                }
            }
            do {
                try process.run()
            } catch {
                finish(.failure(.failed(exit: -1, message: error.localizedDescription)))
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    finish(.failure(.timedOut(args.first ?? "helper")))
                }
            }
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                // Prefer the helper's own {"error": ...} on stdout: the last
                // stderr line is often just asyncio teardown noise
                // ("Event loop is closed") hiding the real cause.
                if let json = try? JSONSerialization.jsonObject(with: outData) as? [String: String],
                   let msg = json["error"] {
                    finish(.failure(.failed(exit: process.terminationStatus, message: msg)))
                    return
                }
                let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let lastLine = errText.split(separator: "\n").last.map(String.init) ?? "unknown error"
                finish(.failure(.failed(exit: process.terminationStatus, message: lastLine)))
                return
            }
            finish(.success(out.fileHandleForReading.readDataToEndOfFile()))
        }
    }

    // MARK: - Public API (all completion blocks run on main)

    func refreshApps(completion: ((Result<Int, StorageError>) -> Void)? = nil) {
        isLoadingList = true
        statusMessage = "Reading installed apps…"
        runHelper(["list"], timeout: 90) { [weak self] result in
            guard let self else { return }
            self.isLoadingList = false
            switch result {
            case .failure(let e):
                self.statusMessage = e.localizedDescription
                completion?(.failure(e))
            case .success(let data):
                do {
                    let list = try JSONDecoder().decode(AppListResponse.self, from: data)
                    self.apps = list.apps
                    self.sizes = [:]
                    self.sizeParts = [:]
                    self.sizeWarnings = [:]
                    let users = list.apps.filter(\.isUserApp).count
                    self.statusMessage = "\(list.apps.count) apps (\(users) user-installed)."
                    completion?(.success(list.apps.count))
                } catch {
                    self.statusMessage = "Could not parse app list: \(error.localizedDescription)"
                    completion?(.failure(.failed(exit: -1, message: error.localizedDescription)))
                }
            }
        }
    }

    /// Loads container sizes for user apps in the background (4 at a time).
    /// System apps have no vendable container and stay "—".
    func loadSizes() {
        let targets = apps.filter(\.isUserApp)
        guard !targets.isEmpty, !sizingInFlight else { return }
        sizingInFlight = true
        statusMessage = "Measuring app data (keep the iPhone unlocked)…"
        DispatchQueue.global(qos: .utility).async {
            let group = DispatchGroup()
            let sema = DispatchSemaphore(value: 4)
            var failed = 0
            let failedLock = NSLock()
            for app in targets {
                sema.wait()
                group.enter()
                self.runHelper(["size", app.id], timeout: 240) { [weak self] result in
                    defer { sema.signal(); group.leave() }
                    guard let self else { return }
                    if case .success(let data) = result,
                       let resp = try? JSONDecoder().decode(AppSizeResponse.self, from: data) {
                        if let bytes = resp.bytes {
                            self.sizes[app.id] = bytes
                            if let parts = resp.parts { self.sizeParts[app.id] = parts }
                        } else {
                            self.sizeWarnings[app.id] = resp.warning ?? "Container not accessible — unlock the iPhone and Refresh."
                        }
                    } else {
                        failedLock.lock()
                        failed += 1
                        failedLock.unlock()
                    }
                }
            }
            group.wait()
            DispatchQueue.main.async {
                self.sizingInFlight = false
                if failed > targets.count / 2, !targets.isEmpty {
                    self.statusMessage = "Could not measure most apps — unlock the iPhone and hit Refresh."
                }
            }
        }
    }

    func wipeData(_ app: StoredApp, completion: @escaping (Result<String, StorageError>) -> Void) {
        runHelper(["wipedata", app.id], timeout: 240) { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let data):
                if let resp = try? JSONDecoder().decode(WipeResponse.self, from: data) {
                    completion(.success("Cleared \(Self.sizeString(resp.freed)) in \(resp.removed) item(s) of \(app.name)."))
                } else if let err = try? JSONDecoder().decode([String: String].self, from: data),
                          let msg = err["error"] {
                    completion(.failure(.failed(exit: -1, message: msg)))
                } else {
                    completion(.failure(.failed(exit: -1, message: "Unexpected response")))
                }
            }
        }
    }

    func uninstall(_ app: StoredApp, completion: @escaping (Result<String, StorageError>) -> Void) {
        runHelper(["uninstall", app.id], timeout: 120) { result in
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let data):
                struct Resp: Decodable { var id: String; var ok: Bool }
                if let resp = try? JSONDecoder().decode(Resp.self, from: data), resp.ok {
                    completion(.success("Deleted \(app.name)."))
                } else if let err = try? JSONDecoder().decode([String: String].self, from: data),
                          let msg = err["error"] {
                    completion(.failure(.failed(exit: -1, message: msg)))
                } else {
                    completion(.failure(.failed(exit: -1, message: "Unexpected response")))
                }
            }
        }
    }
}
