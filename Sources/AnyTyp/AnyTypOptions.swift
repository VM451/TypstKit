import Foundation

/// Rendering and asset-extraction options when converting documents to Typst (`.typ`).
public struct AnyTypOptions: Sendable, Equatable {
    /// Prepend a standalone Typst preamble (`#set page(...)`, `#set par(...)`).
    public var standalone: Bool

    /// Optional document title for `#set document(title: "...")` (implies `standalone = true`).
    public var title: String?

    /// Directory on disk where embedded images (`png`, `jpg`, `gif`, `svg`, `webp`) are written.
    public var extractAssetsTo: URL?

    /// Logical path prefix emitted inside `#image("<prefix>/asset-001.png")`.
    /// Defaults to `extractAssetsTo.lastPathComponent` when `extractAssetsTo` is set.
    public var assetsPrefix: String?

    public init(
        standalone: Bool = false,
        title: String? = nil,
        extractAssetsTo: URL? = nil,
        assetsPrefix: String? = nil
    ) {
        self.standalone = standalone
        self.title = title
        self.extractAssetsTo = extractAssetsTo
        self.assetsPrefix = assetsPrefix
    }
}
