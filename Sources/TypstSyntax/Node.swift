import Foundation

/// A node in the untyped syntax tree.
///
/// Port of `typst-syntax/src/node.rs`. Unlike upstream's `Arc`-based
/// copy-on-write, this uses a class hierarchy with in-place mutation.
/// Nodes are not shared between trees until the incremental reparser
/// lands; mutation methods therefore mutate in place.
public final class SyntaxNode {
    /// The underlying node data, possibly wrapped in warnings.
    enum Data {
        case leaf(String, SyntaxKind)
        case inner(InnerNode, SyntaxKind)
        case error(ErrorNode, SyntaxKind)
        case warning(WarningNode, SyntaxKind)

        /// Deep copy of this data payload.
        func copy() -> Data {
            switch self {
            case .leaf(let text, let kind): return .leaf(text, kind)
            case .inner(let inner, let kind): return .inner(inner.copy(), kind)
            case .error(let error, let kind): return .error(error.copy(), kind)
            case .warning(let warning, let kind):
                return .warning(warning.copy(), kind)
            }
        }
    }

    var data: Data
    /// The node's span.
    public internal(set) var span: Span

    init(data: Data, span: Span = .detached) {
        self.data = data
        self.span = span
    }

    /// Create a new leaf node.
    public static func leaf(_ kind: SyntaxKind, _ text: String) -> SyntaxNode {
        precondition(!kind.isError, "leaf cannot be an error")
        return SyntaxNode(data: .leaf(text, kind))
    }

    /// Create a new inner node with children.
    public static func inner(_ kind: SyntaxKind, _ children: [SyntaxNode]) -> SyntaxNode {
        precondition(!kind.isError, "inner cannot be an error")
        return SyntaxNode(data: .inner(InnerNode(children: children), kind))
    }

    /// Create a new error node.
    public static func error(_ message: String, _ text: String) -> SyntaxNode {
        SyntaxNode(data: .error(ErrorNode(message: message, text: text), .error))
    }

    /// Create a dummy node of the given kind.
    public static func placeholder(_ kind: SyntaxKind) -> SyntaxNode {
        precondition(!kind.isError, "cannot create error placeholder")
        return SyntaxNode(data: .leaf("", kind))
    }

    /// The type of the node.
    public var kind: SyntaxKind {
        switch data {
        case .leaf(_, let k), .inner(_, let k), .error(_, let k), .warning(_, let k):
            return k
        }
    }

    /// `true` if the length is 0.
    public var isEmpty: Bool { len == 0 }

    /// The byte length of the node in the source text.
    public var len: Int {
        switch underlying {
        case .leaf(let text, _): return text.utf8.count
        case .inner(let inner, _): return inner.len
        case .error(let err, _): return err.text.utf8.count
        }
    }

    /// The text of the node if it is a leaf or error node.
    /// Returns the empty string for inner nodes.
    public var leafText: String {
        switch underlying {
        case .leaf(let text, _): return text
        case .inner: return ""
        case .error(let err, _): return err.text
        }
    }

    /// The node's children (empty for leaf/error nodes).
    public var children: [SyntaxNode] {
        if case .inner(let inner, _) = underlying { return inner.children }
        return []
    }

    /// Whether this is a leaf node.
    var isLeaf: Bool {
        if case .leaf = underlying { return true }
        return false
    }

    /// Whether this is an inner node.
    var isInner: Bool {
        if case .inner = underlying { return true }
        return false
    }

    /// The number of descendants, including the node itself.
    var descendants: Int {
        switch underlying {
        case .leaf, .error: return 1
        case .inner(let inner, _): return inner.descendants
        }
    }

    /// The upper bound of assigned numbers in this subtree.
    var upper: UInt64 {
        switch underlying {
        case .leaf, .error: return span.number + 1
        case .inner(let inner, _): return inner.upper
        }
    }

    /// Clone the full text, traversing inner nodes.
    public func fullText() -> String {
        var buffer = ""
        buffer.reserveCapacity(len)
        traverse { node in
            switch node.underlying {
            case .leaf(let text, _): buffer += text
            case .inner: break
            case .error(let err, _): buffer += err.text
            }
            return node.children
        }
        return buffer
    }

    /// Whether the node has diagnostic errors and/or warnings.
    public var diagnosis: Diagnosis {
        let base: Diagnosis
        switch underlying {
        case .leaf: base = Diagnosis()
        case .inner(let inner, _): base = inner.diagnosis
        case .error: base = Diagnosis(errors: true)
        }
        if case .warning = data {
            return Diagnosis(errors: base.errors, warnings: true)
        }
        return base
    }

