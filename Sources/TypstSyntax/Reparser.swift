import Foundation

/// Refresh the given syntax node with as little parsing as possible.
///
/// Takes the new text, the range in the old text that was replaced and the
/// length of the replacement and returns the reparsed root node and the
/// range in the new text that was ultimately reparsed.
///
/// The high-level API for this function is `Source.edit`.
///
/// Port of `reparser.rs` in `typst-syntax`.
func reparse(
    root: SyntaxNode,
    text: String,
    replaced: Range<Int>,
    replacementLen: Int
) -> (root: SyntaxNode, reparsed: Range<Int>) {
    let rootId = root.span.id

    var renumber = true
    var reparsedRange = 0..<text.utf8.count
    var newRoot = root
    if let (inner, kind, span) = root.reparseInnerNodeMut(),
       let (range, numberingOK) = tryReparseAndRenumber(
           text: text,
           replaced: replaced,
           replacementLen: replacementLen,
           parentKind: nil,
           inner: inner,
           kind: kind,
           span: span,
           offset: 0
       ) {
        reparsedRange = range
        renumber = !numberingOK
    } else {
        newRoot = parse(text)
    }

    if renumber, let id = rootId {
        try! newRoot.numberize(id: id, within: Span.FULL)
    }

    return (newRoot, reparsedRange)
}

/// Try to reparse inside the given node, returning the range of new text that
/// was ultimately reparsed and whether span numbering succeeded.
///
/// If reparsing succeeds, also tries to assign span numbers to the new nodes.
/// If numbering fails (i.e. we're out of span numbers at this level), the
/// caller is in charge of assigning span numbers (this should be rare).
///
/// We start by doing a depth-first search for the innermost node or nodes
/// which fully surround the replaced range. This can be a single node that is
/// a code/content block or one or more nodes that are markup expressions and
/// are directly inside a markup block or the top-level markup. In either case,
/// we call the parser and succeed only if the parsed text has balanced
/// delimiters with the same delimiter nesting level as before. Otherwise, we
/// expand the set of markup expressions outwards or return upwards until we
/// either get a parse that does succeed or we parse the entire text.
///
/// Note that we currently only reparse markup expressions at the top-level or
/// directly inside a markup block. We also do not currently reparse math.
private func tryReparseAndRenumber(
    text: String,
    replaced: Range<Int>,
    replacementLen: Int,
    parentKind: SyntaxKind?,
    inner: InnerNode,
    kind: SyntaxKind,
    span: Span,
    offset: Int
) -> (range: Range<Int>, numberingOK: Bool)? {
    guard let (overlap, startOffset) = overlappingChildren(
        inner, replaced: replaced, offset: offset
    ) else { return nil }

    if overlap.count == 1 {
        let childNode = inner.children[overlap.lowerBound]
        if let (child, childKind, childSpan) = childNode.reparseInnerNodeMut(),
           startOffset < replaced.lowerBound,
           replaced.upperBound < startOffset + child.len {
            // A single child fully surrounds the edit. We either reparse
            // within the child, or reparse the child itself (if the child is
            // a block).
            let prevLen = child.len
            let prevDesc = child.descendants
            let prevDiag = child.diagnosis
            let newLen = prevLen + replacementLen - replaced.count
            let newRange = startOffset..<(startOffset + newLen)

            // Recursively descend and try to reparse at a lower level.
            if let (deepRange, deepNumberingOK) = tryReparseAndRenumber(
                text: text,
                replaced: replaced,
                replacementLen: replacementLen,
                parentKind: kind,
                inner: child,
                kind: childKind,
                span: childSpan,
                offset: startOffset
            ) {
                // A lower level reparse succeeded! Update this node and
                // return the reparsed range.
                assert(child.len == newLen)
                let newDesc = child.descendants
                let newDiag = child.diagnosis
                inner.updateParent(
                    prevLen: prevLen, newLen: newLen,
                    prevDesc: prevDesc, newDesc: newDesc,
                    prevDiag: prevDiag, newDiag: newDiag
                )
                var numberingOK = deepNumberingOK
                if !numberingOK {
                    numberingOK = inner.renumberChildren(span: span, range: overlap)
                }
                return (deepRange, numberingOK)
            }

            // The child is the innermost block which fully surrounds the text
            // (and hasn't failed at reparsing yet), reparse!
            if childKind.isBlock,
               let newChild = reparseBlock(text, range: newRange) {
                let newDesc = newChild.descendants
                let newDiag = newChild.diagnosis
                inner.children[overlap.lowerBound] = newChild
                inner.updateParent(
                    prevLen: prevLen, newLen: newLen,
                    prevDesc: prevDesc, newDesc: newDesc,
                    prevDiag: prevDiag, newDiag: newDiag
                )
                // Reparsing succeeded! Now try to assign span numbers.
                let numberingOK = inner.renumberChildren(span: span, range: overlap)
                return (newRange, numberingOK)
            }
        }
    }

    if kind == .markup,
       parentKind == nil || parentKind == .contentBlock,
       let reparse = expandAndReparseMarkup(
           text: text,
           replaced: replaced,
           replacementLen: replacementLen,
           children: inner.children,
           overlap: overlap,
           offset: offset,
           topLevel: parentKind == nil
       ) {
        let reparsedChildren = inner.replaceChildren(
            reparse.prevChildren, reparse.newborns
        )
        // Reparsing succeeded! Now try to assign span numbers to the nodes.
        let numberingOK = inner.renumberChildren(span: span, range: reparsedChildren)
        return (reparse.newRange, numberingOK)
    }

    return nil
}

