// StorageView.swift – iPhone app storage over USB: list apps + sizes,
// delete what you don't need (e.g. Maps). Deletions are permanent.

import SwiftUI
import AppKit

struct StorageView: View {
    @ObservedObject var storage: StorageManager

    enum SortMode: String, CaseIterable, Identifiable {
        case size, name
        var id: String { rawValue }
        var title: String { self == .size ? "Size" : "Name" }
    }

    /// Single alert source (two `.alert(item:)` on one view conflict —
    /// only the last one ever presents).
    enum PendingAction: Identifiable {
        case delete(StoredApp)
        var id: String {
            switch self {
            case .delete(let a): return "delete-\(a.id)"
            }
        }
    }

    @State private var search = ""
    @State private var showSystemApps = false
    @State private var sortMode: SortMode = .size
    @State private var pendingAction: PendingAction?
    @State private var resultMessage: String?
    @State private var showResult = false
    @State private var deletingID: String?

    var filtered: [StoredApp] {
        var list = storage.apps
        if !showSystemApps { list = list.filter(\.isUserApp) }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
        }
        switch sortMode {
        case .name:
            break // helper order: user apps first, then by name
        case .size:
            // Biggest first; unmeasured ("—") sink to the bottom.
            list.sort { (storage.sizes[$0.id] ?? -1) > (storage.sizes[$1.id] ?? -1) }
        }
        return list
    }

    var totalKnown: Int64 {
        storage.sizes.values.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "internaldrive")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone Storage")
                        .font(.headline)
                    Text(storage.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Refresh") {
                    storage.refreshApps { _ in storage.loadSizes() }
                }
                .disabled(storage.isLoadingList)
            }

            if let free = storage.diskFree, let total = storage.diskTotal {
                HStack(spacing: 4) {
                    Text("iPhone free: \(StorageManager.sizeString(free)) of \(StorageManager.sizeString(total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if free < 2_000_000_000 {
                        Label("critically low — free space before updating iOS or backing up", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if storage.pythonReady == false {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Python package missing — needed to talk to the iPhone.")
                        .font(.caption)
                    Spacer()
                    if storage.installingDeps { ProgressView().scaleEffect(0.7) }
                    Button(storage.installingDeps ? "Installing…" : "Install") {
                        storage.installDependencies()
                    }
                    .disabled(storage.installingDeps)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }

            HStack {
                TextField("Search apps…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle("Show system apps", isOn: $showSystemApps)
                Picker("Sort", selection: $sortMode) {
                    ForEach(SortMode.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)
                Spacer()
                if storage.sizingInFlight {
                    ProgressView().scaleEffect(0.7)
                    Text("Measuring…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if totalKnown > 0 {
                    Text("Measured: \(StorageManager.sizeString(totalKnown))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if storage.apps.isEmpty && !storage.isLoadingList {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("No apps listed yet")
                            .font(.headline)
                        Text("Connect the iPhone via USB, unlock it, then hit Refresh.\nNeeds Python with pymobiledevice3:\n\(StorageManager.pythonSetupHint)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                List(filtered) { app in
                    DisclosureGroup {
                        if let parts = storage.sizeParts[app.id], !parts.isEmpty {
                            ForEach(parts, id: \.path) { part in
                                HStack {
                                    Text(part.path == "App" ? "App itself" : part.path == "Data" ? "App data" : part.path)
                                        .font(.caption2)
                                    Spacer()
                                    Text(StorageManager.sizeString(part.bytes))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if let warning = storage.sizeWarnings[app.id] {
                            Text(warning)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        } else {
                            Text("Expand after measuring — App/Data split appears here.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.body)
                                Text("\(app.id) · \(app.version)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if let bytes = storage.sizes[app.id] {
                                Text(StorageManager.sizeString(bytes))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            } else if app.isUserApp && storage.sizingInFlight {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Text("—")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .help("No size: container not accessible (unlock iPhone) or system app")
                            }
                        Button {
                            pendingAction = .delete(app)
                        } label: {
                            Image(systemName: "trash")
                        }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .disabled(deletingID != nil)
                            .help("Delete \(app.name) from the iPhone (permanent)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .task {
            storage.checkDependencies()
        }
        .onChange(of: storage.pythonReady) { ready in
            if ready == true, storage.apps.isEmpty {
                storage.refreshApps { _ in storage.loadSizes() }
            }
        }
        .alert(item: $pendingAction) { action in
            switch action {
            case .delete(let app):
                Alert(
                    title: Text("Delete \(app.name)?"),
                    message: Text("This permanently removes \(app.name) (\(app.id)) and its data from the iPhone. System apps iOS protects will fail with a device error."),
                    primaryButton: .destructive(Text("Delete")) {
                        deletingID = app.id
                        storage.uninstall(app) { result in
                            deletingID = nil
                            switch result {
                            case .success(let msg):
                                resultMessage = msg
                            case .failure(let e):
                                resultMessage = "Could not delete \(app.name): \(e.localizedDescription)"
                            }
                            showResult = true
                            storage.refreshApps { _ in storage.loadSizes() }
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .alert("Storage", isPresented: $showResult) {
            Button("OK") {}
        } message: {
            Text(resultMessage ?? "")
        }
    }
}