    /// The error and warning diagnostics for this node and its descendants.
    public func errorsAndWarnings() -> (errors: [SyntaxDiagnostic], warnings: [SyntaxDiagnostic]) {
        var errors: [SyntaxDiagnostic] = []
        var warnings: [SyntaxDiagnostic] = []
        traverse { node in
            var d = node.data
            while true {
                switch d {
                case .inner(let inner, _) where inner.diagnosis.either:
                    return inner.children
                case .leaf, .inner:
                    return []
                case .error(let err, _):
                    errors.append(err.diagnostic(span: node.span))
                    return []
                case .warning(let warn, _):
                    warnings.append(warn.diagnostic(span: node.span))
                    d = warn.child
                }
            }
        }
        return (errors, warnings)
    }

    /// Traverse the tree in-order, calling `f` on each node before recursing
    /// on the returned children slice (empty prunes the traversal).
    ///
    /// Implemented with an explicit stack so deeply nested trees cannot
    /// overflow the call stack.
    func traverse(_ f: (SyntaxNode) -> [SyntaxNode]) {
        var stack = [self]
        while let node = stack.popLast() {
            let children = f(node)
            stack.append(contentsOf: children.reversed())
        }
    }

    /// Add a warning message to an existing node.
    public func warn(_ message: String) {
        let kind = self.kind
        let child = data
        data = .warning(WarningNode(child: child, subRange: nil, message: message), kind)
    }

    /// Add a warning around this node at a sub-range of its text.
    public func warnAt(_ range: Range<Int>, _ message: String) {
        precondition(range.upperBound <= len, "sub-range exceeds node length")
        guard let sub = SubRange(range.lowerBound, range.upperBound) else {
            preconditionFailure("invalid sub-range")
        }
        let kind = self.kind
        let child = data
        data = .warning(WarningNode(child: child, subRange: sub, message: message), kind)
    }

    /// Add a hint to an existing error or warning node.
    public func hint(_ message: String) {
        switch data {
        case .error(let err, _): err.hints.append((message, nil))
        case .warning(let warn, _): warn.hints.append((message, nil))
        default: preconditionFailure("expected an error or warning")
        }
    }

    /// Add a hint at a sub-range of an error or warning node.
    public func hintAt(_ range: Range<Int>, _ message: String) {
        precondition(range.upperBound <= len, "sub-range exceeds node length")
        guard let sub = SubRange(range.lowerBound, range.upperBound) else {
            preconditionFailure("invalid sub-range")
        }
        switch data {
        case .error(let err, _): err.hints.append((message, sub))
        case .warning(let warn, _): warn.hints.append((message, sub))
        default: preconditionFailure("expected an error or warning")
        }
    }

    /// Add multiple hints while building an error or warning.
    @discardableResult
    public func withHints(_ newHints: [String]) -> SyntaxNode {
        for h in newHints { hint(h) }
        return self
    }

    /// Access the underlying data, descending past warnings.
    enum Underlying {
        case leaf(String, SyntaxKind)
        case inner(InnerNode, SyntaxKind)
        case error(ErrorNode, SyntaxKind)
    }

    var underlying: Underlying {
        var d = data
        while true {
            switch d {
            case .leaf(let t, let k): return .leaf(t, k)
            case .inner(let i, let k): return .inner(i, k)
            case .error(let e, let k): return .error(e, k)
            case .warning(let w, _): d = w.child
            }
        }
    }

    /// Convert the node to another kind (mutates through warnings).
    func convertToKind(_ newKind: SyntaxKind) {
        precondition(!newKind.isError, "cannot convert to an error")
        precondition(!kind.isError, "cannot convert an error")
        data = Self.convertKind(data, newKind)
    }

    private static func convertKind(_ d: Data, _ newKind: SyntaxKind) -> Data {
        switch d {
        case .leaf(let t, _): return .leaf(t, newKind)
        case .inner(let i, _): return .inner(i, newKind)
        case .error: preconditionFailure("cannot convert an error")
        case .warning(let w, _):
            w.child = convertKind(w.child, newKind)
            return .warning(w, newKind)
        }
    }

    /// Convert the node to an error if it isn't already one.
    func convertToError(_ message: String) {
        if !kind.isError {
            let text = fullText()
            data = .error(ErrorNode(message: message, text: text), .error)
        }
    }

    /// Convert the node to an error stating that `expected` was expected.
    func expected(_ expected: String) {
        let k = kind
        convertToError("expected \(expected), found \(k.name)")
        if k.isKeyword && (expected == "identifier" || expected == "pattern") {
            hint("keyword `\(leafText)` is not allowed as an identifier; try `\(leafText)_` instead")
        }
    }

