import Foundation

/// Indicates whether the cursor is before the related byte index, or after.
public enum Side {
    case before
    case after
}

/// A syntax node in a context.
///
/// Knows its exact offset in the file and provides access to its children,
/// parent and siblings. Port of `LinkedNode` in `node.rs`.
///
/// **Note that all sibling and leaf accessors skip over trivia!**
public final class LinkedNode {
    /// The underlying syntax node.
    public let node: SyntaxNode
    /// The parent of this node.
    public let parent: LinkedNode?
    /// The index of this node in its parent's children array.
    public let index: Int
    /// This node's byte offset in the source file.
    public let offset: Int

    /// Start a new traversal at a root node.
    public convenience init(root: SyntaxNode) {
        self.init(node: root, parent: nil, index: 0, offset: 0)
    }

    init(node: SyntaxNode, parent: LinkedNode?, index: Int, offset: Int) {
        self.node = node
        self.parent = parent
        self.index = index
        self.offset = offset
    }

    /// The kind of this node.
    public var kind: SyntaxKind { node.kind }
    /// The span of this node.
    public var span: Span { node.span }
    /// The byte length of this node.
    public var len: Int { node.len }
    /// The text of the node if it is a leaf or error node.
    public var leafText: String { node.leafText }
    /// Whether this is a leaf node.
    var isLeaf: Bool { node.isLeaf }
    /// The number of descendants, including the node itself.
    var descendants: Int { node.descendants }
    /// The upper bound of assigned numbers in this subtree.
    var upper: UInt64 { node.upper }
    /// Whether the node has diagnostic errors and/or warnings.
    public var diagnosis: Diagnosis { node.diagnosis }

    /// Clone the full text, traversing inner nodes.
    public func fullText() -> String { node.fullText() }

    /// Whether the two syntax nodes are the same apart from spans.
    public func spanlessEq(_ other: LinkedNode) -> Bool {
        node.spanlessEq(other.node)
    }

    /// The error and warning diagnostics for this node and its descendants.
    public func errorsAndWarnings() -> (errors: [SyntaxDiagnostic], warnings: [SyntaxDiagnostic]) {
        node.errorsAndWarnings()
    }

    /// The byte range of this node in the source file.
    public func range() -> Range<Int> {
        offset..<(offset + node.len)
    }

    /// An iterator over this node's children.
    public func children() -> LinkedChildren {
        LinkedChildren(parent: self)
    }

    /// Find a descendant with the given span.
    public func find(span: Span) -> LinkedNode? {
        switch span.kind {
        case .detached:
            return nil
        case .number(_, let num):
            return findNumber(num)
        case .range(_, let range):
            return findRange(start: range.lowerBound, end: range.upperBound)
        }
    }

    /// Find the descendant whose span number matches the given number.
    ///
    /// This relies on the ordering guarantees of numbered spans:
    /// - The number of a parent is smaller than the numbers of all its children
    /// - The numbers of sibling nodes always increase from left to right
    func findNumber(_ target: SpanNumber) -> LinkedNode? {
        let number = node.span.number
        if number == target.raw {
            return self
        }

        // The parent of a subtree has a smaller span number than all of its
        // descendants. Therefore, we can bail out early if the target span's
        // number is smaller than our number.
        if node.isInner && number < target.raw {
            var iter = children().makeIterator()
            var child = iter.next()
            while let current = child {
                let next = iter.next()
                // Every node in this child's subtree has a smaller span number
                // than the next sibling. Therefore we only need to recurse if
                // the next sibling's span number is larger than the target.
                if next == nil || next!.node.span.number > target.raw,
                   let found = current.findNumber(target) {
                    return found
                }
                child = next
            }
        }

        return nil
    }