/// Reparsed markup expressions. We use a struct to avoid ambiguity since the
/// two `Range<Int>` values have different meanings.
private struct MarkupReparse {
    /// The newly parsed expressions.
    var newborns: [SyntaxNode]
    /// The range of children that were replaced.
    var prevChildren: Range<Int>
    /// The range of new text that was reparsed.
    var newRange: Range<Int>
}

/// Reparse a range of markup expressions, expanding the range exponentially
/// on each iteration until reparsing succeeds.
private func expandAndReparseMarkup(
    text: String,
    replaced: Range<Int>,
    replacementLen: Int,
    children: [SyntaxNode],
    overlap: Range<Int>,
    offset: Int,
    topLevel: Bool
) -> MarkupReparse? {
    // Reparse a segment. Retries until it works, taking exponentially more
    // children into account.
    var expansion = 1
    while true {
        // Add slack in both directions.
        var start = Swift.max(overlap.lowerBound - Swift.max(expansion, 2), 0)
        var end = Swift.min(overlap.upperBound + expansion, children.count)

        // Expand to the left.
        while start > 0 && expand(children[start]) {
            start -= 1
        }

        // Expand to the right.
        while end < children.count && expand(children[end]) {
            end += 1
        }

        // Also take hash.
        if start > 0 && children[start - 1].kind == .hash {
            start -= 1
        }

        // Synthesize what `atStart` and `nesting` would be at the start of the
        // reparse.
        var prefixLen = 0
        var nesting = 0
        var atStart = true
        for child in children[..<start] {
            prefixLen += child.len
            nextAtStart(child, &atStart)
            nextNesting(child, &nesting)
        }

        // Determine what `atStart` will have to be at the end of the reparse.
        var prevLen = 0
        var prevAtStartAfter = atStart
        var prevNestingAfter = nesting
        for child in children[start..<end] {
            prevLen += child.len
            nextAtStart(child, &prevAtStartAfter)
            nextNesting(child, &prevNestingAfter)
        }

        // Determine the range in the new text that we want to reparse.
        let shifted = offset + prefixLen
        let newLen = prevLen + replacementLen - replaced.count
        let newRange = shifted..<(shifted + newLen)
        let atEnd = end == children.count

        // Reparse!
        var newAtStart = atStart
        var newNesting = nesting
        if let newborns = reparseMarkup(
            text,
            range: newRange,
            atStart: &newAtStart,
            nesting: &newNesting,
            topLevel: topLevel
        ) {
            // Generally, `atStart` and `nesting` need to match their previous
            // values or else the reparse could affect adjacent/surrounding
            // nodes. For example, `= Head` is only a heading at the start of
            // a line, not in the middle of some text. And the outer content
            // block in `#[a[b]c]` would group differently if the first `[`
            // were deleted.
            //
            // But they can safely differ from their previous values under the
            // right conditions:
            // - `atStart` can differ if we're at the end of this markup node,
            //   since no following markup nodes could be affected.
            // - `nesting` can differ if we're _both_ at the end of this markup
            //   node and are reparsing the top-level markup node (i.e. we're
            //   inserting at the very end of a file), since only the top-level
            //   markup node has no surrounding blocks.
            if (atEnd || newAtStart == prevAtStartAfter)
                && ((atEnd && topLevel) || newNesting == prevNestingAfter) {
                return MarkupReparse(
                    newborns: newborns,
                    prevChildren: start..<end,
                    newRange: newRange
                )
            }
        }

        // If it didn't even work with all children, we give up.
        if start == 0 && atEnd {
            return nil
        }

        // Exponential expansion to both sides.
        expansion *= 2
    }
}

