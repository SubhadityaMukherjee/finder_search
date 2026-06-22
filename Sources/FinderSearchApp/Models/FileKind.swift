import Foundation

enum FileKind: String, Codable, Sendable, CaseIterable {
    case txt, md, html, pdf

    static let supportedExtensions: Set<String> = Set(FileKind.allCases.map(\.rawValue))

    static func from(pathExtension ext: String) -> FileKind? {
        FileKind(rawValue: ext.lowercased())
    }

    /// Order matters only for display; not used for matching.
    var displayName: String {
        switch self {
        case .txt: return "Text"
        case .md: return "Markdown"
        case .html: return "HTML"
        case .pdf: return "PDF"
        }
    }
}
