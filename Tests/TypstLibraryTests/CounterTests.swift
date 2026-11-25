import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for `counter`, `counter.update`, `counter.get`/`at`/`final`/
/// `display`/`step`, `CounterState`/`CounterUpdate`/`CounterKey` casts,
/// and the `Count` impls — port of `introspection/counter.rs` +
/// `introspection/location.rs` methods.
@Suite("Counter")
struct CounterTests {
    private func loc(_ n: Int) -> Location {
        Location(hash: Hash128(high: 0, low: UInt64(n)))
    }

    private let flags = TagFlags(introspectable: true, tagged: false)

    /// Build an introspector holding `contents` as flat tag pairs.
    private func introspector(_ contents: [Content]) -> TestIntrospector {
        var b = ElementIntrospectorBuilder<Int>()
        for (i, e) in contents.enumerated() {
            let location = e.location ?? loc(1000 + i)
            var tagged = e
            tagged.location = location
            b.discoverTag(.start(tagged, flags), position: i)
            b.discoverTag(.end(location,
                                Hash128(high: 0, low: UInt64(100 + i)),
                                flags), position: i)
        }
        return TestIntrospector(inner: b.finalize())
    }

    private func update(_ key: CounterKey, _ update: CounterUpdate,
                        _ n: Int) -> Content {
        var c = Content(CounterUpdateElem(key: key, update: update))
        c.location = loc(n)
        return c
    }

    private func harness(_ contents: [Content],
                         at location: Location? = nil) -> FuncHarness {
        let h = FuncHarness()
        h.engine.introspector = introspector(contents)
        h.context.location = location ?? loc(0)
        return h
    }

    private func counterValue(_ key: CounterKey = .str(TypstLibrary.Str("k")))
        -> Value {
        .dynamic(Counter(key))
    }

    private let numbering11 = try! NumberingPattern(parsing: "1.1")

    // MARK: - CounterState

    @Test func stateInit() {
        #expect(CounterState.initial(page: false).numbers == [0])
        #expect(CounterState.initial(page: true).numbers == [1])
        #expect(CounterState.initial(page: false).first() == 0)
        #expect(CounterState([5, 2]).first() == 5)
        #expect(CounterState([]).first() == 1)
    }

    @Test func stateStep() {
        var s = CounterState([3])
        s.step(level: NonZeroUsize(value: 1), by: 2)
        #expect(s.numbers == [5])

        // Stepping a deeper level pads with zeros and truncates deeper
        // levels.
        var t = CounterState([1, 4, 9])
        t.step(level: NonZeroUsize(value: 2), by: 1)
        #expect(t.numbers == [1, 5])
    }

    @Test func stateSetAndFuncUpdate() throws {
        var s = CounterState([1, 2])
        var tmp = FuncHarness()
        guard case .success = s.update(engine: &tmp.engine,
                                       update: .set(CounterState([7, 8, 9])))
        else { Issue.record("set update failed"); return }
        #expect(s.numbers == [7, 8, 9])

        let addTen = Func(native: nativeFunc(
            "addTen",
            params: [
                NativeParamInfo(name: "n", input: Int64.input,
                                required: true),
            ],
            returns: Int64.output
        ) { _, _, args in
            let n: Int64 = try args.expectT("n")
            try args.finishT()
            return n + 10
        })
        // Function updates receive all numbers as arguments.
        s = CounterState([4])
        var h = FuncHarness()
        guard case .success = s.update(engine: &h.engine,
                                       update: .function(addTen))
        else { Issue.record("func update failed"); return }
        #expect(s.numbers == [14])
    }

