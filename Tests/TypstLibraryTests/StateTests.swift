import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for `state`/`state.update`/`state.get`/`state.at`/`state.final`
/// and `StateUpdateElem` — port of `introspection/state.rs`.
@Suite("State")
struct StateTests {
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

    private func update(_ key: TypstLibrary.Str, _ update: StateUpdate,
                        _ n: Int) -> Content {
        var c = Content(StateUpdateElem(key: key, update: update))
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

    private func stateValue(_ key: String = "k",
                            _ initial: Value = .none) -> Value {
        .dynamic(State(key: TypstLibrary.Str(key), initial: initial))
    }

    private func expectFailure(_ result: SourceResult<Value>,
                               _ name: String) {
        guard case .failure = result else {
            Issue.record("\(name): expected failure")
            return
        }
    }

    @Test func construct() throws {
        let h = FuncHarness()
        let result = try h.call(stateConstruct, h.args([.str(TypstLibrary.Str("key")), .int(7)])).get()
        guard case let .dynamic(d) = result,
              let state = d.downcast(State.self) else {
            Issue.record("expected state value")
            return
        }
        #expect(state.key == TypstLibrary.Str("key"))
        #expect(state.initial == .int(7))
        #expect(state.repr() == "state(\"key\", 7)")
    }

    @Test func constructDefaultInit() throws {
        let h = FuncHarness()
        let result = try h.call(stateConstruct, h.args([.str(TypstLibrary.Str("key"))])).get()
        guard case let .dynamic(d) = result,
              let state = d.downcast(State.self) else {
            Issue.record("expected state value")
            return
        }
        #expect(state.initial == .none)
    }

    @Test func updateReturnsElem() throws {
        let h = FuncHarness()
        let result = try h.call(stateUpdateFunc, h.args([
            stateValue("k", .int(0)), .int(42)])).get()
        guard case let .content(c) = result,
              let elem = c.to(StateUpdateElem.self) else {
            Issue.record("expected StateUpdateElem content")
            return
        }
        #expect(elem.key == TypstLibrary.Str("k"))
        #expect(elem.update == .set(.int(42)))
    }

    @Test func updateWithFunc() throws {
        let h = FuncHarness()
        let inc = Func(native: nativeFunc(
            "inc",
            params: [
                NativeParamInfo(name: "self", input: Int64.input,
                                required: true),
            ],
            returns: Int64.output
        ) { _, _, args in
            let x: Int64 = try args.expectT("self")
            try args.finishT()
            return x + 1
        })
        let result = try h.call(stateUpdateFunc, h.args([stateValue("k"), .function(inc)])).get()
        guard case let .content(c) = result,
              let elem = c.to(StateUpdateElem.self) else {
            Issue.record("expected StateUpdateElem content")
            return
        }
        #expect(elem.update == .function(inc))
    }

    @Test func getReturnsInitialWithoutUpdates() throws {
        let h = harness([], at: loc(1))
        let result = try h.call(stateGet, h.args([stateValue("k", .int(5))])).get()
        #expect(result == .int(5))
    }

    @Test func getAppliesUpdatesInOrder() throws {
        let key = TypstLibrary.Str("k")
        let contents = [
            update(key, .set(.int(1)), 1),
            update(key, .set(.int(2)), 2),
            update(key, .set(.int(3)), 3),
        ]
        // At location 2 (second update), value is 2.
        let h = harness(contents, at: loc(2))
        let result = try h.call(stateGet, h.args([stateValue("k", .int(0))])).get()
        #expect(result == .int(2))

        // At location 3, value is 3.
        let h2 = harness(contents, at: loc(3))
        let result2 = try h2.call(stateGet,
            h2.args([stateValue("k", .int(0))])).get()
        #expect(result2 == .int(3))
    }

    @Test func getIgnoresOtherKeys() throws {
        let contents = [
            update(TypstLibrary.Str("other"), .set(.int(9)), 1),
            update(TypstLibrary.Str("k"), .set(.int(4)), 2),
        ]
        let h = harness(contents, at: loc(2))
        let result = try h.call(stateGet, h.args([stateValue("k", .int(0))])).get()
        #expect(result == .int(4))
    }

    @Test func getAppliesFuncUpdates() throws {
        let inc = Func(native: nativeFunc(
            "inc",
            params: [
                NativeParamInfo(name: "self", input: Int64.input,
                                required: true),
            ],
            returns: Int64.output
        ) { _, _, args in
            let x: Int64 = try args.expectT("self")
            try args.finishT()
            return x + 1
        })
        let key = TypstLibrary.Str("k")
        let contents = [
            update(key, .function(inc), 1),
            update(key, .set(.int(10)), 2),
            update(key, .function(inc), 3),
        ]
        // init 0 -> +1 -> 10 -> +1 = 11 at loc 3.
        let h = harness(contents, at: loc(3))
        let result = try h.call(stateGet, h.args([stateValue("k", .int(0))])).get()
        #expect(result == .int(11))
    }

    @Test func finalReturnsLastValue() throws {
        let key = TypstLibrary.Str("k")
        let contents = [
            update(key, .set(.int(1)), 1),
            update(key, .set(.int(7)), 2),
        ]
        let h = harness(contents)
        let result = try h.call(stateFinal, h.args([stateValue("k", .int(0))])).get()
        #expect(result == .int(7))
    }

    @Test func atResolvesSelector() throws {
        let key = TypstLibrary.Str("k")
        let label = TypstLibrary.Label(name: .intern("mark"))!
        var marked = update(key, .set(.int(1)), 1)
        marked.label = label
        let contents = [
            marked,
            update(key, .set(.int(2)), 2),
        ]
        // `state.at(<mark>)` evaluates at the mark: value is 1.
        let h = harness(contents, at: loc(9))
        let result = try h.call(stateAt, h.args([stateValue("k", .int(0)), .label(label)])).get()
        #expect(result == .int(1))
    }

    @Test func getRequiresContext() throws {
        let h = FuncHarness()
        h.engine.introspector = introspector([])
        expectFailure(h.call(stateGet, h.args([stateValue("k")])),
                      "get without context")
    }

    @Test func updateElemCannotBeConstructed() throws {
        let h = FuncHarness()
        var args = h.args([.str(TypstLibrary.Str("k")), .int(1)])
        do {
            _ = try StateUpdateElem.construct(
                engine: &h.engine, args: &args)
            Issue.record("expected construct to throw")
        } catch {}
    }

    @Test func stateUpdateCastPrefersFunc() throws {
        let f = Func(native: nativeFunc(
            "f", params: [], returns: Int64.output
        ) { _, _, _ in 0 })
        // A function value casts to `.function`, not `.set`.
        let update = try StateUpdate.fromValue(.function(f)).get()
        #expect(update == .function(f))
        // A plain value casts to `.set`.
        let update2 = try StateUpdate.fromValue(.int(3)).get()
        #expect(update2 == .set(.int(3)))
    }
}