    /// Convert the node to an error stating it was unexpected.
    func unexpected() {
        convertToError("unexpected \(kind.name)")
    }

    /// Assign spans to each node within a number range.
    func numberize(id: FileId, within: Range<UInt64>) throws {
        if within.lowerBound >= within.upperBound { throw Unnumberable() }
        if case .inner(let inner, _) = underlying {
            try inner.numberize(node: self, id: id, range: nil, within: within)
        } else {
            span = Span.fromNumber(id: id, (within.lowerBound + within.upperBound) / 2)
        }
    }

    /// Access an inner node mutably for incremental reparsing. Also returns
    /// the node's span and syntax kind since those are needed.
    ///
    /// Unlike `underlying`, this does not descend past wrapped warnings since
    /// reparsing under syntax warnings cannot be made sound.
    func reparseInnerNodeMut() -> (inner: InnerNode, kind: SyntaxKind, span: Span)? {
        guard case .inner(let inner, let kind) = data else { return nil }
        return (inner, kind, span)
    }

    /// Deep copy of this node and its whole subtree.
    ///
    /// Used for copy-on-write in `Source`: upstream's `Arc`-shared nodes are
    /// cloned lazily by the reparser, but since `SyntaxNode` is a class here,
    /// an aliased source must copy its tree before mutating.
    func copy() -> SyntaxNode {
        SyntaxNode(data: data.copy(), span: span)
    }

    /// Set a synthetic span for the node and all descendants, adding index
    /// hints to errors and warnings.
    public func synthesize(_ newSpan: Span) {
        synthesizeWith(offset: 0,
                       mapSpan: { _, _ in newSpan },
                       updateSubRange: { _, _ in },
                       addHint: { offset, len in
                           len == 0
                               ? "at index `\(offset)`"
                               : "from index `\(offset)` to `\(offset + len)`"
                       })
    }

    /// Set a raw range span for each node via a range mapper.
    /// Returns the mapper's length error if the text is longer than mapped.
    public func synthesizeMapped(id: FileId, mapper: RangeMapper) throws {
        if len > mapper.totalLen {
            throw RangeMapperError(
                message: "text length (\(len)) is greater than mapper length (\(mapper.totalLen))")
        }
        synthesizeWith(offset: 0,
                       mapSpan: { offset, len in
                           Span.fromRange(id: id, mapper.map(offset..<(offset + len)))
                       },
                       updateSubRange: { offset, sr in
                           if let sub = sr {
                               sr = mapper.mapSubRange(offset: offset, subRange: sub)
                           }
                       },
                       addHint: { _, _ in nil })
    }

    /// Shared span-synthesis walk. `updateSubRange` maps a node-relative
    /// sub-range through the mapper; `addHint` produces optional index hints.
    private func synthesizeWith(offset start: Int,
                                mapSpan: (Int, Int) -> Span,
                                updateSubRange: (Int, inout SubRange?) -> Void,
                                addHint: (Int, Int) -> String?) {
        var offset = start
        span = mapSpan(offset, len)
        switch data {
        case .leaf:
            break
        case .inner(let inner, _):
            inner.upper = span.number
            for child in inner.children {
                child.synthesizeWith(offset: offset, mapSpan: mapSpan,
                                      updateSubRange: updateSubRange, addHint: addHint)
                offset += child.len
            }
        case .error(let err, _):
            for i in err.hints.indices {
                updateSubRange(offset, &err.hints[i].1)
            }
            if let hint = addHint(offset, len) { err.hints.append((hint, nil)) }
        case .warning(let warn, _):
            let (origOffset, origLen): (Int, Int)
            if let sub = warn.subRange {
                let r = sub.toAbsolute(offset)
                origOffset = r.lowerBound
                origLen = r.count
            } else {
                origOffset = offset
                origLen = len
            }
            updateSubRange(offset, &warn.subRange)
            for i in warn.hints.indices {
                updateSubRange(offset, &warn.hints[i].1)
            }
            if let hint = addHint(origOffset, origLen) { warn.hints.append((hint, nil)) }
            // Descend into the wrapped child data within this same node,
            // mirroring upstream's `data = &mut warn.child` loop.
            synthesizeData(warn.child, offset: offset, mapSpan: mapSpan,
                           updateSubRange: updateSubRange, addHint: addHint)
        }
    }

