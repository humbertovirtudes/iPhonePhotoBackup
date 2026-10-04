// ReorganizePanel.swift – sidebar UI for reorganizing a backup folder.

import SwiftUI

/// Re-lays out the files already in a backup folder (year / year-month /
/// year-month-day / photos-videos / location), moves stragglers into place
/// and deletes folders left empty. Location grouping reads EXIF GPS and
/// reverse-geocodes it (needs network); files without GPS go to
/// "Unknown location".
struct ReorganizePanel: View {
    @ObservedObject var reorganizer: Reorganizer
    var root: URL?

    @State private var scheme: OrganizationScheme = .yearMonth
    @State private var dryRun = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reorganize folder")
                .font(.headline)
            Text("Move existing backups into a new layout and clean up empty folders.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Layout:", selection: $scheme) {
                ForEach(OrganizationScheme.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .labelsHidden()
            Text("e.g. \(scheme.example)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Toggle("Dry run (preview only)", isOn: $dryRun)
                .font(.caption)
            HStack {
                Button(dryRun ? "Preview" : "Reorganize") {
                    guard let root else { return }
                    reorganizer.run(root: root, scheme: scheme, dryRun: dryRun)
                }
                .disabled(root == nil || reorganizer.isRunning)
                if reorganizer.isRunning {
                    Button("Cancel") { reorganizer.cancel() }
                    ProgressView().scaleEffect(0.7)
                }
            }
            if !reorganizer.statusLine.isEmpty {
                Text(reorganizer.statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(reorganizer.logLines.suffix(4), id: \.self) { line in
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
