import Foundation
import NaturalLanguage

/// Splits extracted text into embedding-sized chunks while preserving character offsets back
/// into the source. Sentence-aware so chunks don't split mid-sentence when possible.
struct Chunker {
    struct ChunkSlice: Sendable {
        let text: String
        let charStart: Int
        let charEnd: Int
        let pageNumber: Int?
    }

    let targetChars: Int
    let overlapChars: Int

    init(targetChars: Int = 500, overlapChars: Int = 100) {
        self.targetChars = targetChars
        self.overlapChars = overlapChars
    }

    func chunk(
        _ text: String,
        pageBoundaries: [(page: Int, startChar: Int)]? = nil
    ) -> [ChunkSlice] {
        guard !text.isEmpty else { return [] }

        // Tokenize into sentences. NLTokenizer yields sentence ranges in the source string.
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        struct Sentence {
            let text: String
            let start: Int
            let end: Int
        }
        var sentences: [Sentence] = []
        sentences.reserveCapacity(text.count / 40 + 1)

        var lastEnd = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let endOffset = text.distance(from: text.startIndex, to: range.upperBound)
            // Catch any text between sentences (whitespace, headings NLTokenizer skips).
            if lastEnd < range.lowerBound {
                let gapStart = text.distance(from: text.startIndex, to: lastEnd)
                let gapEnd = text.distance(from: text.startIndex, to: range.lowerBound)
                if gapEnd > gapStart {
                    let gapText = String(text[lastEnd..<range.lowerBound])
                    if !gapText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        sentences.append(Sentence(text: gapText, start: gapStart, end: gapEnd))
                    }
                }
            }
            sentences.append(Sentence(
                text: String(text[range]),
                start: startOffset,
                end: endOffset
            ))
            lastEnd = range.upperBound
            return true
        }
        // Trailing fragment after the last sentence boundary.
        if lastEnd < text.endIndex {
            let gapStart = text.distance(from: text.startIndex, to: lastEnd)
            let gapEnd = text.distance(from: text.startIndex, to: text.endIndex)
            let gapText = String(text[lastEnd..<text.endIndex])
            if !gapText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(Sentence(text: gapText, start: gapStart, end: gapEnd))
            }
        }

        guard !sentences.isEmpty else { return [] }

        // Group sentences into chunks of ~targetChars, with overlap.
        var chunks: [ChunkSlice] = []
        var currentText = ""
        var currentStart = sentences[0].start
        var currentEnd = 0
        var idx = 0

        while idx < sentences.count {
            let sentence = sentences[idx]
            let prospectiveLength = currentText.count + sentence.text.count
            if currentText.isEmpty {
                currentText = sentence.text
                currentStart = sentence.start
                currentEnd = sentence.end
                idx += 1
                continue
            }
            if prospectiveLength <= targetChars {
                currentText += sentence.text
                currentEnd = sentence.end
                idx += 1
            } else {
                // Flush current chunk.
                chunks.append(makeSlice(text: currentText, start: currentStart, end: currentEnd, pageBoundaries: pageBoundaries))
                // Start next chunk with overlap: carry the last `overlapChars` worth of current text.
                let overlap = tailOverlap(of: currentText, length: overlapChars)
                currentText = overlap.text + sentence.text
                currentStart = (currentEnd - overlap.charsDropped)
                currentEnd = sentence.end
                idx += 1
            }
        }
        if !currentText.isEmpty {
            chunks.append(makeSlice(text: currentText, start: currentStart, end: currentEnd, pageBoundaries: pageBoundaries))
        }
        return chunks
    }

    private func makeSlice(
        text: String,
        start: Int,
        end: Int,
        pageBoundaries: [(page: Int, startChar: Int)]?
    ) -> ChunkSlice {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageNumber = pageBoundaries.flatMap { boundaries -> Int? in
            // The chunk's start char lives on whichever page's range contains it.
            // Find the last page whose startChar is <= start. That's the page this chunk begins on.
            var page: Int?
            for (p, pStart) in boundaries {
                if pStart <= start {
                    page = p
                } else {
                    break
                }
            }
            return page
        }
        return ChunkSlice(text: trimmed, charStart: start, charEnd: end, pageNumber: pageNumber)
    }

    /// Returns the trailing substring of `s` up to `length` characters, plus the number of
    /// characters dropped from the head. Used to seed the next chunk's overlap.
    private func tailOverlap(of s: String, length: Int) -> (text: String, charsDropped: Int) {
        guard s.count > length else { return (s, 0) }
        let dropCount = s.count - length
        let startIndex = s.index(s.startIndex, offsetBy: dropCount)
        return (String(s[startIndex...]), dropCount)
    }
}