    /// Synthesize spans through a bare `Data` payload (warning children).
    private func synthesizeData(_ d: Data, offset: Int,
                                mapSpan: (Int, Int) -> Span,
                                updateSubRange: (Int, inout SubRange?) -> Void,
                                addHint: (Int, Int) -> String?) {
        var offset = offset
        switch d {
        case .leaf, .error:
            // Leaf contributes no children; error text/hints were handled
            // when the error node itself was visited. Warning children that
            // are errors still need hint sub-range updates though — handle
            // them here for completeness.
            if case .error(let err, _) = d {
                for i in err.hints.indices { updateSubRange(offset, &err.hints[i].1) }
                _ = addHint(offset, len)
            }
        case .inner(let inner, _):
            inner.upper = span.number
            for child in inner.children {
                child.synthesizeWith(offset: offset, mapSpan: mapSpan,
                                      updateSubRange: updateSubRange, addHint: addHint)
                offset += child.len
            }
        case .warning(let warn, _):
            updateSubRange(offset, &warn.subRange)
            for i in warn.hints.indices { updateSubRange(offset, &warn.hints[i].1) }
            synthesizeData(warn.child, offset: offset, mapSpan: mapSpan,
                           updateSubRange: updateSubRange, addHint: addHint)
        }
    }

    /// Whether the two syntax nodes are the same apart from spans.
    ///
    /// Implemented iteratively with an explicit work list: deeply nested
    /// trees (e.g. the reparser's nesting tests) would overflow the stack with
    /// naive recursion.
    public func spanlessEq(_ other: SyntaxNode) -> Bool {
        kind == other.kind && Self.dataSpanlessEq(data, other.data)
    }

    private static func dataSpanlessEq(_ a: Data, _ b: Data) -> Bool {
        var stack: [(Data, Data)] = [(a, b)]
        while let (da, db) = stack.popLast() {
            guard kindOf(da) == kindOf(db) else { return false }
            switch (da, db) {
            case (.leaf(let x, _), .leaf(let y, _)):
                if x != y { return false }
            case (.inner(let x, _), .inner(let y, _)):
                guard x.len == y.len
                    && x.descendants == y.descendants
                    && x.diagnosis == y.diagnosis
                    && x.children.count == y.children.count
                else { return false }
                for (ca, cb) in zip(x.children, y.children) {
                    stack.append((ca.data, cb.data))
                }
            case (.error(let x, _), .error(let y, _)):
                if x != y { return false }
            case (.warning(let x, _), .warning(let y, _)):
                guard x.subRange == y.subRange, x.message == y.message,
                      x.hints.elementsEqual(y.hints, by: ==) else { return false }
                stack.append((x.child, y.child))
            default:
                return false
            }
        }
        return true
    }

    private static func kindOf(_ d: Data) -> SyntaxKind {
        switch d {
        case .leaf(_, let k), .inner(_, let k), .error(_, let k), .warning(_, let k):
            return k
        }
    }
}

/// An inner node in the untyped syntax tree.
final class InnerNode {
    /// The byte length of the node in the source.
    var len: Int
    /// The number of nodes in the whole subtree, including this node.
    var descendants: Int
    /// Whether this node or any children contain diagnostics.
    var diagnosis: Diagnosis
    /// The upper bound of this node's numbering range.
    var upper: UInt64
    /// This node's children, losslessly making up this node.
    var children: [SyntaxNode]

    init(children: [SyntaxNode]) {
        self.len = 0
        self.descendants = 0
        self.diagnosis = Diagnosis()
        self.upper = 0
        self.children = children
        recompute()
    }

    /// Recompute cached aggregates after mutating `children`.
    func recompute() {
        var len = 0
        var descendants = 1
        var diagnosis = Diagnosis()
        for child in children {
            len += child.len
            descendants += child.descendants
            diagnosis = diagnosis.or(child.diagnosis)
        }
        self.len = len
        self.descendants = descendants
        self.diagnosis = diagnosis
    }

    /// Assign span numbers within an interval to this subtree.
    ///
    /// When `node` is `nil`, only a `range` of children is numbered and the
    /// node's own span and `upper` bound are left untouched (used by
    /// incremental renumbering during reparsing).
    func numberize(node: SyntaxNode?, id: FileId, range: Range<Int>?,
                   within: Range<UInt64>) throws {
        let descendants: Int
        if let range {
            if range.isEmpty { return }
            descendants = children[range].reduce(0) { $0 + $1.descendants }
        } else {
            descendants = self.descendants
        }

        let space = within.upperBound - within.lowerBound
        var stride = space / UInt64(2 * descendants)
        if stride == 0 {
            stride = space / UInt64(descendants)
            if stride == 0 { throw Unnumberable() }
        }

        var start = within.lowerBound
        if let node {
            let end = start + stride
            node.span = Span.fromNumber(id: id, (start + end) / 2)
            upper = within.upperBound
            start = end
        }

        let count = children.count
        for i in (range ?? 0..<count) {
            let child = children[i]
            let childEnd = start + UInt64(child.descendants) * stride
            try child.numberize(id: id, within: start..<childEnd)
            start = childEnd
        }
    }

