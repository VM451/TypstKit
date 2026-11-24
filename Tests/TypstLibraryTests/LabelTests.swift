import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `label` constructor — mirrors the
/// portable assertions from upstream `tests/suite/foundations/label.typ`.
@Suite struct LabelTests {
    let harness = FuncHarness()

    private func eval(_ data: NativeFuncData, _ values: [Value]) throws -> Value {
        try harness.unwrap(harness.call(data, harness.args(values)))
    }

    private func s(_ v: String) -> Value { .str(Str(v)) }

    @Test func construct() throws {
        let result = try eval(labelConstruct, [s("intro")])
        guard case .label(let label) = result else {
            Issue.record("expected label, got \(result)")
            return
        }
        #expect(label.name.value == "intro")
        #expect(label.repr() == "<intro>")
    }

    @Test func constructSpecialCharacters() throws {
        // Unlike `<name>` syntax, the constructor accepts any non-empty
        // string, including characters invalid in label literals.
        let result = try eval(labelConstruct, [s("not a valid <label>")])
        guard case .label(let label) = result else {
            Issue.record("expected label")
            return
        }
        #expect(label.name.value == "not a valid <label>")
        // repr falls back to `label("...")` for non-literal names.
        #expect(label.repr().hasPrefix("label("))
    }

    @Test func constructEmptyError() {
        switch harness.call(labelConstruct, harness.args([s("")])) {
        case .failure(let r):
            #expect(r.diagnostics.first?.message == "label name must not be empty")
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func strConversion() throws {
        // `str(label)` yields the resolved name (upstream cast).
        let label = try eval(labelConstruct, [s("hey")])
        let result = try harness.unwrap(harness.call(
            strConstruct, harness.args([label])))
        #expect(result == s("hey"))
    }
}
