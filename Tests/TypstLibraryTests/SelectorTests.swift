import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `selector` scope — port of
/// `foundations/selector.rs`.
@Suite struct SelectorTests {
    let harness = FuncHarness()

    private func i(_ v: Int64) -> Value { .int(v) }
    private func s(_ v: String) -> Value { .str(Str(v)) }

    private func call(_ f: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(f, args))
    }

    private func asSelector(_ v: Value) -> TypstLibrary.Selector? {
        guard case .dynamic(let d) = v else { return nil }
        return d.downcast(TypstLibrary.Selector.self)
    }

    @Test func constructFromFunc() throws {
        // selector(text-func) → elem selector.
        let v = try call(TypstLibrary.selectorConstruct,
                         [.function(Element(TextElem.self).function)])
        guard case .elem(let elem, let fields) = asSelector(v) else {
            Issue.record("expected elem selector, got \(v.repr())"); return
        }
        #expect(elem == Element(TextElem.self))
        #expect(fields == nil)
    }

    @Test func constructFromStr() throws {
        // selector("hi") → regex selector (text is regex-escaped).
        let v = try call(TypstLibrary.selectorConstruct, [s("hi.there")])
        guard case .regex = asSelector(v) else {
            Issue.record("expected regex selector, got \(v.repr())"); return
        }
        // Empty string → "text selector is empty".
        switch harness.call(TypstLibrary.selectorConstruct, harness.args([s("")])) {
        case .failure(let r):
            #expect(r.diagnostics.contains {
                $0.message == "text selector is empty" })
        case .success:
            Issue.record("expected error")
        }
        // Non-element function → error.
        switch harness.call(TypstLibrary.selectorConstruct,
                            harness.args([.function(Func(native: intConstruct))])) {
        case .failure(let r):
            #expect(r.diagnostics.contains {
                $0.message == "only element functions can be used as selectors" })
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func orAnd() throws {
        let textSel = try call(TypstLibrary.selectorConstruct,
                               [.function(Element(TextElem.self).function)])
        let rawSel = try call(TypstLibrary.selectorConstruct,
                              [.function(Element(RawElem.self).function)])
        // or: others first, self last (upstream order).
        let or = try call(TypstLibrary.selectorOr, [textSel, rawSel])
        guard case .or(let list) = asSelector(or) else {
            Issue.record("expected or, got \(or.repr())"); return
        }
        #expect(list.count == 2)
        // and similarly.
        let and = try call(TypstLibrary.selectorAnd, [textSel, rawSel])
        guard case .and = asSelector(and) else {
            Issue.record("expected and"); return
        }
    }

    @Test func beforeAfterWithin() throws {
        let textSel = try call(TypstLibrary.selectorConstruct,
                               [.function(Element(TextElem.self).function)])
        // LocatableSelector accepts element funcs; text elem is locatable.
        let before = try call(TypstLibrary.selectorBefore, [textSel, textSel],
                              named: [FuncHarness.named("inclusive", .bool(false))])
        guard case .before(_, let end, let inclusive) = asSelector(before) else {
            Issue.record("expected before, got \(before.repr())"); return
        }
        #expect(inclusive == false)
        #expect(end.repr() == "text")
        // Non-locatable selector (regex) → "text is not locatable".
        let regexSel = try call(TypstLibrary.selectorConstruct, [s("x")])
        switch harness.call(TypstLibrary.selectorBefore,
                            harness.args([textSel, regexSel])) {
        case .failure(let r):
            #expect(r.diagnostics.contains {
                $0.message == "text is not locatable" })
        case .success:
            Issue.record("expected error")
        }
        // within requires locatable ancestor too.
        let within = try call(TypstLibrary.selectorWithin, [textSel, textSel])
        guard case .within = asSelector(within) else {
            Issue.record("expected within"); return
        }
    }
}
