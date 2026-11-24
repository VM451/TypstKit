import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `function` scope — port of
/// `Func::with`/`Func::where_` in upstream `foundations/func.rs`.
@Suite struct FuncScopeTests {
    let harness = FuncHarness()

    private func i(_ v: Int64) -> Value { .int(v) }
    private func s(_ v: String) -> Value { .str(Str(v)) }

    private func call(_ f: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(f, args))
    }

    @Test func funcWith() throws {
        // `int.with(16)` style: pre-applies args, returns a function.
        let base = Value.function(Func(native: intConstruct))
        let result = try call(TypstLibrary.funcWith, [base, i(16)])
        guard case .function(let f) = result else {
            Issue.record("expected function"); return
        }
        // Upstream reprs a `with` function as "(..) => ..".
        #expect(f.repr() == "(..) => ..")
        // with() consumes ALL remaining args (positional + named).
        let result2 = try call(TypstLibrary.funcWith,
                               [base, i(2), s("ff")],
                               named: [FuncHarness.named("base", i(16))])
        guard case .function = result2 else {
            Issue.record("expected function"); return
        }
    }

    @Test func funcWhereNonElement() {
        // `where` on a non-element function errors.
        let base = Value.function(Func(native: intConstruct))
        switch harness.call(TypstLibrary.funcWhere,
                            harness.args([base, i(1)])) {
        case .failure(let r):
            #expect(r.diagnostics.contains {
                $0.message.contains("`where()` can only be called on element functions") })
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func funcWhereElement() throws {
        let textFunc = Value.function(Element(TextElem.self).function)
        // Valid field → selector value.
        let sel = try call(TypstLibrary.funcWhere, [textFunc],
                           named: [FuncHarness.named("text", s("hi"))])
        guard case .dynamic(let d) = sel, d.is(TypstLibrary.Selector.self) else {
            Issue.record("expected selector dynamic, got \(sel.repr())"); return
        }
        // Unknown field → element/field error.
        switch harness.call(TypstLibrary.funcWhere,
                            { var a = harness.args([textFunc])
                               a.items.append(FuncHarness.named("bogus", i(1)))
                               return a }()) {
        case .failure(let r):
            #expect(r.diagnostics.contains {
                $0.message == "element `text` does not have field `bogus`" })
        case .success:
            Issue.record("expected error")
        }
        // Positional leftovers → unexpected argument.
        switch harness.call(TypstLibrary.funcWhere,
                            harness.args([textFunc, i(1)])) {
        case .failure(let r):
            #expect(r.diagnostics.contains {
                $0.message.contains("unexpected argument") } == true)
        case .success:
            Issue.record("expected error")
        }
    }
}
