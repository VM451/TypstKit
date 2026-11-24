import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Direct-invocation tests for the `content` scope — port of
/// `Content`'s `#[scope]` methods in upstream `foundations/content/mod.rs`.
@Suite struct ContentScopeTests {
    let harness = FuncHarness()

    private func s(_ v: String) -> Value { .str(Str(v)) }

    private func call(_ f: NativeFuncData, _ values: [Value],
                      named: [TypstLibrary.Arg] = []) throws -> Value {
        var args = harness.args(values)
        args.items.append(contentsOf: named)
        return try harness.unwrap(harness.call(f, args))
    }

    @Test func contentFunc() throws {
        let text = TextElem.packed("hi")
        let v = try call(TypstLibrary.contentFunc, [.content(text)])
        guard case .function(let f) = v else {
            Issue.record("expected function"); return
        }
        #expect(f.element == Element(TextElem.self))
    }

    @Test func contentHas() throws {
        let text = TextElem.packed("hi")
        // text elem has field "text".
        #expect(try call(TypstLibrary.contentHas, [.content(text), s("text")])
            == .bool(true))
        #expect(try call(TypstLibrary.contentHas, [.content(text), s("bogus")])
            == .bool(false))
        // Label field: present only when labelled.
        #expect(try call(TypstLibrary.contentHas, [.content(text), s("label")])
            == .bool(false))
    }

    @Test func contentAt() throws {
        let text = TextElem.packed("hi")
        #expect(try call(TypstLibrary.contentAt, [.content(text), s("text")])
            == s("hi"))
        // Missing field + default → default.
        #expect(try call(TypstLibrary.contentAt, [.content(text), s("bogus")],
                         named: [FuncHarness.named("default", s("d"))])
            == s("d"))
        // Missing field, no default → error.
        switch harness.call(TypstLibrary.contentAt,
                            harness.args([.content(text), s("bogus")])) {
        case .failure(let r):
            #expect(r.diagnostics.contains {
                $0.message.contains("does not have field") } == true)
        case .success:
            Issue.record("expected error")
        }
    }

    @Test func contentFields() throws {
        let text = TextElem.packed("hi")
        let v = try call(TypstLibrary.contentFields, [.content(text)])
        guard case .dict(let d) = v else {
            Issue.record("expected dict"); return
        }
        #expect(d.get("text") == s("hi"))
    }

    @Test func contentLocation() throws {
        // Unlocated content → none.
        let v = try call(TypstLibrary.contentLocation,
                         [.content(TextElem.packed("hi"))])
        #expect(v == .none)
    }
}
