import SwiftUI

struct SearchWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        TabView {
            VStack(spacing: 0) {
                searchBar(text: $appState.searchQuery)
                Divider()
                content
            }
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }

            FoldersTab()
                .tabItem {
                    Label("Folders", systemImage: "folder")
                }
        }
        .task {
            await appState.bootstrap()
        }
        .onChange(of: appState.searchQuery) {
            appState.scheduleSearch()
        }
    }

    private func searchBar(text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Ask anything…", text: text)
                .textFieldStyle(.plain)
                .font(.title3)
                .onSubmit {
                    Task { await appState.ask() }
                }
            if appState.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
            if !appState.searchQuery.isEmpty {
                Button {
                    appState.searchQuery = ""
                    appState.results = []
                    appState.answerState = .idle
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var content: some View {
        if appState.folders.isEmpty {
            emptyStateView
        } else if appState.chunkCount == 0 {
            noIndexView
        } else if appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            idleView
        } else {
            VStack(spacing: 0) {
                if !isAnswerIdle {
                    AnswerView()
                    Divider()
                }
                if appState.results.isEmpty && !appState.isSearching {
                    noResultsView
                } else {
                    resultsList
                }
            }
        }
    }

    /// True when the answer panel has nothing useful to show.
    private var isAnswerIdle: Bool {
        if case .idle = appState.answerState { return true }
        return false
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("Add a folder to start indexing")
                .font(.title3)
            Text("FinderSearch will index every .txt, .md, .html, and .pdf file in folders you choose, then let you search them by meaning.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Task { await appState.addFolder() }
            } label: {
                Label("Add folder…", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)

            IndexingSettings()
                .padding(.top, 20)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noIndexView: some View {
        VStack(spacing: 14) {
            if appState.progress.isIndexing {
                ProgressView()
                    .controlSize(.large)
                Text("Indexing your files…")
                    .font(.title3)
                Text("\(appState.progress.processedFiles) files · \(appState.progress.totalChunksIndexed) chunks so far")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Index is empty")
                    .font(.title3)
                Button {
                    Task { await appState.reindex() }
                } label: {
                    Label("Reindex now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idleView: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Ask a question above")
                .font(.title3)
            Text("\(appState.chunkCount) chunks across \(appState.fileCount) files, ready to search.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No matches")
                .font(.title3)
            Text("Try a different phrasing — semantic search works best with natural-language queries.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(appState.results) { result in
                    ResultRow(result: result)
                    if result.id != appState.results.last?.id {
                        Divider().padding(.leading, 4)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
