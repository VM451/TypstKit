import Foundation

/// Plain text (`.txt`) frontend (port of `formats/text.rs`).
enum TextFormat {
    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        let text = SharedText.decode(bytes)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var blocks: [AnyTypBlock] = []
        var curLines: [String] = []

        func flush() {
            guard !curLines.isEmpty else { return }
            var inlines: [AnyTypInline] = []
            for (idx, line) in curLines.enumerated() {
                if idx > 0 { inlines.append(.lineBreak) }
                let cleaned = SharedText.clean(line)
                if !cleaned.isEmpty { inlines.append(.text(cleaned, style: .plain)) }
            }
            curLines.removeAll()
            if !inlinesAreEmpty(inlines) {
                blocks.append(.paragraph(inlines))
            }
        }

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.allSatisfy({ $0.isWhitespace }) {
                flush()
            } else {
                curLines.append(String(line))
            }
        }
        flush()
        return .success(AnyTypDocument(blocks: blocks))
    }
}
