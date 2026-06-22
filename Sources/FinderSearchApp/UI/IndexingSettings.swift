import SwiftUI

struct IndexingSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 16) {
            // Folder list
            GroupBox("Indexed folders") {
                VStack(alignment: .leading, spacing: 8) {
                    if appState.folders.isEmpty {
                        Text("No folders yet. Add one to start indexing.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(appState.folders, id: \.id) { folder in
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(folder.displayName)
                                        .font(.body)
                                    if let last = folder.lastIndexedAt {
                                        Text("Last indexed \(last.formatted(.relative(presentation: .named)))")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    } else {
                                        Text("Not indexed yet")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    Task { await appState.removeFolder(id: folder.id) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Stop indexing this folder")
                            }
                        }
                    }

                    HStack {
                        Button {
                            Task { await appState.addFolder() }
                        } label: {
                            Label("Add folder…", systemImage: "plus")
                        }
                        Spacer()
                        Button {
                            Task { await appState.reindex() }
                        } label: {
                            Label("Reindex now", systemImage: "arrow.clockwise")
                        }
                        .disabled(appState.folders.isEmpty || appState.progress.isIndexing)
                    }
                    .padding(.top, 4)
                }
                .padding(8)
            }

            // Indexing status
            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 6) {
                    if appState.progress.isIndexing {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading) {
                                Text(appState.progress.currentFolder.isEmpty
                                     ? "Indexing…" : "Indexing \(appState.progress.currentFolder)")
                                Text("\(appState.progress.processedFiles) processed · \(appState.progress.totalChunksIndexed) chunks · \(appState.progress.skippedUnchanged) unchanged · \(appState.progress.failed) failed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("Idle")
                            .foregroundStyle(.secondary)
                    }
                    if let err = appState.progress.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Counts
            GroupBox("Index") {
                HStack {
                    stat(label: "Files", value: appState.fileCount)
                    Spacer()
                    stat(label: "Chunks", value: appState.chunkCount)
                    Spacer()
                    stat(label: "Folders", value: appState.folders.count)
                }
                .padding(8)
            }
        }
        .task {
            await appState.refresh()
        }
    }

    private func stat(label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
