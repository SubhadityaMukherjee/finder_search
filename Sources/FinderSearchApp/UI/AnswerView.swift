import SwiftUI
import AppKit

struct AnswerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.answerState {
        case .idle:
            EmptyView()
        case .thinking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Thinking…")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        case .complete(let result):
            completeView(result)
        case .error(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        case .unavailable(let reason):
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Q&A unavailable")
                        .font(.callout.weight(.medium))
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func completeView(_ result: QAResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text(result.broad ? "Synthesis" : "Answer")
                    .font(.headline)
                Spacer()
                if result.broad {
                    Text("\(result.sources.count) sources")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(result.answer)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !result.citations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Citations")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(result.citations) { citation in
                            CitationChip(citation: citation)
                        }
                    }
                }
            }

            // Broad queries surface every retrieved source so the user can see what was
            // fed to the LLM — not just the chunks the model chose to cite. Collapsed by
            // default; expand to scroll through all of them.
            if result.broad, !result.sources.isEmpty {
                DisclosureGroup("All retrieved sources (\(result.sources.count))") {
                    SourceList(sources: result.sources)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }
}

struct CitationChip: View {
    let citation: QACitation

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconForKind)
                .font(.caption2)
            Text(citation.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if let page = citation.pageNumber {
                Text("p.\(page)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .help(citation.quote)
        .onTapGesture {
            NSWorkspace.shared.activateFileViewerSelecting([citation.url])
        }
    }

    private var iconForKind: String {
        switch citation.kind {
        case .md: return "doc.richtext"
        case .pdf: return "doc.text.fill"
        case .html: return "globe"
        case .txt: return "doc.plaintext"
        }
    }
}

/// Compact list of every chunk retrieved for a broad query, grouped by file. Click a row
/// to reveal the source file in Finder.
struct SourceList: View {
    let sources: [SearchResult]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { _, source in
                    SourceRow(source: source)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 180)
    }
}

private struct SourceRow: View {
    let source: SearchResult

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForKind)
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.activateFileViewerSelecting([source.url])
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let page = source.pageNumber { parts.append("p.\(page)") }
        parts.append("score \(source.score.formatted(.number.precision(.fractionLength(3))))")
        return parts.joined(separator: " · ")
    }

    private var iconForKind: String {
        switch source.kind {
        case .md: return "doc.richtext"
        case .pdf: return "doc.text.fill"
        case .html: return "globe"
        case .txt: return "doc.plaintext"
        }
    }
}

/// Minimal wrapping layout for citation chips. SwiftUI's `Layout` protocol lets us
/// position children in a row that wraps to the next line when full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