/// The indices and start offset of the children which overlap a replaced
/// range. Returns `nil` if the children don't fully cover the range. Will
/// never return an empty range if it returns non-nil.
///
/// Note that the returned `Range<Int>` is the range of children in the
/// parent, but the returned `Int` is a byte offset in the source text.
private func overlappingChildren(
    _ node: InnerNode,
    replaced range: Range<Int>,
    offset startOffset: Int
) -> (Range<Int>, Int)? {
    var offset = startOffset
    if offset > range.lowerBound || range.upperBound > offset + node.len {
        // No set of children will fully cover the range, no need to search.
        return nil
    }
    var index = 0
    var start = 0
    var childStartOffset = offset
    for child in node.children {
        if offset < range.lowerBound {
            start = index
            childStartOffset = offset
        }
        offset += child.len
        index += 1
        if range.upperBound < offset {
            break
        }
    }
    assert(childStartOffset <= range.lowerBound)
    assert(range.upperBound <= offset)
    return (start..<index, childStartOffset)
}

/// Whether the selection should be expanded beyond a node of this kind.
private func expand(_ node: SyntaxNode) -> Bool {
    let kind = node.kind
    return kind.isTrivia
        || kind.isError
        || kind == .semicolon
        || node.leafText == "/"
        || node.leafText == ":"
}

/// Whether `atStart` would still be true after this node given the previous
/// value of the property.
private func nextAtStart(_ node: SyntaxNode, _ atStart: inout Bool) {
    let kind = node.kind
    if kind.isTrivia {
        atStart = atStart || kind == .parbreak || kind == .spaceWithNewline
    } else {
        atStart = false
    }
}

/// Update `nesting` based on the node.
private func nextNesting(_ node: SyntaxNode, _ nesting: inout Int) {
    if node.kind == .text {
        switch node.leafText {
        case "[": nesting += 1
        case "]" where nesting > 0: nesting -= 1
        default: break
        }
    }
}

/// The next power of two greater than or equal to `x` (for `x >= 1`).
private func nextPowerOfTwo(_ x: Int) -> Int {
    var p = 1
    while p < x { p <<= 1 }
    return p
}

extension InnerNode {
    /// Update this node after one or more of its children were replaced or
    /// updated. The new children must already be in `self.children`.
    ///
    /// `prev_*` variables should come from the previous range of children.
    /// `new_*` are for the new range of children.
    func updateParent(
        prevLen: Int,
        newLen: Int,
        prevDesc: Int,
        newDesc: Int,
        prevDiag: Diagnosis,
        newDiag: Diagnosis
    ) {
        // Length and descendants are numerical, can update with algebra.
        // Subtract the previous values first to avoid potential overflow.
        len = (len - prevLen) + newLen
        descendants = (descendants - prevDesc) + newDesc

        // Our diagnosis is the `OR` of all our children's diagnoses.
        if !diagnosis.either || newDiag.both {
            // We can avoid iterating our children if our previous overall
            // state had no errors/warnings, or if the new children have both.
            diagnosis = newDiag
        } else if prevDiag != newDiag {
            // Otherwise, we recompute using all the children since we don't
            // know if there were multiple children with errors or warnings.
            diagnosis = Diagnosis.any(children)
        }
    }

