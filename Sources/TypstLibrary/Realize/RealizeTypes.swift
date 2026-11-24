import Foundation
import TypstSyntax
import TypstUtils

/// Defines what kind of realization we are performing.
///
/// Port of `RealizationKind` in `routines.rs`. Upstream carries `&mut`
/// references to document metadata; Swift uses reference boxes so the kind
/// can be stored in the realization state.
public enum RealizationKind {
    /// The realization for bundles. The content is realized into documents and
    /// assets.
    case bundle
    /// The root realization for a document. Requires mutable references to
    /// document metadata that will be filled from `set document` rules.
    case document(info: DocumentInfoRef, options: DocumentFormatOptionsRef)
    /// A nested realization in a container (e.g. a `block`).
    /// Requires a mutable reference to an enum that will be set to
    /// `FragmentKind.inline` if the fragment's content was fully inline.
    case fragment(kind: FragmentKindRef)
    /// A nested realization in a paragraph (i.e. a `par`).
    case par
    /// A realization within math.
    case math

    /// Whether this is the bundle realization.
    var isBundle: Bool { if case .bundle = self { return true }; return false }
    /// Whether this is a document realization.
    var isDocument: Bool { if case .document = self { return true }; return false }
}

/// The kind of fragment output that realization produced.
///
/// Port of `FragmentKind` in `routines.rs`.
public enum FragmentKind: Sendable, Hashable {
    /// The fragment's contents were fully inline.
    case inline
    /// The fragment contained non-inline content.
    case block
}

/// Mutable box for `DocumentInfo` during document realization.
public final class DocumentInfoRef: @unchecked Sendable {
    public var value = DocumentInfo()
    public init(_ value: DocumentInfo = DocumentInfo()) { self.value = value }
}

/// Mutable box for `DocumentFormatOptions` during document realization.
public final class DocumentFormatOptionsRef: @unchecked Sendable {
    public var value = DocumentFormatOptions()
    public init(_ value: DocumentFormatOptions = DocumentFormatOptions()) {
        self.value = value
    }
}

/// Mutable box for `FragmentKind` during fragment realization.
public final class FragmentKindRef: @unchecked Sendable {
    public var value: FragmentKind = .block
    public init(_ value: FragmentKind = .block) { self.value = value }
}

/// Temporary storage for lifetime extension during realization.
///
/// Port of `Arenas` in `routines.rs`. Upstream uses typed arenas to extend
/// content/style lifetimes; Swift's ARC handles this, so this is a marker
/// type kept for API parity.
public struct Arenas: Sendable {
    public init() {}
}

/// A pair of content and a style chain that applies to it.
///
/// Port of `Pair` in `routines.rs`.
public typealias RealizePair = (content: Content, styles: StyleChain)

/// Details about the document.
///
/// Port of `DocumentInfo` in `model/document.rs`.
public struct DocumentInfo: Sendable, Hashable {
    /// The document's title.
    public var title: Str?
    /// The document's author(s).
    public var author: [Str] = []
    /// The document's description.
    public var description: Str?
    /// The document's keywords.
    public var keywords: [Str] = []
    /// The document's creation date.
    public var date: Smart<Datetime?> = .auto
    /// The document's language.
    ///
    /// Upstream uses `Smart<Locale>`; `Locale` lands with `text/lang.rs`, so
    /// this stores the raw components for now.
    public var locale: Smart<DocumentLocale> = .auto

    public init() {}

    /// Populate this document info with details from the given styles.
    /// Port of upstream `DocumentInfo::populate`.
    public mutating func populate(_ styles: StyleChain) {
        let doc = Element(DocumentElem.self)
        if styles.has(doc, 0),
           case let .content(c)? = styles.getValue(doc, 0) {
            title = Str(c.plainText)
        }
        if styles.has(doc, 1),
           case let .array(a)? = styles.getValue(doc, 1) {
            author = a.items.compactMap {
                if case let .str(s) = $0 { return s }
                return nil
            }
        }
        if styles.has(doc, 2),
           case let .content(c)? = styles.getValue(doc, 2) {
            description = Str(c.plainText)
        }
        if styles.has(doc, 3),
           case let .array(a)? = styles.getValue(doc, 3) {
            keywords = a.items.compactMap {
                if case let .str(s) = $0 { return s }
                return nil
            }
        }
        if styles.has(doc, 4) {
            switch styles.getValue(doc, 4) {
            case .auto?: date = .auto
            case .none?: date = .custom(nil)
            case let .datetime(d)?: date = .custom(d)
            default: break
            }
        }
    }

    /// Populate this document info with locale details from the given styles.
    /// Port of upstream `DocumentInfo::populate_locale`.
    public mutating func populateLocale(_ styles: StyleChain) {
        if case .custom = locale { return }

        var locale = DocumentLocale()
        var hasLocale = false
        let text = Element(TextElem.self)
        if styles.has(text, 1),
           case let .str(s)? = styles.getValue(text, 1) {
            locale.lang = s
            hasLocale = true
        }
        if styles.has(text, 2),
           case let .str(s)? = styles.getValue(text, 2) {
            locale.region = s
            hasLocale = true
        }
        self.locale = hasLocale ? .custom(locale) : .auto
    }
}

/// Format options that have been configured by the document.
///
/// Port of `DocumentFormatOptions` in `format.rs` — minimal surface until
/// export formats land.
public struct DocumentFormatOptions: Sendable, Hashable {
    public init() {}

    /// Populate the format options with details from the given styles.
    public mutating func populate(_ styles: StyleChain, span: Span) {}
}

/// Document locale components.
///
/// Placeholder for upstream `Locale` (`text/lang.rs`) until that module lands.
public struct DocumentLocale: Sendable, Hashable {
    public var lang: Str = Str("")
    public var region: Str?
    public init() {}
}
