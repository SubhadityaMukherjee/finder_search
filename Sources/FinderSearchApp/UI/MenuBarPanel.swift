import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    @State private var query: String = ""
    @State private var results: [SearchResult] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FinderSearch")
                .font(.headline)

            searchField

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusView
            } else if results.isEmpty {
                Text("No matches yet — keep typing, or press Enter to ask the assistant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                resultsList
            }

            Divider()

            HStack {
                Button("Open Window") {
                    openWindow(id: "main")
                }
                Spacer()
                Button("Add folder…") {
                    Task { await appState.addFolder() }
                }
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(14)
        .frame(minWidth: 340, idealWidth: 380)
        .task {
            await appState.refresh()
        }
        .onChange(of: query) {
            scheduleSearch()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search or ask…", text: $query)
                .textFieldStyle(.plain)
                .onSubmit {
                    Task { await ask() }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.progress.isIndexing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(appState.progress.currentFolder.isEmpty
                         ? "Indexing…" : "Indexing \(appState.progress.currentFolder)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(appState.progress.processedFiles) files · \(appState.progress.totalChunksIndexed) chunks")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if appState.folderStats.isEmpty {
                Text("Add a folder to start indexing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(appState.chunkCount) chunks across \(appState.fileCount) files ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(results.prefix(5).enumerated()), id: \.element.id) { idx, result in
                MenuBarResultRow(result: result)
                if idx < min(results.count, 5) - 1 {
                    Divider()
                }
            }
            if results.count > 5 {
                Button {
                    Task { await ask() }
                } label: {
                    Text("Open window for all \(results.count) results and Q&A →")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        let engine = appState.queryEngine
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let r = await engine.search(q, k: 10, maxPerFile: 3)
            guard !Task.isCancelled else { return }
            results = r
        }
    }

    /// Enter hands the query to the main window for full Q&A. The popover is too small for
    /// synthesis answers, but the user gets continuity: the search box is pre-populated and
    /// the answer panel is one click away.
    private func ask() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        appState.searchQuery = q
        appState.scheduleSearch()
        openWindow(id: "main")
    }
}

private struct MenuBarResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconForKind)
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(result.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let page = result.pageNumber {
                        Text("p.\(page)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(result.text.prefix(120))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help("Reveal in Finder")
        .onTapGesture {
            NSWorkspace.shared.activateFileViewerSelecting([result.url])
        }
    }

    private var iconForKind: String {
        switch result.kind {
        case .md: return "doc.richtext"
        case .pdf: return "doc.text.fill"
        case .html: return "globe"
        case .txt: return "doc.plaintext"
        }
    }
}