    /// Replace a range of children and call `updateParent`.
    /// `renumberChildren` should be called immediately after this.
    ///
    /// To increase the stability of span numbers, this does not replace nodes
    /// at the front/back that are equal to the previous nodes. Returns the
    /// final indices of the inserted nodes.
    func replaceChildren(_ range: Range<Int>, _ replacement: [SyntaxNode]) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        var replacementLower = 0
        var replacementUpper = replacement.count

        // Trim off common prefix.
        while lower < upper
            && replacementLower < replacementUpper
            && children[lower].spanlessEq(replacement[replacementLower]) {
            lower += 1
            replacementLower += 1
        }

        // Trim off common suffix.
        while lower < upper
            && replacementLower < replacementUpper
            && children[upper - 1].spanlessEq(replacement[replacementUpper - 1]) {
            upper -= 1
            replacementUpper -= 1
        }

        // Compute child information for the `updateParent` call.
        let new = Array(replacement[replacementLower..<replacementUpper])
        let newLen = new.reduce(0) { $0 + $1.len }
        let newDesc = new.reduce(0) { $0 + $1.descendants }
        let newDiag = Diagnosis.any(new)

        let prevSlice = Array(children[lower..<upper])
        let prevLen = prevSlice.reduce(0) { $0 + $1.len }
        let prevDesc = prevSlice.reduce(0) { $0 + $1.descendants }
        let prevDiag = Diagnosis.any(prevSlice)

        let replacedRange = lower..<(lower + new.count)

        children.replaceSubrange(lower..<upper, with: new)
        updateParent(
            prevLen: prevLen, newLen: newLen,
            prevDesc: prevDesc, newDesc: newDesc,
            prevDiag: prevDiag, newDiag: newDiag
        )

        return replacedRange
    }

    /// Try to assign span numbers to a range of children. If there are not
    /// enough numbers, retries taking exponentially more children into
    /// account. Returns whether numbering succeeded.
    func renumberChildren(span: Span, range: Range<Int>) -> Bool {
        guard let id = span.id else { return false }

        var left = 0
        var right = 0
        let maxLeft = range.lowerBound
        let maxRight = children.count - range.upperBound
        while true {
            let renumber = (range.lowerBound - left)..<(range.upperBound + right)

            // The minimum assignable number is either
            // - the upper bound of the node right before the to-be-renumbered
            //   children,
            // - or this inner node's span number plus one if renumbering
            //   starts at the first child.
            let startNumber: UInt64
            if renumber.lowerBound > 0,
               renumber.lowerBound - 1 < children.count {
                startNumber = children[renumber.lowerBound - 1].upper
            } else {
                startNumber = span.number + 1
            }

            // The upper bound for renumbering is either
            // - the span number of the first child after the to-be-renumbered
            //   children,
            // - or this node's upper bound if renumbering ends behind the
            //   last child.
            let endNumber = renumber.upperBound < children.count
                ? children[renumber.upperBound].span.number
                : upper

            // Try to renumber.
            let within = startNumber..<endNumber
            if (try? numberize(node: nil, id: id, range: renumber, within: within)) != nil {
                return true
            }

            // If it didn't even work with all children, we give up.
            if left == maxLeft && right == maxRight {
                return false
            }

            // Exponential expansion to both sides.
            left = Swift.min(nextPowerOfTwo(left + 1), maxLeft)
            right = Swift.min(nextPowerOfTwo(right + 1), maxRight)
        }
    }
}
