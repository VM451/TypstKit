import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `symbol()` constructor — port of
/// upstream `Symbol::construct` validation in `foundations/symbol.rs`.
@Suite struct SymbolTests {
    let harness = FuncHarness()

    private func eval(_ values: [Value]) throws -> Value {
        try harness.unwrap(harness.call(symbolConstruct, harness.args(values)))
    }

    private func s(_ v: String) -> Value { .str(Str(v)) }
    private func arr(_ items: [Value]) -> Value {
        .array(ArrayValue(items: items))
    }

    private func symbolValue(_ v: Value) -> Symbol? {
        guard case .symbol(let sym) = v else { return nil }
        return sym
    }

    @Test func symbolConstructSingle() throws {
        let v = try eval([s("a")])
        #expect(symbolValue(v)?.get == "a")
        // Multi-codepoint grapheme cluster is allowed.
        #expect(symbolValue(try eval([s("👨‍👩‍👧‍👦")]))?.get == "👨‍👩‍👧‍👦")
    }

    @Test func symbolConstructVariants() throws {
        // ["mods", "char"] pair form.
        let v = try eval([
            s("🖂"),
            arr([s("stamped"), s("🖃")]),
            arr([s("stamped.pen"), s("🖆")]),
            arr([s("lightning"), s("🖄")]),
        ])
        let sym = symbolValue(v)
        #expect(sym?.get == "🖂")
        #expect(sym?.variants.count == 4)
    }

    @Test func symbolConstructErrors() {
        // No variants.
        switch harness.call(symbolConstruct, harness.args([])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "expected at least one variant")
        case .success:
            Issue.record("expected error")
        }
        // Empty / multi-grapheme value.
        for bad in ["", "ab"] {
            switch harness.call(symbolConstruct, harness.args([s(bad)])) {
            case .failure(let r):
                #expect(r.diagnostics.first?.message.hasPrefix(
                    "invalid variant value:") == true)
                #expect(r.diagnostics.first?.hints.contains {
                    $0.value.contains("grapheme cluster") } == true)
            case .success:
                Issue.record("expected error for \(bad)")
            }
        }
        // Invalid modifier (not an ident).
        switch harness.call(symbolConstruct,
                            harness.args([arr([s("not an ident"), s("x")])])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message.hasPrefix(
                "invalid symbol modifier:") == true)
        case .success:
            Issue.record("expected error")
        }
        // Duplicate modifier within one variant.
        switch harness.call(symbolConstruct,
                            harness.args([arr([s("a.a"), s("x")])])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message.hasPrefix(
                "duplicate modifier within variant:") == true)
        case .success:
            Issue.record("expected error")
        }
        // Duplicate default variant.
        switch harness.call(symbolConstruct, harness.args([s("a"), s("b")])) {
        case .failure(let r):
            #expect(r.diagnostics.contains {
                $0.message == "duplicate default variant" } == true)
        case .success:
            Issue.record("expected error")
        }
        // Same modifier set in different order → duplicate with hint.
        switch harness.call(symbolConstruct, harness.args([
            arr([s("a.b"), s("x")]),
            arr([s("b.a"), s("y")]),
        ])) {
        case .failure(let r):
            #expect(r.diagnostics.contains {
                $0.message.hasPrefix("duplicate variant:") } == true)
            #expect(r.diagnostics.contains {
                $0.hints.contains {
                    $0.value.contains("regardless of their order") } } == true)
        case .success:
            Issue.record("expected error")
        }
        // Identical raw modifier string → duplicate without ordering hint.
        switch harness.call(symbolConstruct, harness.args([
            arr([s("a.b"), s("x")]),
            arr([s("a.b"), s("y")]),
        ])) {
        case .failure(let r):
            #expect(r.diagnostics.contains {
                $0.message == "duplicate variant: \"a.b\"" } == true)
        case .success:
            Issue.record("expected error")
        }
        // Variant array must have exactly two entries.
        switch harness.call(symbolConstruct,
                            harness.args([arr([s("a")])])) {
        case .failure:
            break
        case .success:
            Issue.record("expected error")
        }
    }
}
