import SwiftUI

/// Per-folder management view shown in the Folders tab of the main window. Lists every
/// tracked folder with file/chunk counts (computed by `Store.folderStats()`), last-indexed
/// time, and remove action. The "Add folder…" sheet uses the same `NSOpenPanel` flow as
/// the menu bar panel.
struct FoldersTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            toolbar
            Divider()
            if appState.folderStats.isEmpty {
                emptyState
            } else {
                folderList
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
            await appState.refresh()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Indexed Folders")
                    .font(.title3.weight(.semibold))
                Text("\(appState.folderStats.count) folders · \(appState.fileCount) files · \(appState.chunkCount) chunks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await appState.reindex() }
            } label: {
                Label("Reindex all", systemImage: "arrow.clockwise")
            }
            .disabled(appState.folderStats.isEmpty || appState.progress.isIndexing)

            Button {
                Task { await appState.addFolder() }
            } label: {
                Label("Add folder…", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No folders indexed yet")
                .font(.title3)
            Text("Add a folder and FinderSearch will read every .txt, .md, .html, and .pdf file inside, then let you search them by meaning.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)
            Button {
                Task { await appState.addFolder() }
            } label: {
                Label("Add folder…", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderList: some View {
        List {
            ForEach(appState.folderStats) { stats in
                folderRow(stats)
            }
        }
        .listStyle(.inset)
    }

    private func folderRow(_ stats: Store.FolderStats) -> some View {
        HStack(alignment: .top, spacing: 12) {
            folderCell(stats)
                .frame(maxWidth: .infinity, alignment: .leading)
            statsColumn(stats)
            Button(role: .destructive) {
                Task { await appState.removeFolder(id: stats.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Stop indexing this folder")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statsColumn(_ stats: Store.FolderStats) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 12) {
                Text("\(stats.fileCount) files")
                Text("\(stats.chunkCount) chunks")
                if stats.failedCount > 0 {
                    Text("\(stats.failedCount) failed").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            if let date = stats.lastIndexedAt {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("never indexed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func folderCell(_ stats: Store.FolderStats) -> some View {
        HStack(spacing: 8) {
            Image(systemName: stats.resolvedPath == nil ? "folder.badge.questionmark" : "folder.fill")
                .foregroundStyle(stats.resolvedPath == nil ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(stats.displayName)
                        .fontWeight(.medium)
                    if stats.resolvedPath == nil {
                        Text("bookmark stale")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let path = stats.resolvedPath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Folder not reachable — re-add it to refresh access.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }
}
