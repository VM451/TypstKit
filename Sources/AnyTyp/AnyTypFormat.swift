import Foundation

/// Supported input document formats for `AnyTyp`.
public enum AnyTypFormat: String, CaseIterable, Codable, Sendable, Hashable {
    case doc
    case docx
    case odt
    case pdf
    case ppt
    case pptx
    case rtf
    case epub
    case xlsx
    case ods
    case odp
    case csv
    case tsv
    case md
    case html
    case tex
    case json
    case txt

    /// Detect container/header format directly from in-memory bytes.
    /// Returns `nil` for signature-less plain-text formats.
    public static func detect(from data: Data) -> AnyTypFormat? {
        Format.detect(from: [UInt8](data)).map(AnyTypFormat.init)
    }

    /// Resolve a format from a file extension (with or without leading `.`),
    /// including aliases such as `docm`, `xls`, `xlsb`, `ppsx`, `markdown`,
    /// `latex`, and `htm`.
    public init?(fileExtension: String) {
        guard let format = Format.fromExtension(fileExtension) else { return nil }
        self.init(format)
    }

    /// Resolve a format from a file URL's path extension.
    public init?(url: URL) {
        self.init(fileExtension: url.pathExtension)
    }

    init(_ format: Format) {
        switch format {
        case .doc: self = .doc
        case .docx: self = .docx
        case .odt: self = .odt
        case .pdf: self = .pdf
        case .ppt: self = .ppt
        case .pptx: self = .pptx
        case .rtf: self = .rtf
        case .epub: self = .epub
        case .excel: self = .xlsx
        case .ods: self = .ods
        case .odp: self = .odp
        case .csv: self = .csv
        case .tsv: self = .tsv
        case .markdown: self = .md
        case .html: self = .html
        case .latex: self = .tex
        case .json: self = .json
        case .text: self = .txt
        }
    }

    var format: Format {
        switch self {
        case .doc: return .doc
        case .docx: return .docx
        case .odt: return .odt
        case .pdf: return .pdf
        case .ppt: return .ppt
        case .pptx: return .pptx
        case .rtf: return .rtf
        case .epub: return .epub
        case .xlsx: return .excel
        case .ods: return .ods
        case .odp: return .odp
        case .csv: return .csv
        case .tsv: return .tsv
        case .md: return .markdown
        case .html: return .html
        case .tex: return .latex
        case .json: return .json
        case .txt: return .text
        }
    }
}
