import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for `ElementIntrospector`/`ElementIntrospectorBuilder` and
/// `EmptyIntrospector` — port of `introspection/introspector.rs`.
@Suite("ElementIntrospector")
struct ElementIntrospectorTests {
    private func loc(_ n: Int) -> Location {
        Location(hash: Hash128(high: 0, low: UInt64(n)))
    }

    private func elem(_ text: String, _ n: Int, label: TypstLibrary.Label? = nil) -> Content {
        var c = Content(TextElem(Str(text)))
        c.location = loc(n)
        c.label = label
        return c
    }

    private let flags = TagFlags(introspectable: true, tagged: false)

    /// Discover start/end tag pairs for `elems` (flat, no nesting).
    private func buildFlat(_ elems: [Content]) -> ElementIntrospector<Int> {
        var b = ElementIntrospectorBuilder<Int>()
        for (i, e) in elems.enumerated() {
            b.discoverTag(.start(e, flags), position: i)
            b.discoverTag(.end(e.location!, Hash128(high: 0, low: UInt64(100 + i)), flags),
                          position: i)
        }
        return b.finalize()
    }

    /// Discover nested: outer contains inner.
    private func buildNested() -> (ElementIntrospector<Int>, Content, Content) {
        let outer = elem("outer", 1)
        let inner = elem("inner", 2)
        var b = ElementIntrospectorBuilder<Int>()
        b.discoverTag(.start(outer, flags), position: 0)
        b.discoverTag(.start(inner, flags), position: 1)
        b.discoverTag(.end(inner.location!, Hash128(high: 0, low: 102), flags),
                      position: 1)
        b.discoverTag(.end(outer.location!, Hash128(high: 0, low: 101), flags),
                      position: 0)
        return (b.finalize(), outer, inner)
    }

    private var textSelector: TypstLibrary.Selector {
        .elem(Element(TextElem.self), fields: nil)
    }

    @Test func queryAllInOrder() {
        let intro = buildFlat([elem("a", 1), elem("b", 2), elem("c", 3)])
        let result = intro.query(textSelector)
        #expect(result.map { $0.plainText } == ["a", "b", "c"])
        #expect(intro.queryFirst(textSelector)?.plainText == "a")
    }

    @Test func queryByLocationAndLabel() throws {
        let labelValue = TypstLibrary.Label(name: .intern("key"))
        let label = try #require(labelValue)
        let a = elem("a", 1, label: label)
        let b = elem("b", 2)
        let intro = buildFlat([a, b])

        #expect(intro.query(.location(loc(2))).first?.plainText == "b")
        #expect(try intro.queryLabel(label).get().plainText == "a")
        #expect(intro.queryLabelled().count == 1)
        #expect(intro.labelCount(label) == 1)

        let missingValue = TypstLibrary.Label(name: .intern("missing"))
        let missing = try #require(missingValue)
        if case .success = intro.queryLabel(missing) { Issue.record("expected failure") }
        #expect(intro.labelCount(missing) == 0)
    }

    @Test func queryUnique() throws {
        let intro = buildFlat([elem("a", 1), elem("b", 2)])
        #expect(try intro.queryUnique(.location(loc(1))).get().plainText == "a")
        if case .success = intro.queryUnique(textSelector) { Issue.record("expected failure") }
        if case .success = intro.queryUnique(.location(loc(99))) { Issue.record("expected failure") }
    }

    @Test func queryOrAnd() {
        let intro = buildFlat([elem("a", 1), elem("b", 2), elem("c", 3)])
        let locs = intro.query(.or([.location(loc(1)), .location(loc(3))]))
        #expect(locs.map { $0.plainText } == ["a", "c"])

        // `and` of elem-selector and location → only the located one.
        let both = intro.query(.and([textSelector, .location(loc(2))]))
        #expect(both.map { $0.plainText } == ["b"])
        #expect(intro.query(.and([textSelector, .location(loc(99))])).isEmpty)
    }

    @Test func queryBeforeAfter() {
        let intro = buildFlat([elem("a", 1), elem("b", 2), elem("c", 3)])
        let before = intro.query(.before(
            selector: textSelector, end: .location(loc(3)), inclusive: false))
        #expect(before.map { $0.plainText } == ["a", "b"])

        let after = intro.query(.after(
            selector: textSelector, start: .location(loc(1)), inclusive: true))
        #expect(after.map { $0.plainText } == ["a", "b", "c"])

        // Unknown end → full list.
        let all = intro.query(.before(
            selector: textSelector, end: .location(loc(99)), inclusive: false))
        #expect(all.count == 3)
    }

    @Test func queryWithin() {
        let (intro, outer, inner) = buildNested()
        let all = intro.query(textSelector)
        #expect(all.map { $0.plainText } == ["outer", "inner"])

        // Elements within `outer` but not `outer` itself.
        let withinOuter = intro.query(.within(
            selector: textSelector, ancestor: .location(loc(1))))
        #expect(withinOuter.map { $0.plainText } == ["inner"])

        // Within inner → nothing (inner has no children).
        let withinInner = intro.query(.within(
            selector: textSelector, ancestor: .location(loc(2))))
        #expect(withinInner.isEmpty)

        // Location ranges cover descendants.
        #expect(intro.locRange(loc(1)) == 0..<2)
        #expect(intro.locRange(loc(2)) == 1..<2)
        _ = outer
        _ = inner
    }

    @Test func queryCountBeforeAndLocator() {
        let intro = buildFlat([elem("a", 1), elem("b", 2), elem("c", 3)])
        #expect(intro.queryCountBefore(textSelector, end: loc(2)) == 2)
        #expect(intro.queryCountBefore(textSelector, end: loc(99)) == 3)

        // `locator` finds the closest location after `base` for a key.
        // End-tag keys were 100, 101, 102 → key 101 is loc(2).
        let key = Hash128(high: 0, low: 101)
        #expect(intro.locator(key, base: loc(1)) == loc(2))
        // Base after all → wraps to the smallest index distance.
        #expect(intro.locator(key, base: loc(3)) == loc(2))
    }

    @Test func positionAndGetByLoc() {
        let intro = buildFlat([elem("a", 1), elem("b", 2)])
        #expect(intro.position(loc(1)) == 0)
        #expect(intro.getByLoc(loc(2))?.plainText == "b")
        #expect(intro.getByLoc(loc(99)) == nil)
        #expect(intro.locIndex(loc(99)) == Int.max)
    }

    @Test func emptyIntrospector() {
        let intro = EmptyIntrospector()
        #expect(intro.query(textSelector).isEmpty)
        #expect(intro.queryFirst(textSelector) == nil)
        if case .success = intro.queryUnique(textSelector) { Issue.record("expected failure") }
        #expect(intro.queryLabelled().isEmpty)
        let anyLabel = TypstLibrary.Label(name: .intern("x"))!
        #expect(intro.labelCount(anyLabel) == 0)
        #expect(intro.pages(loc(1)) == nil)
        #expect(intro.position(loc(1)) == nil)
    }

    @Test func nonIntrospectableTagsIgnored() {
        let e = elem("a", 1)
        let flags = TagFlags(introspectable: false, tagged: true)
        var b = ElementIntrospectorBuilder<Int>()
        b.discoverTag(.start(e, flags), position: 0)
        b.discoverTag(.end(e.location!, Hash128(high: 0, low: 1), flags),
                      position: 0)
        let intro = b.finalize()
        #expect(intro.all().isEmpty)
    }
}