    /// Find the descendant whose byte range matches the given range exactly.
    func findRange(start: Int, end: Int) -> LinkedNode? {
        if start == offset && end == offset + node.len {
            return self
        }
        for child in children() {
            // Descend into the single child which fully covers the range.
            if child.offset <= start && end <= child.offset + child.node.len {
                return child.findRange(start: start, end: end)
            }
        }
        return nil
    }

    /// Get the `SyntaxMode` we will be in when immediately after this node.
    ///
    /// Unlike some other `LinkedNode` methods, this does not treat all trivia
    /// the same: it returns `nil` for both comments and the bodies of raw text
    /// and returns a mode for whitespace (based on the parent's mode). The
    /// only other way this would return `nil` is when inside a partial tree,
    /// i.e. one not rooted in `Markup`, `Math`, or `Code`.
    ///
    /// Also note that errors inherit the mode of their parent.
    public func modeAfter() -> SyntaxMode? {
        switch node.kind.modeAfter {
        case .known(let mode):
            return mode
        // Comments and the bodies of raw text have no mode.
        case .none:
            return nil
        case .text where parentKind() == .raw:
            return nil
        case .rawDelim where index == 0:
            return nil
        // Text not under raw is always markup.
        case .text:
            return .markup
        // An opening dollar sign starts math mode.
        case .dollar where index == 0:
            return .math
        // Spaces at the left/right of an equation are still in math mode.
        case .space where parentKind() == .equation:
            return .math
        // The position after something embedded with a hash is still code.
        case .embeddable
            where prevSiblingWithTrivia()?.kind == .hash:
            return .code
        // Otherwise, we're simply based on our parent's mode.
        case .parent, .rawDelim, .space, .dollar, .embeddable:
            return parentMode()
        }
    }

    /// Get the `SyntaxMode` we will be in when immediately after the parent
    /// of this node.
    public func parentMode() -> SyntaxMode? {
        parent?.modeAfter()
    }
}

/// Access to parents and siblings.
extension LinkedNode {
    /// Get the first previous non-trivia sibling node.
    public func prevSibling() -> LinkedNode? {
        guard let parent else { return nil }
        let children = parent.node.children
        var offset = self.offset
        for i in (0..<self.index).reversed() {
            let child = children[i]
            offset -= child.len
            if !child.kind.isTrivia {
                return LinkedNode(node: child, parent: parent, index: i, offset: offset)
            }
        }
        return nil
    }

    /// Get the first previous sibling node, including potential trivia.
    public func prevSiblingWithTrivia() -> LinkedNode? {
        guard let parent, self.index > 0 else { return nil }
        let i = self.index - 1
        let child = parent.node.children[i]
        return LinkedNode(node: child, parent: parent, index: i,
                          offset: self.offset - child.len)
    }

    /// Get the next non-trivia sibling node.
    public func nextSibling() -> LinkedNode? {
        guard let parent else { return nil }
        let children = parent.node.children
        var offset = self.offset + self.len
        for i in (self.index + 1)..<children.count {
            let child = children[i]
            if !child.kind.isTrivia {
                return LinkedNode(node: child, parent: parent, index: i, offset: offset)
            }
            offset += child.len
        }
        return nil
    }

    /// Get the next sibling node, including potential trivia.
    public func nextSiblingWithTrivia() -> LinkedNode? {
        guard let parent,
              self.index + 1 < parent.node.children.count else { return nil }
        let i = self.index + 1
        let child = parent.node.children[i]
        return LinkedNode(node: child, parent: parent, index: i,
                          offset: self.offset + self.len)
    }

    /// Get the kind of this node's parent.
    public func parentKind() -> SyntaxKind? {
        parent?.node.kind
    }

    /// Get the kind of this node's first previous non-trivia sibling.
    public func prevSiblingKind() -> SyntaxKind? {
        prevSibling()?.kind
    }

    /// Get the kind of this node's next non-trivia sibling.
    public func nextSiblingKind() -> SyntaxKind? {
        nextSibling()?.kind
    }
}

