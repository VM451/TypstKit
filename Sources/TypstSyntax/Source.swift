import Foundation

/// A Typst source file containing the full source text, a mapping from byte
/// indices to lines/columns, and the parsed syntax tree.
///
/// All line and column indices start at zero, just like byte indices. Only for
/// user-facing display, you should add 1 to them.
///
/// Values of this type are cheap to clone. Like upstream's
/// `Arc<LazyHash<SourceInner>>`, clones share storage until an edit occurs,
/// at which point the tree is copied (upstream copies lazily inside the
/// reparser; here the whole tree is copied up front when the storage is
/// aliased).
///
/// Port of `source.rs` in `typst-syntax`.
public struct Source {
    /// The internal representation of a `Source`.
    final class Storage {
        var id: FileId
        var root: SyntaxNode
        var lines: Lines

        init(id: FileId, root: SyntaxNode, lines: Lines) {
            self.id = id
            self.root = root
            self.lines = lines
        }

        /// An independent copy for copy-on-write.
        func copy() -> Storage {
            Storage(id: id, root: root.copy(), lines: lines.copy())
        }
    }

    private var storage: Storage

    /// Create a new source file. This parses the input text and assigns span
    /// numbers to the parsed tree.
    public init(id: FileId, text: String) {
        let root = parse(text)
        try! root.numberize(id: id, within: Span.FULL)
        storage = Storage(id: id, root: root, lines: Lines(text: text))
    }

    /// Create a new source file with an already created syntax tree.
    public init(id: FileId, text: String, root: SyntaxNode) {
        storage = Storage(id: id, root: root, lines: Lines(text: text))
    }

    /// The root node of the file's untyped syntax tree.
    public var root: SyntaxNode { storage.root }

    /// The id of the source file.
    public var id: FileId { storage.id }

    /// The whole source as a string.
    public var text: String { storage.lines.text }

    /// An acceleration structure for conversion of UTF-8, UTF-16 and
    /// line/column indices.
    public var lines: Lines { storage.lines }

    /// Fully replace the source text.
    ///
    /// This performs a naive (suffix/prefix-based) diff of the old and new
    /// text to produce the smallest single edit that transforms old into new
    /// and then calls `edit` with it.
    ///
    /// Returns the range in the new source that was ultimately reparsed.
    @discardableResult
    public mutating func replace(_ new: String) -> Range<Int> {
        guard let (prefix, suffix) = storage.lines.replacementRange(new) else {
            return 0..<0
        }

        let old = text
        let replace = prefix..<(old.utf8.count - suffix)
        let newBytes = Array(new.utf8)
        let with = String(decoding: newBytes[prefix..<(newBytes.count - suffix)],
                          as: UTF8.self)
        return edit(replace, with: with)
    }

    /// Edit the source file by replacing the given range.
    ///
    /// Returns the range in the new source that was ultimately reparsed.
    ///
    /// The method traps if the `replace` range is out of bounds.
    @discardableResult
    public mutating func edit(_ replace: Range<Int>, with: String) -> Range<Int> {
        // Copy-on-write: upstream clones the `Arc`'d inner when shared; since
        // `SyntaxNode` mutates in place here, an aliased storage must copy
        // its whole tree first to keep clones independent.
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
        }

        // Update the text and lines.
        storage.lines.edit(replace, with: with)

        // Incrementally reparse the replaced range.
        let result = reparse(
            root: storage.root,
            text: storage.lines.text,
            replaced: replace,
            replacementLen: with.utf8.count
        )
        storage.root = result.root
        return result.reparsed
    }

    /// Find the node with the given span.
    ///
    /// Returns `nil` if the span does not point into this source file.
    public func find(_ span: Span) -> LinkedNode? {
        if span.id != id {
            return nil
        }
        return LinkedNode(root: storage.root).find(span: span)
    }

    /// Get the byte range for the given span number (and optional sub-range)
    /// in this file.
    ///
    /// The main way to get a `SpanNumber` is by unpacking a span, but it's
    /// likely easier to use a world `range` helper instead.
    public func range(
        num: SpanNumber,
        subRange: SubRange? = nil
    ) -> Range<Int>? {
        guard let node = LinkedNode(root: storage.root).findNumber(num) else {
            return nil
        }
        let overall = node.range()
        if let subRange {
            let range = subRange.toAbsolute(overall.lowerBound)
            assert(range.upperBound <= overall.upperBound)
            return range
        }
        return overall
    }
}

extension Source: CustomStringConvertible {
    public var description: String { "Source(\(id.vpath))" }
}
