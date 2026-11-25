import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for the `query`/`locate`/`here`/`metadata` introspection
/// functions — port of `introspection/{query,locate,here,metadata}.rs`.
@Suite("QueryFuncs")
struct QueryFuncTests {
    private func loc(_ n: Int) -> Location {
        Location(hash: Hash128(high: 0, low: UInt64(n)))
    }

    private func elem(_ text: String, _ n: Int,
                      label: TypstLibrary.Label? = nil) -> Content {
        var c = Content(TextElem(Str(text)))
        c.location = loc(n)
        c.label = label
        return c
    }

    private let flags = TagFlags(introspectable: true, tagged: false)

    /// Build an introspector holding `elems` as flat tag pairs.
    private func introspector(_ elems: [Content]) -> TestIntrospector {
        var b = ElementIntrospectorBuilder<Int>()
        for (i, e) in elems.enumerated() {
            b.discoverTag(.start(e, flags), position: i)
            b.discoverTag(.end(e.location!, Hash128(high: 0, low: UInt64(100 + i)),
                                flags), position: i)
        }
        return TestIntrospector(inner: b.finalize())
    }

    /// Harness with a populated introspector and a context location.
    private func harness(_ elems: [Content]) -> FuncHarness {
        let h = FuncHarness()
        h.engine.introspector = introspector(elems)
        h.context.location = loc(0)
        return h
    }

    private var textSelectorValue: Value {
        .function(Element(TextElem.self).function)
    }

    private func downcast<T>(_ value: Value, _ type: T.Type) -> T? {
        guard case let .dynamic(d) = value else { return nil }
        return d.downcast(T.self)
    }

    private func expectFailure(_ result: SourceResult<Value>,
                               _ name: String) {
        guard case .failure = result else {
            Issue.record("\(name): expected failure")
            return
        }
    }

    @Test func queryReturnsMatches() throws {
        let h = harness([elem("a", 1), elem("b", 2), elem("c", 3)])
        let result = try h.call(queryFunc, h.args([textSelectorValue])).get()
        guard case let .array(items) = result else {
            Issue.record("expected array, got \(result)")
            return
        }
        #expect(items.map {
            guard case let .content(c) = $0 else { return "" }
            return c.plainText
        } == ["a", "b", "c"])
    }

    @Test func queryRecordsIntrospection() throws {
        let h = harness([elem("a", 1)])
        _ = try h.call(queryFunc, h.args([textSelectorValue])).get()
        #expect(h.engine.sink.introspections.count == 1)
    }

    @Test func queryRequiresContext() throws {
        let h = FuncHarness()
        h.engine.introspector = introspector([elem("a", 1)])
        expectFailure(h.call(queryFunc, h.args([textSelectorValue])),
                      "query without context")
    }

    @Test func queryRejectsUnlocatable() throws {
        let h = harness([])
        let spaceFunc = Element(SpaceElem.self).function
        expectFailure(h.call(queryFunc, h.args([.function(spaceFunc)])),
                      "query(space)")
    }

    @Test func locateReturnsUniqueLocation() throws {
        let h = harness([elem("only", 7)])
        let result = try h.call(locateFunc, h.args([textSelectorValue])).get()
        #expect(downcast(result, Location.self) == loc(7))
        #expect(h.engine.sink.introspections.count == 1)
    }

    @Test func locateFailsWhenNotUnique() throws {
        let h = harness([elem("a", 1), elem("b", 2)])
        expectFailure(h.call(locateFunc, h.args([textSelectorValue])),
                      "locate(text) with two matches")
    }

    @Test func locateByLabel() throws {
        let label = TypstLibrary.Label(name: .intern("note"))!
        let h = harness([elem("x", 3, label: label)])
        let result = try h.call(locateFunc, h.args([.label(label)])).get()
        #expect(downcast(result, Location.self) == loc(3))
    }

    @Test func locateByLocation() throws {
        let h = harness([elem("a", 1)])
        let result = try h.call(
            locateFunc, h.args([.dynamic(TypstLibrary.Selector.location(loc(1)))]))
            .get()
        #expect(downcast(result, Location.self) == loc(1))
    }

    @Test func hereReturnsContextLocation() throws {
        let h = harness([])
        let result = try h.call(hereFunc, h.args([])).get()
        #expect(downcast(result, Location.self) == loc(0))
    }

    @Test func hereRequiresContext() throws {
        let h = FuncHarness()
        expectFailure(h.call(hereFunc, h.args([])), "here without context")
    }

    @Test func metadataConstruct() throws {
        let h = FuncHarness()
        var args = h.args([.int(42)])
        let content = try MetadataElem.construct(
            engine: &h.engine, args: &args)
        #expect(content.to(MetadataElem.self)?.value == .int(42))
    }

    @Test func metadataLabelledAndQueryable() throws {
        let label = TypstLibrary.Label(name: .intern("m"))!
        var elem = MetadataElem()
        elem.value = Value.str(Str("payload"))
        var meta = Content(elem)
        meta.location = loc(5)
        meta.label = label
        let h = harness([meta])
        let result = try h.call(
            queryFunc, h.args([.label(label)])).get()
        guard case let .array(items) = result else {
            Issue.record("expected array")
            return
        }
        #expect(items.count == 1)
        guard case let .content(c) = items[0],
              let meta = c.to(MetadataElem.self) else {
            Issue.record("expected metadata content")
            return
        }
        #expect(meta.value == Value.str(Str("payload")))
    }
}
