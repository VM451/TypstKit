import Foundation
import TypstUtils

// Space collapsing and discarding infrastructure for realization.
//
// Port of `typst-realize/src/spaces.rs`.

/// State kept for space collapsing/discarding.
///
/// Port of `SpaceState` in `spaces.rs`. Upstream borrows `&'a str`; Swift
/// stores owned `String`s (the texts are small).
enum SpaceState {
    /// When destructive, we skip any future spaces.
    case destructive
    /// When supportive, we usually keep future spaces, but we will discard
    /// newline spaces if the text surrounding a newline space returns true for
    /// `discard_space_between`.
    ///
    /// Text can be empty if this is not a textual element.
    case supportive(text: String)
    /// A current space. Spaces collapse into one with the styles of the first
    /// space by skipping following spaces, and they set `had_newline` to true
    /// if any space in a group had a newline.
    case space(prevText: String, hadNewline: Bool)
}

/// What action to take for space collapsing/discarding.
///
/// Port of `SpaceAction` in `spaces.rs`.
enum SpaceAction {
    /// Invisible elements are themselves kept, but neither contain text nor
    /// affect the space collapsing state.
    case invisible
    /// Avoid adding the current space element.
    case skip
    /// Discard the preceding space, but keep the current element.
    case discard
    /// Keep the current element and don't change any preceding spaces.
    case keep
}

/// Resolves a boolean element field through the style chain, falling back to
/// the element's stored value. Mirrors upstream `field.get(styles)`.
private func boolField(_ styles: StyleChain, _ elem: Element, _ id: UInt8,
                       _ fallback: Bool) -> Bool {
    if let value = styles.getValue(elem, id), case let .bool(b) = value {
        return b
    }
    return fallback
}

/// Run the space collapsing algorithm on `buf[start...]`. This discards space
/// elements that are at the edges of the range or in the vicinity of
/// destructive elements and collapses adjacent spaces into one with the styles
/// of the first space.
///
/// Port of `collapse_spaces` in `spaces.rs` — implemented efficiently
/// in-place by shifting elements in the buffer to the left whenever we
/// discard or collapse a space.
func collapseSpaces(_ buf: inout [RealizePair], _ start: Int) {
    var cursor = start
    var prevSpace = cursor
    var state = SpaceState.destructive

    // We do one pass over the elements, backshifting everything as necessary
    // when a space collapses. The variable `cursor` is our cursor in the
    // result. The variable `i` is our cursor in the original elements. At all
    // times, we have `cursor <= i`, so we can do it in-place.
    var i = start
    while i < buf.count {
        let pair = buf[i]

        let (action, newState) = collapseTransition(state, pair.content,
                                                    pair.styles)
        state = newState
        switch action {
        case .invisible:
            break
        case .skip:
            i += 1
            continue
        case .discard:
            // buf.copy_within(prev_space + 1..cursor, prev_space)
            let moved = Array(buf[(prevSpace + 1)..<cursor])
            buf.replaceSubrange(prevSpace..<(cursor - 1), with: moved)
            cursor -= 1
        case .keep:
            prevSpace = cursor
        }

        // Copy over normal elements (in place).
        if cursor < i {
            buf[cursor] = buf[i]
        }
        cursor += 1
        i += 1
    }

    if case .space = state {
        let moved = Array(buf[(prevSpace + 1)..<cursor])
        buf.replaceSubrange(prevSpace..<(cursor - 1), with: moved)
        cursor -= 1
    }

    // Delete all the excess that's left due to the gaps produced by spaces.
    buf.removeLast(buf.count - cursor)
}

/// How to transition state for the space collapsing algorithm.
///
/// Port of `collapse_transition` in `spaces.rs`.
private func collapseTransition(
    _ state: SpaceState, _ content: Content, _ styles: StyleChain
) -> (SpaceAction, SpaceState) {
    if content.is(TagElem.self) {
        return (.invisible, state)
    } else if let elem = content.packed(HElem.self) {
        if elem.amount.isFractional
            || boolField(styles, Element(HElem.self), 1, elem.weak) {
            return forDestructive(state)
        } else {
            return (.invisible, state)
        }
    } else if content.is(LinebreakElem.self) {
        // We want to collapse spaces that would otherwise be protected and
        // show up as spans with `white-space: pre-wrap`.
        // (The upstream `HtmlElem` whitespace-collapsing branch has no
        // counterpart until HTML export lands.)
        return forDestructive(state)
    } else if let elem = content.packed(SpaceElem.self) {
        return forSpace(state, hadNewline: elem.hadNewline)
    } else if let elem = content.packed(TextElem.self) {
        return forSupportive(state, text: elem.text.value)
    } else {
        return forSupportive(state, text: "")
    }
}

/// How to transition state for space collapsing during regex matching.
///
/// Port of `collapse_transition_textual` in `spaces.rs`.
func collapseTransitionTextual(
    _ state: SpaceState, _ content: Content, _ styles: StyleChain
) -> (SpaceAction, SpaceState, String) {
    let text: String
    // Roughly ordered from most to least common.
    let (action, newState): (SpaceAction, SpaceState)
    if content.is(TagElem.self) {
        text = ""
        (action, newState) = (.invisible, state)
    } else if content.is(LinebreakElem.self) {
        text = "\n"
        (action, newState) = forDestructive(state)
    } else if let elem = content.packed(SpaceElem.self) {
        text = " "
        (action, newState) = forSpace(state, hadNewline: elem.hadNewline)
    } else if let elem = content.packed(TextElem.self) {
        text = elem.text.value
        (action, newState) = forSupportive(state, text: text)
    } else if let elem = content.packed(SmartQuoteElem.self) {
        text = boolField(styles, Element(SmartQuoteElem.self), 0, elem.double)
            ? "\"" : "'"
        (action, newState) = forSupportive(state, text: text)
    } else {
        fatalError(
            "tried to find regex match in a non-textual element: \(content.name)")
    }
    return (action, newState, text)
}

/// The state transition for a destructive element.
///
/// Port of `for_destructive` in `spaces.rs`.
private func forDestructive(_ state: SpaceState)
    -> (SpaceAction, SpaceState) {
    if case .space = state {
        return (.discard, .destructive)
    } else {
        return (.keep, .destructive)
    }
}

/// The state transition for a space element.
///
/// If any space in a group of spaces had a newline, we treat all spaces in
/// that group as having a newline.
///
/// Port of `for_space` in `spaces.rs`.
private func forSpace(_ state: SpaceState, hadNewline: Bool)
    -> (SpaceAction, SpaceState) {
    switch state {
    case .destructive:
        return (.skip, .destructive)
    case let .supportive(prevText):
        return (.keep, .space(prevText: prevText, hadNewline: hadNewline))
    case let .space(prevText, prevNewline):
        return (.skip, .space(
            prevText: prevText, hadNewline: prevNewline || hadNewline))
    }
}

/// The state transition for a supportive element. `text` should be empty if
/// this is not a textual element.
///
/// Port of `for_supportive` in `spaces.rs`.
private func forSupportive(_ state: SpaceState, text: String)
    -> (SpaceAction, SpaceState) {
    if case let .space(prevText, hadNewline) = state,
       hadNewline,
       discardSpaceBetween(prevText, text) {
        return (.discard, .supportive(text: text))
    } else {
        return (.keep, .supportive(text: text))
    }
}
