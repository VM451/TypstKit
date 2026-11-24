import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for `target()` and the `Target` cast enum — port coverage for
/// upstream `foundations/target.rs`.
@Suite("Target")
struct TargetTests {
    let harness = FuncHarness()

    /// Call `target()` with a given context.
    private func callTarget(_ context: Context) -> SourceResult<Value> {
        var engine = harness.engine
        var args = TypstLibrary.Args(span: .detached)
        return targetFunc.function(&engine, context, &args)
    }

    @Test func targetRequiresContext() {
        // No styles in context → contextual error.
        #expect(throws: (any Error).self) {
            try harness.unwrap(callTarget(Context()))
        }
    }

    @Test func targetDefaultsToPaged() throws {
        let chain = StyleChain.new(root: Styles())
        let result = try harness.unwrap(callTarget(Context(styles: chain)))
        #expect(result == .str(Str("paged")))
    }

    @Test func targetReadsStyleProperty() throws {
        var styles = Styles()
        styles.append(Property(
            elem: Element(TargetElem.self), field: 0,
            value: .str(Str("html"))))
        let chain = StyleChain.new(root: styles)
        let result = try harness.unwrap(callTarget(Context(styles: chain)))
        #expect(result == .str(Str("html")))
    }

    @Test func targetCastsRoundtrip() throws {
        #expect(try unwrap(Target.fromValue(.str(Str("paged")))) == .paged)
        #expect(try unwrap(Target.fromValue(.str(Str("html")))) == .html)
        #expect(try unwrap(Target.fromValue(.str(Str("bundle")))) == .bundle)
        #expect(Target.paged.intoValue() == .str(Str("paged")))
        #expect(Target.html.intoValue() == .str(Str("html")))
        #expect(Target.bundle.intoValue() == .str(Str("bundle")))
        #expect(Target.html.isHtml)
        #expect(!Target.paged.isHtml)
    }

    @Test func targetRejectsBadString() {
        #expect(throws: (any Error).self) {
            _ = try unwrap(Target.fromValue(.str(Str("wasm"))))
        }
    }

    @Test func targetElemFieldRoundtrip() throws {
        var elem = TargetElem(target: .bundle)
        #expect(elem.field(0) == .str(Str("bundle")))
        try elem.setField(0, .str(Str("html")))
        #expect(elem.target == .html)
    }
}
