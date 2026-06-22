import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FinderSearch")
                .font(.headline)

            if appState.folders.isEmpty {
                emptyState
            } else if appState.progress.isIndexing {
                indexingState
            } else {
                readyState
            }

            Divider()

            HStack {
                Button("Open Window") {
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(minWidth: 320)
        .task {
            await appState.refresh()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No folders indexed yet.")
                .foregroundStyle(.secondary)
            Button {
                Task { await appState.addFolder() }
            } label: {
                Label("Add a folder…", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var indexingState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(appState.progress.currentFolder.isEmpty
                     ? "Indexing…" : "Indexing \(appState.progress.currentFolder)")
                    .lineLimit(1)
            }
            Text("\(appState.progress.processedFiles) files · \(appState.progress.totalChunksIndexed) chunks · \(appState.progress.skippedUnchanged) unchanged")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var readyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Ready — search coming in the main window")
                    .foregroundStyle(.secondary)
            }
            Text("\(appState.chunkCount) chunks across \(appState.fileCount) files")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Reindex") {
                    Task { await appState.reindex() }
                }
                Button("Add folder…") {
                    Task { await appState.addFolder() }
                }
            }
            .buttonStyle(.bordered)
        }
    }
}
