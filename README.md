# FinderSearch

A Mac menu-bar app that indexes every `.txt`, `.md`, `.html`, and `.pdf` file in folders you choose, then answers natural-language questions about them using on-device Apple Intelligence — returning the exact file and location (line for text, page for PDF) the answer came from.

Fully local. No cloud, no API keys.

## Requirements

- macOS 27 (Sequoia successor / Darwin 27)
- Xcode 26.5+ (only for the Swift toolchain; you don't need to open the project)
- Apple Intelligence enabled in System Settings → Apple Intelligence & Siri (only required for the Q&A panel; semantic search works without it)

## Build & run

```sh
./scripts/make-app-bundle.sh
open .build/FinderSearch.app
```

This builds the SwiftPM executable in release mode, wraps it in a proper `.app` bundle, and launches it. A magnifying-glass icon appears in the menu bar.

Iterating during development:

```sh
swift build                       # debug build, faster compile
./scripts/make-app-bundle.sh      # rebuilds release + re-wraps
open .build/FinderSearch.app
```

## Usage

1. Click the menu-bar magnifying glass → **Open Window**.
2. Click **Add folder…** and pick a folder to index (your `~/Documents`, a project directory, etc.). The folder is stored as a security-scoped bookmark, so access survives restarts.
3. Wait for indexing to finish. Progress shows in the menu-bar dropdown and the main window.
4. Type a query. As you type, semantic matches appear instantly (debounced 200ms).
5. Press **Enter** to ask the on-device LLM. The answer appears at the top with citation chips; click a chip to reveal the source file in Finder.

Folders are watched via FSEvents — drop in a new file or edit an existing one and the index updates within a few seconds without a manual reindex.

## Architecture

RAG pipeline built on Apple's public frameworks:

```
NSOpenPanel → TrackedFolder (SwiftData, security-scoped bookmark)
                     ↓
              FileCrawler (FileManager.enumerator)
                     ↓
              TextExtractors (txt/md/html/pdf, PDFKit for PDFs)
                     ↓
              Chunker (NLTokenizer sentence-aware, ~500 chars + 100 overlap)
                     ↓
              EmbeddingService (NLEmbedding.sentenceEmbedding for .english)
                     ↓
              SwiftData: FileRecord, Chunk (with embedding blob)

Query path:
  query → EmbeddingService → VectorStore.cosineTopK → [Chunk]
                                                  ↓
                          FoundationModels.LanguageModelSession.respond(
                              generating: AnswerWithCitations.self
                          )
                                                  ↓
                          Answer + Citations (chunk IDs map back to sources)
```

Key files:
- `Sources/FinderSearchApp/Models/` — SwiftData models (`FileRecord`, `Chunk`, `TrackedFolder`) and the `@Generable` schema (`AnswerWithCitations`).
- `Sources/FinderSearchApp/Indexing/` — crawler, extractors, chunker, embedder, indexer actor, FSEvents watcher.
- `Sources/FinderSearchApp/Retrieval/` — in-memory cosine vector store and the RAG query engine.
- `Sources/FinderSearchApp/UI/` — SwiftUI views (menu-bar panel, main window, answer view, source list).
- `Sources/FinderSearchApp/Store.swift` — `@ModelActor` isolating all SwiftData access for background work.
- `scripts/make-app-bundle.sh` — wraps `swift build` output into a launchable `.app`.

## Storage

- SwiftData SQLite store at `~/Library/Application Support/FinderSearch/store.sqlite`.
- No telemetry. Logs go to stderr (visible in Console.app).

## Limitations / next steps

- **Scanned PDFs** without an OCR text layer return empty content; we log them as failed and move on.
- **Non-English text** may retrieve poorly — `NLEmbedding.sentenceEmbedding(for: .english)` is English-only. Swap point is `EmbeddingService` only.
- **Streaming**: the Q&A panel waits for the full response. Streaming via `ResponseStream` is the obvious upgrade.
- **Result diversity**: top-K caps at 3 chunks per file so a single huge file can't dominate.
- **Distribution**: the bundle is unsigned (fine for personal use). To distribute, add an entitlements file and notarize.