    @Test func stateCasts() throws {
        #expect(try CounterState.fromValue(.int(4)).get().numbers == [4])
        #expect(try CounterState.fromValue(
            .array(ArrayValue(items: [.int(1), .int(2)]))).get().numbers
            == [1, 2])
        #expect((try? CounterState.fromValue(.int(-1)).get()) == nil)
        #expect((try? CounterState.fromValue(.str(TypstLibrary.Str("x"))).get()) == nil)
        #expect(try CounterState([1, 2]).intoValue()
            == .array(ArrayValue(items: [.int(1), .int(2)])))
    }

    // MARK: - CounterKey / CounterUpdate casts

    @Test func keyCasts() throws {
        #expect(try CounterKey.fromValue(.str(TypstLibrary.Str("k"))).get()
            == .str(TypstLibrary.Str("k")))
        let label = TypstLibrary.Label(name: .intern("l"))!
        #expect(try CounterKey.fromValue(.label(label)).get()
            == .selector(.label(label)))

        // `page` element function → page counter.
        let pageFunc = Element(PageElem.self).intoValue()
        #expect(try CounterKey.fromValue(pageFunc).get() == .page)

        // Other element functions → element selector.
        let headingFunc = Element(HeadingElem.self).intoValue()
        #expect(try CounterKey.fromValue(headingFunc).get()
            == .selector(.elem(Element(HeadingElem.self), fields: nil)))

        // Labels/selectors also accepted.
        #expect(try CounterKey.fromValue(.label(label)).get()
            == .selector(.label(label)))
        #expect((try? CounterKey.fromValue(.int(3)).get()) == nil)
    }

    @Test func updateCasts() throws {
        #expect(try CounterUpdate.fromValue(.int(2)).get()
            == .set(CounterState([2])))
        let f = Func(native: nativeFunc("f", params: [], returns: Int64.output) {
            _, _, _ in 0
        })
        #expect(try CounterUpdate.fromValue(.function(f)).get()
            == .function(f))
        #expect((try? CounterUpdate.fromValue(.str(TypstLibrary.Str("x"))).get()) == nil)
    }

    // MARK: - Construct bails

    @Test func updateElemConstructBails() {
        let h = FuncHarness()
        var args = h.args([])
        #expect(throws: HintedString.self) {
            _ = try CounterUpdateElem.construct(
                engine: &h.engine, args: &args)
        }
    }

    @Test func displayElemConstructBails() {
        let h = FuncHarness()
        var args = h.args([])
        #expect(throws: HintedString.self) {
            _ = try CounterDisplayElem.construct(
                engine: &h.engine, args: &args)
        }
    }

    // MARK: - counter constructor

    @Test func construct() throws {
        let h = FuncHarness()
        let result = try h.call(counterConstruct,
            h.args([.str(TypstLibrary.Str("k"))])).get()
        guard case let .dynamic(d) = result,
              let counter = d.downcast(Counter.self) else {
            Issue.record("expected counter value")
            return
        }
        #expect(counter.key == .str(TypstLibrary.Str("k")))
        #expect(counter.repr() == "counter(\"k\")")

        // `page` element function key.
        let result2 = try h.call(counterConstruct,
            h.args([Element(PageElem.self).intoValue()])).get()
        guard case let .dynamic(d2) = result2,
              let pageCounter = d2.downcast(Counter.self) else {
            Issue.record("expected counter value")
            return
        }
        #expect(pageCounter.isPage)
    }

    // MARK: - Sequence + introspections

    @Test func atIntrospectionAppliesUpdates() throws {
        let key = Counter(.str(TypstLibrary.Str("k")))
        // Leading non-matching element gives a location before all updates.
        let contents = [
            Content(TextElem(TypstLibrary.Str("start"))),
            update(key.key, .set(CounterState([1])), 1),
            update(key.key, .set(CounterState([2])), 2),
            update(key.key, .step(NonZeroUsize(value: 1)), 3),
        ]
        let introspector = introspector(contents)
        var h = FuncHarness()
        h.engine.introspector = introspector

        // Before the first update → initial state. (loc(1000) is the
        // leading text element.)
        let before = try h.engine.introspect(CounterAtIntrospection(
            counter: key, location: loc(1000), span: .detached)).get()
        #expect(before.numbers == [0])

        // At the second update → state after it (inclusive).
        let at2 = try h.engine.introspect(CounterAtIntrospection(
            counter: key, location: loc(2), span: .detached)).get()
        #expect(at2.numbers == [2])

        // After all → stepped.
        let at3 = try h.engine.introspect(CounterAtIntrospection(
            counter: key, location: loc(3), span: .detached)).get()
        #expect(at3.numbers == [3])
    }

    @Test func finalIntrospection() throws {
        let key = Counter(.str(TypstLibrary.Str("k")))
        let contents = [
            update(key.key, .set(CounterState([4])), 1),
            update(key.key, .set(CounterState([9])), 2),
        ]
        var h = FuncHarness()
        h.engine.introspector = introspector(contents)
        let state = try h.engine.introspect(CounterFinalIntrospection(
            counter: key, location: loc(0), span: .detached)).get()
        #expect(state.numbers == [9])
    }

    @Test func bothIntrospection() throws {
        let key = Counter(.str(TypstLibrary.Str("k")))
        let contents = [
            update(key.key, .set(CounterState([4])), 1),
            update(key.key, .set(CounterState([9])), 2),
        ]
        var h = FuncHarness()
        h.engine.introspector = introspector(contents)
        // At loc 1: at=4, final=9.
        let state = try h.engine.introspect(CounterBothIntrospection(
            counter: key, location: loc(1), span: .detached)).get()
        #expect(state.numbers == [4, 9])
    }

    @Test func selectorKeyCountsHeadingsByLevel() throws {
        var h1 = HeadingElem(body: Content(TextElem(TypstLibrary.Str("A"))))
        h1.depth = 1
        h1.numbering = Numbering.pattern(numbering11)
        var h2 = HeadingElem(body: Content(TextElem(TypstLibrary.Str("B"))))
        h2.depth = 2
        h2.numbering = Numbering.pattern(numbering11)
        var h3 = HeadingElem(body: Content(TextElem(TypstLibrary.Str("C"))))
        h3.depth = 1
        h3.numbering = Numbering.pattern(numbering11)
        // Unnumbered heading does not count.
        let h4 = HeadingElem(body: Content(TextElem(TypstLibrary.Str("D"))))

        let contents = [Content(h1), Content(h2), Content(h3), Content(h4)]
        let introspector = introspector(contents)
        let counter = Counter.of(Element(HeadingElem.self))
        var h = FuncHarness()
        h.engine.introspector = introspector

        // After h1 (loc 1000): [1]. After h2 (loc 1001): [1,1].
        // After h3 (loc 1002): [2] (deeper levels truncated).
        // After unnumbered h4 (loc 1003): unchanged [2].
        let s1 = try h.engine.introspect(CounterAtIntrospection(
            counter: counter, location: loc(1000), span: .detached)).get()
        #expect(s1.numbers == [1])
        let s2 = try h.engine.introspect(CounterAtIntrospection(
            counter: counter, location: loc(1001), span: .detached)).get()
        #expect(s2.numbers == [1, 1])
        let s3 = try h.engine.introspect(CounterAtIntrospection(
            counter: counter, location: loc(1002), span: .detached)).get()
        #expect(s3.numbers == [2])
        let s4 = try h.engine.introspect(CounterAtIntrospection(
            counter: counter, location: loc(1003), span: .detached)).get()
        #expect(s4.numbers == [2])
    }

    @Test func selectorKeyCountsManualUpdates() throws {
        // `counter(heading)` also picks up `counter.update(heading, ..)`.
        let key: CounterKey = .selector(
            .elem(Element(HeadingElem.self), fields: nil))
        let contents = [
            update(key, .set(CounterState([5])), 1),
        ]
        var h = FuncHarness()
        h.engine.introspector = introspector(contents)
        let counter = Counter(key)
        let state = try h.engine.introspect(CounterAtIntrospection(
            counter: counter, location: loc(1), span: .detached)).get()
        #expect(state.numbers == [5])
    }

    // MARK: - counter methods

    @Test func getFunc() throws {
        let key = Counter(.str(TypstLibrary.Str("k")))
        let contents = [
            update(key.key, .set(CounterState([1])), 1),
            update(key.key, .set(CounterState([2])), 2),
        ]
        let h = harness(contents, at: loc(2))
        let result = try h.call(counterGet,
            h.args([counterValue()])).get()
        #expect(result == .array(ArrayValue(items: [.int(2)])))
    }

    @Test func atFunc() throws {
        let key = Counter(.str(TypstLibrary.Str("k")))
        let contents = [
            update(key.key, .set(CounterState([1])), 1),
            update(key.key, .set(CounterState([2])), 2),
        ]
        let h = harness(contents, at: loc(0))
        // Location selector resolves directly.
        let selector = LocatableSelector(.location(loc(1))).intoValue()
        let result = try h.call(counterAt,
            h.args([counterValue(), selector])).get()
        #expect(result == .array(ArrayValue(items: [.int(1)])))
    }

    @Test func finalFunc() throws {
        let key = Counter(.str(TypstLibrary.Str("k")))
        let contents = [
            update(key.key, .set(CounterState([1])), 1),
            update(key.key, .set(CounterState([8])), 2),
        ]
        let h = harness(contents, at: loc(1))
        let result = try h.call(counterFinal,
            h.args([counterValue()])).get()
        #expect(result == .array(ArrayValue(items: [.int(8)])))
    }

    @Test func displayFunc() throws {
        let key = Counter(.str(TypstLibrary.Str("k")))
        let contents = [
            update(key.key, .set(CounterState([3])), 1),
        ]
        let h = harness(contents, at: loc(1))
        // Explicit numbering "1".
        let result = try h.call(counterDisplay,
            h.args([counterValue(), .str(TypstLibrary.Str("1"))])).get()
        #expect(result == .str(TypstLibrary.Str("3")))
    }

    @Test func displayFuncBoth() throws {
        let key = Counter(.str(TypstLibrary.Str("k")))
        let contents = [
            update(key.key, .set(CounterState([3])), 1),
            update(key.key, .set(CounterState([7])), 2),
        ]
        let h = harness(contents, at: loc(1))
        var args = h.args([counterValue()])
        args.items.append(Arg(span: .detached, name: TypstLibrary.Str("both"),
                              value: Spanned(.bool(true), span: .detached)))
        let result = try h.call(counterDisplay, args).get()
        // both → numbers [at, final] → "1.1" default numbering → "3.7".
        #expect(result == .str(TypstLibrary.Str("3.7")))
    }

    @Test func stepFunc() throws {
        let h = FuncHarness()
        let result = try h.call(counterStep,
            h.args([counterValue()])).get()
        guard case let .content(c) = result,
              let elem = c.to(CounterUpdateElem.self) else {
            Issue.record("expected CounterUpdateElem")
            return
        }
        #expect(elem.key == .str(TypstLibrary.Str("k")))
        #expect(elem.update == .step(NonZeroUsize(value: 1)))

        // With explicit level.
        var args = h.args([counterValue()])
        args.items.append(Arg(span: .detached, name: TypstLibrary.Str("level"),
                              value: Spanned(.int(2), span: .detached)))
        let result2 = try h.call(counterStep, args).get()
        guard case let .content(c2) = result2,
              let elem2 = c2.to(CounterUpdateElem.self) else {
            Issue.record("expected CounterUpdateElem")
            return
        }
        #expect(elem2.update == .step(NonZeroUsize(value: 2)))
    }

    @Test func updateFunc() throws {
        let h = FuncHarness()
        let result = try h.call(counterUpdateFunc,
            h.args([counterValue(), .int(4)])).get()
        guard case let .content(c) = result,
              let elem = c.to(CounterUpdateElem.self) else {
            Issue.record("expected CounterUpdateElem")
            return
        }
        #expect(elem.update == .set(CounterState([4])))
    }

    @Test func updateFuncWithFunction() throws {
        let h = FuncHarness()
        let f = Func(native: nativeFunc("f", params: [], returns: Int64.output) {
            _, _, _ in 0
        })
        let result = try h.call(counterUpdateFunc,
            h.args([counterValue(), .function(f)])).get()
        guard case let .content(c) = result,
              let elem = c.to(CounterUpdateElem.self) else {
            Issue.record("expected CounterUpdateElem")
            return
        }
        #expect(elem.update == .function(f))
    }

    // MARK: - Count impls

    @Test func headingCountUpdate() {
        var numbered = HeadingElem(body: Content(TextElem(TypstLibrary.Str("x"))))
        numbered.depth = 2
        numbered.numbering = Numbering.pattern(try! NumberingPattern(parsing: "1.1"))
        #expect(numbered.counterUpdate() == .step(NonZeroUsize(value: 2)))

        var unnumbered = HeadingElem(body: Content(TextElem(TypstLibrary.Str("x"))))
        unnumbered.numbering = nil
        #expect(unnumbered.counterUpdate() == nil)

        var explicit = HeadingElem(body: Content(TextElem(TypstLibrary.Str("x"))))
        explicit.level = Smart<Int>.custom(3)
        explicit.numbering = Numbering.pattern(try! NumberingPattern(parsing: "1"))
        #expect(explicit.counterUpdate() == .step(NonZeroUsize(value: 3)))
    }

    @Test func figureAndFootnoteCountUpdate() {
        // Figures are numbered by default → they count.
        var fig = FigureElem(body: Content(TextElem(TypstLibrary.Str("x"))))
        #expect(fig.counterUpdate() == .step(NonZeroUsize(value: 1)))
        fig.numbering = nil
        #expect(fig.counterUpdate() == nil)

        var note = FootnoteElem(body: .content(Content(TextElem(TypstLibrary.Str("n")))))
        #expect(note.counterUpdate() == .step(NonZeroUsize(value: 1)))
        note.body = .reference(TypstLibrary.Label(name: .intern("r"))!)
        #expect(note.counterUpdate() == nil)
    }

    @Test func counterKeyOfAndSelectAny() {
        let counter = Counter.of(Element(HeadingElem.self))
        #expect(counter.key == .selector(
            .elem(Element(HeadingElem.self), fields: nil)))
        #expect(Counter.selectAny()
            == Element(CounterUpdateElem.self).select())
    }

    @Test func counterIsPage() {
        #expect(Counter(.page).isPage)
        #expect(!Counter(.str(TypstLibrary.Str("k"))).isPage)
    }
}
