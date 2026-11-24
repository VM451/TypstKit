import Foundation
import Testing
import TypstSyntax
@testable import TypstLibrary

/// End-to-end evaluation tests for the ported `typst-eval` core:
/// literals, collections, operators, bindings, and control flow.
@Suite("Eval")
struct EvalTests {
    /// Evaluate a code expression string and return the final value.
    private func eval(_ source: String) throws -> Value {
        let node = parseCode(source)
        guard let code = node.cast(Code.self) else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                Span.detached, "test harness: expected code"))
        }
        let world = MockWorld()
        let engine = Engine(world: world)
        var vm = Vm(
            engine: engine,
            context: Context(),
            scopes: Scopes(base: world.library.value.scope),
            inspected: nil)
        var index = 0
        return try evalCode(&vm, code.exprs(), &index)
    }

    /// Evaluate and unwrap to a concrete `Value`.
    private func value(_ source: String) throws -> Value {
        try eval(source)
    }

    @Test func literals() throws {
        #expect(try value("1") == .int(1))
        #expect(try value("1.5") == .float(1.5))
        #expect(try value("true") == .bool(true))
        #expect(try value("none") == .none)
        #expect(try value("auto") == .auto)
        #expect(try value("\"hi\"") == .str(Str("hi")))
    }

    @Test func arithmetic() throws {
        #expect(try value("1 + 2") == .int(3))
        #expect(try value("5 - 8") == .int(-3))
        #expect(try value("3 * 4") == .int(12))
        #expect(try value("7 / 2") == .float(3.5))
        #expect(try value("-5") == .int(-5))
        #expect(try value("+5") == .int(5))
        #expect(try value("not false") == .bool(true))
        #expect(try value("1 < 2") == .bool(true))
        #expect(try value("2 <= 1") == .bool(false))
        #expect(try value("3 == 3") == .bool(true))
        #expect(try value("3 != 3") == .bool(false))
    }

    @Test func booleanOps() throws {
        #expect(try value("true and false") == .bool(false))
        #expect(try value("true or false") == .bool(true))
        #expect(try value("false and (1 / 0 > 0)") == .bool(false))
        #expect(try value("true or (1 / 0 > 0)") == .bool(true))
    }

    @Test func collections() throws {
        #expect(try value("(1, 2, 3)") == .array(ArrayValue(items: [
            .int(1), .int(2), .int(3)])))
        #expect(try value("(a: 1, b: 2)") == .dict(Dict([
            (Str("a"), .int(1)), (Str("b"), .int(2))])))
        #expect(try value("(1, 2).len()") == .int(2))
        #expect(try value("(a: 1).a") == .int(1))
    }

    @Test func letBindings() throws {
        #expect(try value("let x = 4; x * 2") == .int(8))
        #expect(try value("let (a, b) = (1, 2); a + b") == .int(3))
        #expect(try value("let (k: v) = (k: 9); v") == .int(9))
    }

    @Test func conditionals() throws {
        #expect(try value("if true { 1 } else { 2 }") == .int(1))
        #expect(try value("if false { 1 } else { 2 }") == .int(2))
        #expect(try value("if false { 1 }") == .none)
    }

    @Test func loops() throws {
        #expect(try value("let s = 0; for i in range(5) { s += i }; s") == .int(10))
        #expect(try value("let s = 0; for i in (1, 2, 3) { s += i }; s") == .int(6))
        #expect(try value("let i = 0; while i < 3 { i += 1 }; i") == .int(3))
    }

    @Test func assignments() throws {
        #expect(try value("let x = 1; x = 5; x") == .int(5))
        #expect(try value("let x = 1; x += 4; x") == .int(5))
        #expect(try value("let d = (a: 1); d.a = 7; d.a") == .int(7))
        #expect(try value("let a = (1, 2); a.push(3); a") ==
            .array(ArrayValue(items: [.int(1), .int(2), .int(3)])))
    }

    @Test func stringOps() throws {
        #expect(try value("\"a\" + \"b\"") == .str(Str("ab")))
        #expect(try value("\"abc\".len()") == .int(3))
    }

    @Test func closures() throws {
        #expect(try value("let f = (x) => x * 2; f(3)") == .int(6))
        #expect(try value("let add = (a, b) => a + b; add(2, 3)") == .int(5))
        #expect(try value("let f = (x, y: 10) => x + y; f(1)") == .int(11))
        #expect(try value("let f = (x, y: 10) => x + y; f(1, y: 5)") == .int(6))
        #expect(try value("let f = (..args) => args.pos().len(); f(1, 2, 3)") == .int(3))
        #expect(try value("let x = 7; let f = () => x; f()") == .int(7))
        #expect(try value("let f = (x) => { return x + 1 }; f(4)") == .int(5))
        #expect(try value("let f = (x) => x; let g = (y) => f(y) * 2; g(3)") == .int(6))
    }

    @Test func methodCalls() throws {
        #expect(try value("(1, 2, 3).map(calc.abs).len()") == .int(3))
        #expect(try value("(a: 1, b: 2).len()") == .int(2))
        #expect(try value("\"hello\".len()") == .int(5))
        #expect(try value("(1, 2, 3).rev().at(0)") == .int(3))
        #expect(try value("let a = (1,); a.push(2); a.len()") == .int(2))
    }

    /// Evaluate markup source and return the resulting content.
    private func markup(_ source: String) throws -> Content {
        let node = parse(source)
        guard let markup = node.cast(Markup.self) else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                Span.detached, "test harness: expected markup"))
        }
        let world = MockWorld()
        let engine = Engine(world: world)
        var vm = Vm(
            engine: engine,
            context: Context(),
            scopes: Scopes(base: world.library.value.scope),
            inspected: nil)
        return try markup.eval(&vm)
    }

    /// Element names of a (possibly sequenced) content value.
    private func elemNames(_ content: Content) -> [String] {
        if let seq = content.packed.element as? SequenceElem {
            return seq.children.map { $0.elem.name }
        }
        return [content.elem.name]
    }

    @Test func markupEval() throws {
        // Plain text produces a text element.
        let text = try markup("Hello")
        #expect(elemNames(text) == ["text"])

        // Strong/emph produce their elements.
        let styled = try markup("a *b* _c_")
        #expect(styled.elem.name == "sequence")
        if let seq = styled.packed.element as? SequenceElem {
            #expect(seq.children.contains { $0.elem.name == "strong" })
            #expect(seq.children.contains { $0.elem.name == "emph" })
        }

        // Space and parbreak.
        let spaced = try markup("a  b\n\nc")
        #expect(spaced.elem.name == "sequence")

        // Heading.
        let head = try markup("= Title")
        #expect(head.elem.name == "heading")

        // Label attaches to preceding content.
        let labelled = try markup("Hi <lbl>")
        if let seq = labelled.packed.element as? SequenceElem {
            #expect(seq.children.contains {
                $0.label?.resolved == "lbl" })
        } else {
            #expect(labelled.label?.resolved == "lbl")
        }

        // List items evaluate to item elements.
        let item = try markup("- entry")
        #expect(item.elem.name == "item")
    }

    @Test func errors() {
        #expect(throws: (any Error).self) { try eval("unknownvar") }
        #expect(throws: (any Error).self) { try eval("1 + \"a\"") }
        #expect(throws: (any Error).self) { try eval("(1, 2).at(5)") }
    }
}
