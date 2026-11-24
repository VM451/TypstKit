import Foundation
import PDFKit

/// PDF frontend (port of `formats/pdf.rs`). The Rust original delegates to
/// the `pdf-inspector` crate; the pure-Swift path uses PDFKit's text
/// extraction. Scanned or image-only pages error with `NeedsOcr` naming
/// those pages so output missing them never passes as complete.
enum PdfFormat {
    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        guard let doc = PDFDocument(data: Data(bytes)) else {
            return .failure(.malformed(part: nil, detail: "not a PDF or unreadable PDF structure"))
        }
        let pageCount = doc.pageCount
        var texts: [String] = []
        var ocrPages: [Int] = []
        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            let s = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty {
                ocrPages.append(i + 1) // 1-indexed
            }
            texts.append(s)
        }
        if !ocrPages.isEmpty {
            return .failure(.needsOCR(pages: ocrPages, pageCount: pageCount))
        }
        let markdown = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.unsupported(
                "PDF has no extractable text (\(pageCount) pages)"))
        }
        return .success(MarkdownFormat.parseStr(markdown))
    }
}
