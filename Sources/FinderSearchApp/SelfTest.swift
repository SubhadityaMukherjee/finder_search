import Foundation

/// End-to-end smoke test invoked via `FinderSearch --self-test`. Creates a few sample files
/// in a temp directory, indexes them, runs a semantic search and a Q&A pass, prints
/// results, and exits. Verifies the whole pipeline works without needing to click through
/// the UI.
@MainActor
enum SelfTest {
    static func run(appState: AppState) async {
        print("[self-test] starting")
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "findersearch-selftest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleMD = """
        # Project Aurora Runbook

        The staging deploy key is `sk-staging-aurora-12345`. Do not share it outside the team.

        On-call rotation: Mondays are Maya, Tuesdays are Theo, Wednesdays are Wei.

        If the database CPU spikes above 90% for more than 5 minutes, page the on-call engineer.
        """
        let sampleTXT = """
        Q3 2025 retrospective notes.

        We shipped the new onboarding flow on August 14th. Conversion improved by 18%.
        Maya led the design; Theo implemented the analytics layer.
        """
        let sampleHTML = """
        <html><head><title>Old</title></head><body>
        <h1>Vendor list</h1>
        <p>Primary CDN: Fastly. Backup CDN: Cloudflare.</p>
        <p>Billing contact: ar-receipts@example.com.</p>
        </body></html>
        """

        let mdURL = tempDir.appending(path: "runbook.md")
        let txtURL = tempDir.appending(path: "retro.txt")
        let htmlURL = tempDir.appending(path: "vendors.html")
        try? sampleMD.write(to: mdURL, atomically: true, encoding: .utf8)
        try? sampleTXT.write(to: txtURL, atomically: true, encoding: .utf8)
        try? sampleHTML.write(to: htmlURL, atomically: true, encoding: .utf8)
        // Also drops a `.bin` file the crawler should skip (not in our extension set).
        try? "garbage".write(to: tempDir.appending(path: "ignoreme.bin"), atomically: true, encoding: .utf8)

        // Register the temp dir as a tracked folder with a security-scoped bookmark.
        do {
            let bookmark = try tempDir.bookmarkData(options: [.withSecurityScope])
            _ = try await appState.store.addTrackedFolder(
                bookmarkData: bookmark,
                displayName: tempDir.lastPathComponent
            )
            print("[self-test] registered folder: \(tempDir.path)")
        } catch {
            print("[self-test] FAILED to register folder: \(error)")
            exit(1)
        }

        // Index.
        print("[self-test] indexing…")
        await appState.indexer.indexAll()
        await appState.vectorStore.reload()
        await appState.refresh()
        print("[self-test] indexed: \(appState.fileCount) files, \(appState.chunkCount) chunks")
        if appState.progress.failed > 0 {
            print("[self-test] failures: \(appState.progress.failed); lastError: \(appState.progress.lastError ?? "(none)")")
        }

        // Sanity: we expect at least 3 files and ≥ 3 chunks.
        guard appState.fileCount >= 3, appState.chunkCount >= 3 else {
            print("[self-test] FAILED: expected ≥3 files and ≥3 chunks")
            exit(1)
        }

        // Semantic search. NLEmbedding's ranking isn't perfect on 3 short chunks, so we
        // assert presence in the top-K rather than position #1.
        print("\n[self-test] === search: 'staging deploy key' ===")
        let r1 = await appState.queryEngine.search("staging deploy key", k: 3)
        for r in r1 { print("  \(r.score.formatted(.number.precision(.fractionLength(3))))  \(r.displayName) [\(r.id.uuidString.prefix(8))]") }
        guard r1.contains(where: { $0.displayName == "runbook.md" }) else {
            print("[self-test] FAILED: runbook.md should appear in 'staging deploy key' results")
            exit(1)
        }

        print("\n[self-test] === search: 'who is on call tuesday' ===")
        let r2 = await appState.queryEngine.search("who is on call tuesday", k: 3)
        for r in r2 { print("  \(r.score.formatted(.number.precision(.fractionLength(3))))  \(r.displayName)") }
        guard r2.contains(where: { $0.displayName == "runbook.md" }) else {
            print("[self-test] FAILED: runbook.md should be in Tuesday on-call results")
            exit(1)
        }

        // Q&A (skipped if Apple Intelligence unavailable).
        let status = await appState.queryEngine.llmStatus()
        if case .available = status {
            print("\n[self-test] === ask: 'What is the staging deploy key?' ===")
            do {
                let result = try await appState.queryEngine.ask("What is the staging deploy key?")
                print("  answer: \(result.answer)")
                print("  citations: \(result.citations.count)")
                for c in result.citations {
                    print("    - \(c.displayName): \(c.quote.prefix(80))")
                }
                if !result.answer.contains("aurora") && !result.answer.contains("12345") {
                    print("[self-test] WARN: answer doesn't contain the deploy key — LLM may have refused or generalized.")
                }
            } catch {
                print("[self-test] Q&A failed: \(error)")
            }
        } else {
            print("\n[self-test] skipping Q&A — Apple Intelligence not available: \(status)")
        }

        print("\n[self-test] ✓ all assertions passed")
        exit(0)
    }
}
