// StorageView.swift – iPhone app storage over USB: list apps + sizes,
// delete what you don't need (e.g. Maps). Deletions are permanent.

import SwiftUI

struct StorageView: View {
    @ObservedObject var storage: StorageManager

    @State private var search = ""
    @State private var showSystemApps = false
    @State private var pendingDelete: StoredApp?
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

            HStack {
                TextField("Search apps…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle("Show system apps", isOn: $showSystemApps)
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
                        }
                        Button {
                            pendingDelete = app
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .disabled(deletingID != nil)
                        .help("Delete \(app.name) from the iPhone (permanent)")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .task {
            if storage.apps.isEmpty {
                storage.refreshApps { _ in storage.loadSizes() }
            }
        }
        .alert(item: $pendingDelete) { app in
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
        .alert("Storage", isPresented: $showResult) {
            Button("OK") {}
        } message: {
            Text(resultMessage ?? "")
        }
    }
}