/// Access to leaves.
extension LinkedNode {
    /// Get the rightmost non-trivia leaf before this node.
    public func prevLeaf() -> LinkedNode? {
        var node = self
        while let prev = node.prevSibling() {
            if let leaf = prev.rightmostLeaf() {
                return leaf
            }
            node = prev
        }
        return parent?.prevLeaf()
    }

    /// Find the leftmost contained non-trivia leaf.
    public func leftmostLeaf() -> LinkedNode? {
        if isLeaf && !kind.isTrivia && !kind.isError {
            return self
        }

        for child in children() {
            if let leaf = child.leftmostLeaf() {
                return leaf
            }
        }

        return nil
    }

    /// Get the leaf immediately before the specified byte offset.
    private func leafBefore(_ cursor: Int) -> LinkedNode? {
        if node.children.isEmpty && cursor <= offset + node.len {
            return self
        }

        var offset = self.offset
        let count = node.children.count
        var i = 0
        for child in children() {
            let len = child.node.len
            if (offset < cursor && cursor <= offset + len)
                || (offset == cursor && i + 1 == count) {
                return child.leafBefore(cursor)
            }
            offset += len
            i += 1
        }

        return nil
    }

    /// Get the leaf after the specified byte offset.
    private func leafAfter(_ cursor: Int) -> LinkedNode? {
        if node.children.isEmpty && cursor < offset + node.len {
            return self
        }

        var offset = self.offset
        for child in children() {
            let len = child.node.len
            if offset <= cursor && cursor < offset + len {
                return child.leafAfter(cursor)
            }
            offset += len
        }

        return nil
    }

    /// Get the leaf at the specified byte offset.
    public func leafAt(_ cursor: Int, side: Side) -> LinkedNode? {
        switch side {
        case .before: return leafBefore(cursor)
        case .after: return leafAfter(cursor)
        }
    }

    /// Find the rightmost contained non-trivia leaf.
    public func rightmostLeaf() -> LinkedNode? {
        if isLeaf && !kind.isTrivia {
            return self
        }

        for child in children().reversed() {
            if let leaf = child.rightmostLeaf() {
                return leaf
            }
        }

        return nil
    }

    /// Get the leftmost non-trivia leaf after this node.
    public func nextLeaf() -> LinkedNode? {
        var node = self
        while let next = node.nextSibling() {
            if let leaf = next.leftmostLeaf() {
                return leaf
            }
            node = next
        }
        return parent?.nextLeaf()
    }
}

/// An iterator over the children of a linked node.
public struct LinkedChildren: Sequence, IteratorProtocol {
    public typealias Element = LinkedNode
    public typealias Iterator = LinkedChildren

    /// The parent whose children we're iterating.
    let parent: LinkedNode
    /// The underlying syntax nodes.
    let nodes: [SyntaxNode]
    /// The index of the next child from the front.
    var front: Int
    /// The index after the next child from the back.
    var back: Int
    /// The byte offset of the next child's start.
    var frontOffset: Int
    /// The byte offset after the final child.
    var backOffset: Int

    init(parent: LinkedNode) {
        self.parent = parent
        self.nodes = parent.node.children
        self.front = 0
        self.back = nodes.count
        self.frontOffset = parent.offset
        self.backOffset = parent.offset + parent.node.len
    }

    public mutating func next() -> LinkedNode? {
        guard front < back else { return nil }
        let node = nodes[front]
        let offset = frontOffset
        frontOffset += node.len
        let result = LinkedNode(node: node, parent: parent, index: front, offset: offset)
        front += 1
        return result
    }

    public mutating func nextBack() -> LinkedNode? {
        guard front < back else { return nil }
        back -= 1
        let node = nodes[back]
        backOffset -= node.len
        return LinkedNode(node: node, parent: parent, index: back, offset: backOffset)
    }

    /// The number of remaining children.
    public var count: Int { Swift.max(0, back - front) }

    public func makeIterator() -> LinkedChildren { self }
}
