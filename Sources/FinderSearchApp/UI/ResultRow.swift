import SwiftUI
import AppKit

struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: iconForKind)
                    .foregroundStyle(.tint)
                Text(result.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(locationLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Text(String(format: "%.0f%%", result.score * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(snippet)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            HStack(spacing: 4) {
                Text(result.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reveal") { revealInFinder() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("Open") { openFile() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private var iconForKind: String {
        switch result.kind {
        case .md: return "doc.richtext"
        case .pdf: return "doc.text.fill"
        case .html: return "globe"
        case .txt: return "doc.plaintext"
        }
    }

    private var locationLabel: String {
        if let page = result.pageNumber {
            return "p. \(page)"
        }
        if let line = computeLineNumber() {
            return "L \(line)"
        }
        return "offset \(result.charStart)"
    }

    private var snippet: String {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= 240 { return text }
        let start = text.startIndex
        let end = text.index(start, offsetBy: 240)
        return String(text[start..<end]) + "…"
    }

    private func computeLineNumber() -> Int? {
        guard result.kind != .pdf, result.kind != .html else { return nil }
        guard let content = try? String(contentsOfFile: result.pathString, encoding: .utf8) else {
            return nil
        }
        let target = result.charStart
        var line = 1
        var i = 0
        for ch in content {
            if i >= target { break }
            if ch == "\n" { line += 1 }
            i += 1
        }
        return line
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }

    private func openFile() {
        NSWorkspace.shared.open(result.url)
    }
}
