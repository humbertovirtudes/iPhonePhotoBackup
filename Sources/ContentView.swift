// ContentView.swift – main UI: device + destination + photo grid + import

import SwiftUI
import AppKit
import ImageCaptureCore

private let bookmarkKey = "destinationBookmark"

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var importer = ImportManager()
    @StateObject private var reorganizer = Reorganizer()

    @State private var destination: URL?
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var showVideosOnly = false
    @State private var importScheme: OrganizationScheme = .yearMonth
    @State private var newCount: Int?

    var filtered: [PhotoItem] {
        var list = camera.items
        if showVideosOnly { list = list.filter { $0.isVideo } }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter { $0.name.lowercased().contains(q) }
        }
        return list
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    grid
                    sidebar
                }
                Divider()
                footer
            }
            if reorganizer.isRunning {
                ReorganizeBlockingOverlay(reorganizer: reorganizer)
            }
        }
        .onAppear {
            restoreDestination()
            camera.start()
        }
        .onDisappear {
            camera.stop()
        }
    }

    // MARK: - Header

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone Photo Backup")
                        .font(.headline)
                    Text(camera.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if camera.isLoadingCatalog {
                    ProgressView().scaleEffect(0.7)
                }
            }

            HStack(spacing: 8) {
                // Device picker
                Picker("iPhone:", selection: $camera.selectedDevice) {
                    Text("None").tag(nil as ICCameraDevice?)
                    ForEach(camera.devices, id: \.self) { d in
                        Text(d.name ?? "iPhone").tag(d as ICCameraDevice?)
                    }
                }
                .frame(maxWidth: 260)

                // Destination picker (works with internal + external drives)
                Button {
                    chooseDestination()
                } label: {
                    HStack {
                        Image(systemName: "externaldrive")
                        Text(destination?.path ?? "Choose backup folder…")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                }
                .help("Pick any folder on this Mac or an external hard drive")

                Spacer()

                Button("Select all") { selection = Set(filtered.map(\.id)) }
                    .disabled(filtered.isEmpty)
                Button("Clear") { selection.removeAll() }
                    .disabled(selection.isEmpty)

                Button("Import selected (\(selection.count))") {
                    importSelected()
                }
                .disabled(selection.isEmpty || importer.isImporting || destination == nil)
                .keyboardShortcut(.defaultAction)

                Button(newCount.map { "Import all new (\($0))" } ?? "Import all new") {
                    importAllNew()
                }
                .disabled(camera.items.isEmpty || importer.isImporting || destination == nil || newCount == 0)
                .help(newCount.map { "\($0) item(s) not yet in the backup folder" } ?? "Copy everything not yet backed up")

                if importer.isImporting {
                    Button("Cancel") { importer.cancel() }
                }
            }

            HStack(spacing: 12) {
                TextField("Search filename…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Toggle("Videos only", isOn: $showVideosOnly)
                Picker("Layout:", selection: $importScheme) {
                    ForEach(OrganizationScheme.importCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .frame(maxWidth: 200)
                .help("Folder layout for new imports, e.g. \(importScheme.example)")
                Spacer()
                Text("\(filtered.count) items · \(selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .task(id: refreshKey) {
            guard let dest = destination, !camera.items.isEmpty else {
                newCount = nil
                return
            }
            let items = camera.items
            let scheme = importScheme
            let n = await Task.detached(priority: .utility) {
                BackupOrganizer.newItemCount(items, root: dest, scheme: scheme)
            }.value
            guard !Task.isCancelled else { return }
            newCount = n
        }
    }

    var refreshKey: String {
        "\(camera.items.count)-\(destination?.path ?? "")-\(importScheme.rawValue)-\(importer.importedCount)"
    }

    // MARK: - Grid

    var grid: some View {
        Group {
            if camera.items.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "cable.connector")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Connect your iPhone with a USB cable")
                        .font(.headline)
                    Text("Unlock it, tap Trust if asked, and wait for photos to appear.\nNo iCloud, no Photos.app needed.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)], spacing: 12) {
                        ForEach(filtered) { item in
                            PhotoCell(
                                item: item,
                                selected: selection.contains(item.id),
                                destinationExistsHint: nil
                            )
                            .onTapGesture {
                                if selection.contains(item.id) {
                                    selection.remove(item.id)
                                } else {
                                    selection.insert(item.id)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sidebar (help + destination info)

    var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Backup")
                    .font(.headline)
                if let dest = destination {
                    Text(dest.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Text("New imports go to:\n\(importScheme.example)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No folder chosen yet. Pick a folder on your Mac or external drive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                ReorganizePanel(reorganizer: reorganizer, root: destination)
                Divider()
                Text("How it works")
                    .font(.headline)
                Text("• USB only — files copy straight off the iPhone.\n• Duplicates matched by name, size and capture date.\n• Videos, Live Photos and HEIC kept as-is.\n• Works with external hard drives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 260)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Footer (progress + log)

    var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if importer.isImporting || importer.progress > 0 {
                HStack {
                    ProgressView(value: importer.progress) {
                        Text(importer.isImporting ? "Backing up \(importer.currentFileName)" : "Idle")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Text("\(importer.importedCount) ✓  \(importer.skippedCount) skipped  \(importer.failedCount) failed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(importer.logLines.suffix(8), id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(height: 90)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    func importSelected() {
        guard let dest = destination else { return }
        let items = camera.items.filter { selection.contains($0.id) }
        importer.importItems(items, to: dest, scheme: importScheme)
    }

    func importAllNew() {
        guard let dest = destination else { return }
        // ImportManager skips duplicates, so "all" == "all new".
        importer.importItems(camera.items, to: dest, scheme: importScheme)
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as backup folder"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
            saveBookmark(url)
        }
    }

    func saveBookmark(_ url: URL) {
        // Persist so the app remembers the external drive folder across launches.
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    func restoreDestination() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            _ = url.startAccessingSecurityScopedResource()
            destination = url
        }
    }
}

struct PhotoCell: View {
    let item: PhotoItem
    let selected: Bool
    let destinationExistsHint: Bool?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = item.thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay {
                                Image(systemName: item.isVideo ? "video" : "photo")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(height: 110)
                .clipped()
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3)
                )

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.title2)
                        .padding(6)
                }
                if item.isVideo {
                    Text("VIDEO")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7))
                        .foregroundStyle(.white)
                        .cornerRadius(4)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(item.displaySize) · \(dateString)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(10)
    }

    var dateString: String {
        DateFormatter.localizedString(from: item.creationDate, dateStyle: .short, timeStyle: .none)
    }
}
