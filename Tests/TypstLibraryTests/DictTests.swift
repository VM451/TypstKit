import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `dict` type scope — mirrors
/// assertions from upstream `tests/suite/foundations/dict.typ`.
/// Lvalue mutation tests (`dict.at("b") = 9`) are eval-dependent and
/// deferred to the eval milestone.
@Suite struct DictTests {
    let harness = FuncHarness()

    private func eval(_ data: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(data, args))
    }

    private func i(_ v: Int64) -> Value { .int(v) }
    private func s(_ v: String) -> Value { .str(Str(v)) }
    private func d(_ pairs: [(String, Value)]) -> Value { .dict(Dict(pairs)) }

    // MARK: constructor

    @Test func constructFromModule() throws {
        // `dict(module)` converts a module's scope bindings to pairs.
        let result = try eval(dictionaryConstruct, [.module(calcModule())])
        guard case .dict(let dict) = result else {
            Issue.record("expected dict")
            return
        }
        // calc module exposes its functions/constants.
        #expect(dict.get("pi") != nil)
        #expect(dict.get("even") != nil)
    }

    @Test func constructRequiresModule() {
        // Non-module values are rejected by the `ToDict` cast.
        switch harness.call(dictionaryConstruct, harness.args([.int(1)])) {
        case .failure:
            break
        case .success:
            Issue.record("expected error")
        }
        // No argument → missing argument.
        switch harness.call(dictionaryConstruct, harness.args([])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                .contains("missing argument") == true)
        case .success:
            Issue.record("expected error")
        }
    }

    // MARK: len / at / insert / remove / keys / values / pairs

    @Test func len() throws {
        #expect(try eval(dictLen, [d([])]) == i(0))
        #expect(try eval(dictLen, [d([("a", i(1)), ("b", i(2))])]) == i(2))
    }

    @Test func at() throws {
        let dict = d([("a", i(1)), ("b", s("two"))])
        #expect(try eval(dictAt, [dict, s("a")]) == i(1))
        #expect(try eval(dictAt, [dict, s("b")]) == s("two"))
        #expect(try eval(dictAt, [dict, s("missing")],
                         named: [FuncHarness.named("default", i(9))]) == i(9))
        #expect(try eval(dictAt, [dict, s("a")],
                         named: [FuncHarness.named("default", i(9))]) == i(1))
    }

    @Test func atMissingError() {
        switch harness.call(dictAt,
                            harness.args([d([("a", i(1))]), s("nope")])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "dictionary does not contain key \"nope\" " +
                   "and no default value was specified")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func insertRemove() throws {
        // `insert`/`remove` mutate a copy when called as plain functions;
        // the evaluator writes back for lvalues (eval milestone).
        #expect(try eval(dictInsert, [d([("a", i(1))]), s("b"), i(2)]) == .none)
        #expect(try eval(dictInsert, [d([("a", i(1))]), s("a"), i(9)]) == .none)
        #expect(try eval(dictRemove, [d([("a", i(1)), ("b", i(2))]), s("a")])
            == i(1))
    }

    @Test func removeMissingError() {
        switch harness.call(dictRemove,
                            harness.args([d([("a", i(1))]), s("nope")])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message
                == "dictionary does not contain key \"nope\"")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func keysValuesPairs() throws {
        let dict = d([("a", i(1)), ("b", s("two")), ("c", .bool(true))])
        // Insertion order is preserved (upstream IndexMap).
        #expect(try eval(dictKeys, [dict])
            == .array(ArrayValue([s("a"), s("b"), s("c")])))
        #expect(try eval(dictValues, [dict])
            == .array(ArrayValue([i(1), s("two"), .bool(true)])))
        #expect(try eval(dictPairs, [dict])
            == .array(ArrayValue([
                .array(ArrayValue([s("a"), i(1)])),
                .array(ArrayValue([s("b"), s("two")])),
                .array(ArrayValue([s("c"), .bool(true)])),
            ])))
        #expect(try eval(dictKeys, [d([])]) == .array(ArrayValue()))
        #expect(try eval(dictValues, [d([])]) == .array(ArrayValue()))
        #expect(try eval(dictPairs, [d([])]) == .array(ArrayValue()))
    }
}