    /// Deep copy: fresh `InnerNode` and fresh copies of all children.
    func copy() -> InnerNode {
        let copied = InnerNode(children: children.map { $0.copy() })
        copied.upper = upper
        return copied
    }

    /// Whether two inner nodes are the same apart from spans.
    func spanlessEq(_ other: InnerNode) -> Bool {
        len == other.len
            && descendants == other.descendants
            && diagnosis == other.diagnosis
            && children.count == other.children.count
            && zip(children, other.children).allSatisfy { $0.spanlessEq($1) }
    }
}

/// Whether a node has diagnostic errors and/or warnings.
public struct Diagnosis: Sendable, Hashable {
    public var errors: Bool
    public var warnings: Bool

    public init(errors: Bool = false, warnings: Bool = false) {
        self.errors = errors
        self.warnings = warnings
    }

    /// Whether there were errors or warnings.
    public var either: Bool { errors || warnings }

    /// Whether there were both errors and warnings.
    public var both: Bool { errors && warnings }

    /// Apply the OR of both fields separately.
    public func or(_ other: Diagnosis) -> Diagnosis {
        Diagnosis(errors: errors || other.errors, warnings: warnings || other.warnings)
    }

    /// Whether any node in the slice has diagnostics.
    public static func any(_ slice: [SyntaxNode]) -> Diagnosis {
        slice.reduce(Diagnosis()) { $0.or($1.diagnosis) }
    }
}

/// A syntactical error or warning.
public struct SyntaxDiagnostic: Sendable, Hashable {
    /// `true` if the diagnostic is an error.
    public var isError: Bool
    /// The span targeted by the diagnostic.
    public var span: DiagSpan
    /// The main diagnostic message.
    public var message: String
    /// Additional hints.
    public var hints: [Spanned<String, DiagSpan>]
}

/// An error node in the untyped syntax tree.
final class ErrorNode: Equatable {
    /// The source text of the node.
    var text: String
    /// The error message.
    var message: String
    /// Hints: (message, optional sub-range).
    var hints: [(String, SubRange?)]

    init(message: String, text: String) {
        self.text = text
        self.message = message
        self.hints = []
    }

    /// Deep copy.
    func copy() -> ErrorNode {
        let copied = ErrorNode(message: message, text: text)
        copied.hints = hints
        return copied
    }

    /// Produce the syntax diagnostic for an error.
    func diagnostic(span: Span) -> SyntaxDiagnostic {
        SyntaxDiagnostic(isError: true, span: span.diag, message: message,
                         hints: Self.buildHints(parentSpan: span, hints: hints))
    }

    static func == (a: ErrorNode, b: ErrorNode) -> Bool {
        a.text == b.text && a.message == b.message && a.hints.elementsEqual(b.hints, by: ==)
    }

    static func buildHints(parentSpan: Span,
                           hints: [(String, SubRange?)]) -> [Spanned<String, DiagSpan>] {
        hints.map { (message, sub) in
            if let sub {
                return Spanned(message, span: DiagSpan(span: parentSpan, subRange: sub))
            }
            return Spanned<String, DiagSpan>(message, span: .detached)
        }
    }
}

/// A warning message wrapped around a node.
final class WarningNode {
    /// The wrapped node data.
    var child: SyntaxNode.Data
    /// A relative sub-range targeting text not grouped by a span.
    var subRange: SubRange?
    /// The warning message.
    var message: String
    /// Hints.
    var hints: [(String, SubRange?)]

    init(child: SyntaxNode.Data, subRange: SubRange?, message: String) {
        self.child = child
        self.subRange = subRange
        self.message = message
        self.hints = []
    }

    /// Deep copy.
    func copy() -> WarningNode {
        let copied = WarningNode(child: child.copy(), subRange: subRange, message: message)
        copied.hints = hints
        return copied
    }

    /// Produce the syntax diagnostic for a warning.
    func diagnostic(span: Span) -> SyntaxDiagnostic {
        SyntaxDiagnostic(isError: false,
                         span: DiagSpan(span: span, subRange: subRange),
                         message: message,
                         hints: ErrorNode.buildHints(parentSpan: span, hints: hints))
    }
}

/// Error thrown when a subtree cannot be numbered in the available range.
struct Unnumberable: Error {}
