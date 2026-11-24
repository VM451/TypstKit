import Foundation

/// One frontend per input format (port of `formats/mod.rs`).
enum Formats {
    static func parse(_ bytes: [UInt8], _ format: Format) -> Result<AnyTypDocument, ConvertError> {
        switch format {
        case .excel: return SheetFormat.parse(bytes)
        case .csv: return CsvFormat.parse(bytes)
        case .tsv: return CsvFormat.parseTSV(bytes)
        case .docx: return DocxFormat.parse(bytes)
        case .odt, .ods, .odp: return OdfFormat.parse(bytes)
        case .pptx: return PptxFormat.parse(bytes)
        case .epub: return EpubFormat.parse(bytes)
        case .rtf: return RtfFormat.parse(bytes)
        // RTF or HTML files wearing a .doc/.xls extension are common in the wild.
        case .doc where bytes.starts(with: [0x7B, 0x5C, 0x72, 0x74, 0x66]):
            return RtfFormat.parse(bytes)
        case .doc: return DocFormat.parse(bytes)
        case .ppt: return PptFormat.parse(bytes)
        case .pdf: return PdfFormat.parse(bytes)
        case .markdown: return MarkdownFormat.parse(bytes)
        case .html: return HtmlFormat.parse(bytes)
        case .latex: return LatexFormat.parse(bytes)
        case .json: return JsonFormat.parse(bytes)
        case .text: return TextFormat.parse(bytes)
        }
    }
}
