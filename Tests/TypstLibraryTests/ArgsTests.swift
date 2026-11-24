import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `arguments` scope — port of upstream
/// `Args` methods in `foundations/args.rs`.
@Suite struct ArgsTests {
    let harness = FuncHarness()

    private func i(_ v: Int64) -> Value { .int(v) }
    private func s(_ v: String) -> Value { .str(Str(v)) }

    private func eval(_ f: NativeFuncData, _ values: [Value]) throws -> Value {
        try harness.unwrap(harness.call(f, harness.args(values)))
    }

    private func mkargs(_ items: [(String?, Value)]) -> TypstLibrary.Args {
        TypstLibrary.Args(span: .detached, items: items.map {
            Arg(span: .detached, name: $0.0.map { Str($0) },
                value: Spanned.detached($0.1))
        })
    }

    private func argValue(_ v: Value) -> TypstLibrary.Args? {
        guard case .arguments(let a) = v else { return nil }
        return a
    }

    @Test func argsConstruct() throws {
        // arguments(1, x: 2, 3) → takes all incoming args as the new value.
        let callArgs = TypstLibrary.Args(span: .detached, items: [
            Arg(span: .detached, name: nil, value: Spanned.detached(i(1))),
            Arg(span: .detached, name: Str("x"), value: Spanned.detached(i(2))),
        ])
        let v = try harness.unwrap(harness.call(TypstLibrary.argsConstruct, callArgs))
        let a = argValue(v)!
        #expect(a.items.count == 2)
        #expect(a.items[0].name == nil)
        #expect(a.items[1].name == "x")
    }

    @Test func argsLen() throws {
        let a = mkargs([(nil, i(1)), ("k", i(2)), (nil, i(3))])
        #expect(try eval(TypstLibrary.argsLen, [.arguments(a)]) == i(3))
    }

    @Test func argsAt() throws {
        let a = mkargs([
            (nil, i(10)),
            ("x", s("hi")),
            (nil, i(30)),
        ])
        // Index access, negative index = from back.
        #expect(try eval(TypstLibrary.argsAt, [.arguments(a), i(0)]) == i(10))
        #expect(try eval(TypstLibrary.argsAt, [.arguments(a), i(1)]) == i(30))
        #expect(try eval(TypstLibrary.argsAt, [.arguments(a), i(-1)]) == i(30))
        // Named access picks the LAST matching name.
        let dup = mkargs([("k", i(1)), ("k", i(2))])
        #expect(try eval(TypstLibrary.argsAt, [.arguments(dup), s("k")]) == i(2))
        // Missing key → error; named `default:` overrides.
        switch harness.call(TypstLibrary.argsAt, harness.args([.arguments(a), i(9)])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message ==
                "no positional argument at index 9 and no default value was specified")
        case .success:
            Issue.record("expected error")
        }
        func withDefault(_ v: Value) -> TypstLibrary.Args {
            var args = harness.args([.arguments(a), i(9)])
            args.items.append(FuncHarness.named("default", v))
            return args
        }
        #expect(try harness.unwrap(harness.call(TypstLibrary.argsAt, withDefault(s("fallback"))))
            == s("fallback"))
        // Explicit `default: none` returns none, not an error.
        #expect(try harness.unwrap(harness.call(TypstLibrary.argsAt, withDefault(.none)))
            == .none)
    }

    @Test func argsPosAndNamed() throws {
        let a = mkargs([
            (nil, i(1)),
            ("x", i(2)),
            (nil, i(3)),
            ("y", i(4)),
        ])
        // pos() → positional only.
        let pos = try eval(TypstLibrary.argsPos, [.arguments(a)])
        guard case .array(let arr) = pos else {
            Issue.record("expected array"); return
        }
        #expect(arr.items == [i(1), i(3)])
        // named() → named only as dict.
        let named = try eval(TypstLibrary.argsNamed, [.arguments(a)])
        guard case .dict(let d) = named else {
            Issue.record("expected dict"); return
        }
        #expect(d.get("x") == i(2))
        #expect(d.get("y") == i(4))
    }
}
