import Foundation
import PDFKit

/// Per-kind text extraction. Each extractor returns the plain text plus, for PDFs, the
/// character offsets where each page begins (so the chunker can tag chunks with page numbers).
enum TextExtractors {
    struct Extraction: Sendable {
        let text: String
        /// `(pageNumber, startCharOffset)` sorted ascending. Nil for non-PDF kinds.
        let pageBoundaries: [(page: Int, startChar: Int)]?
    }

    static func extract(from url: URL, kind: FileKind) throws -> Extraction {
        switch kind {
        case .txt, .md:
            return try extractPlainText(from: url)
        case .html:
            return extractHTML(from: url)
        case .pdf:
            return try extractPDF(from: url)
        }
    }

    private static func extractPlainText(from url: URL) throws -> Extraction {
        // Prefer UTF-8; fall back to other common encodings if the file isn't valid UTF-8.
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            return Extraction(text: s, pageBoundaries: nil)
        }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) {
            return Extraction(text: s, pageBoundaries: nil)
        }
        // Last resort: let Foundation guess.
        let data = try Data(contentsOf: url)
        let s = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        return Extraction(text: s, pageBoundaries: nil)
    }

    /// Strip tags via regex. Faster and safer than `NSAttributedString` HTML init (which
    /// spins up WebKit and can hang on pathological input). Good enough for search indexing.
    private static func extractHTML(from url: URL) -> Extraction {
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            return Extraction(text: "", pageBoundaries: nil)
        }
        var s = raw
        // Drop script/style blocks first so their JS/CSS doesn't leak into the index.
        s = s.replacingOccurrences(
            of: #"<(script|style)\b[^>]*>[\s\S]*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        // Replace block-level closers with newlines so paragraphs survive as boundaries.
        s = s.replacingOccurrences(
            of: #"</(p|div|section|article|li|h[1-6]|tr|td|th|header|footer|nav|main|aside|blockquote)>"#,
            with: "\n",
            options: .regularExpression
        )
        // Remove remaining tags.
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        // Decode common entities.
        s = decodeEntities(s)
        // Collapse runs of whitespace.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return Extraction(text: s.trimmingCharacters(in: .whitespacesAndNewlines), pageBoundaries: nil)
    }

    private static func decodeEntities(_ s: String) -> String {
        var result = s
        let map: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&copy;", "©"), ("&reg;", "®"), ("&trade;", "™"),
        ]
        for (entity, replacement) in map {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities like &#8217;
        result = result.replacingOccurrences(
            of: #"&#(\d+);"#,
            with: " ",
            options: .regularExpression
        )
        return result
    }

    private static func extractPDF(from url: URL) throws -> Extraction {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            return Extraction(text: "", pageBoundaries: nil)
        }
        // Defensive cap on page count. A 5000-page PDF would otherwise pin gigabytes of
        // memory through PDFKit and likely OOM the process. Pages past the cap are skipped
        // silently; the user can split the file or raise the cap if they really need it.
        let pageCount = min(doc.pageCount, Self.maxPDFPages)
        if doc.pageCount > Self.maxPDFPages {
            print("[TextExtractors] truncating \(url.lastPathComponent) to first \(Self.maxPDFPages) of \(doc.pageCount) pages")
        }
        var text = ""
        var boundaries: [(page: Int, startChar: Int)] = []
        boundaries.reserveCapacity(pageCount)
        for pageIndex in 0..<pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            let pageText = page.string ?? ""
            boundaries.append((page: pageIndex + 1, startChar: text.count))
            text += pageText
            text += "\n"
        }
        return Extraction(text: text, pageBoundaries: boundaries)
    }

    private static let maxPDFPages = 1_000
}
