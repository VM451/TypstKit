import Testing
@testable import TypstSyntax

/// Smoke tests for the typed AST accessors (port of `ast.rs` semantics,
/// verified against freshly parsed trees).
@Suite("AST")
struct AstTests {
    /// Parse `text` and return the typed markup root.
    private func markup(_ text: String) -> Markup {
        let root = parse(text)
        return Markup(node: root)!
    }

    /// The expressions of a markup document.
    private func exprs(_ text: String) -> [Expr] {
        markup(text).exprs()
    }

    /// The single expression of a one-expression document.
    private func singleExpr(_ text: String) -> Expr {
        let result = exprs(text)
        #expect(result.count == 1)
        return result.first ?? Expr.placeholder
    }

    /// The first expression inside an embedded code block `#{inner}`.
    private func codeExpr(_ inner: String) -> Expr {
        guard case .codeBlock(let block) = singleExpr("#{\(inner)}") else {
            Issue.record("expected code block for `#{\(inner)}`")
            return Expr.placeholder
        }
        let inner_exprs = block.body().exprs()
        #expect(!inner_exprs.isEmpty)
        return inner_exprs.first ?? Expr.placeholder
    }

    @Test func exprPlaceholder() {
        // Port of upstream `test_expr_placeholder`.
        #expect(Expr.placeholder.node.cast(Expr.self) != nil)
    }

    @Test func markupExprs() {
        let result = exprs("Hello *world* _emph_ `raw` #let x = 1")
        #expect(result.count == 9)
        guard case .text = result[0],
              case .space = result[1],
              case .strong = result[2],
              case .space = result[3],
              case .emph = result[4],
              case .raw = result[6],
              case .letBinding = result[8] else {
            Issue.record("unexpected markup exprs")
            return
        }
    }

    @Test func headingAndLists() {
        guard case .heading(let h) = singleExpr("= Title") else {
            Issue.record("expected heading"); return
        }
        #expect(h.depth() == 1)
        #expect(h.body().exprs().count == 1)

        guard case .enumItem(let e) = singleExpr("+ item") else {
            Issue.record("expected enum item"); return
        }
        #expect(e.number() == nil)
        #expect(e.body().exprs().count == 1)

        guard case .enumItem(let e2) = singleExpr("23. item") else {
            Issue.record("expected numbered enum item"); return
        }
        #expect(e2.number() == 23)
    }

    @Test func rawAndLink() {
        guard case .raw(let raw) = singleExpr("`code`") else {
            Issue.record("expected raw"); return
        }
        #expect(!raw.block())
        #expect(raw.lang() == nil)
        #expect(raw.lines().count == 1)

        guard case .link(let link) = singleExpr("https://typst.org") else {
            Issue.record("expected link"); return
        }
        #expect(link.get() == "https://typst.org")

        guard case .label(let label) = singleExpr("<intro>") else {
            Issue.record("expected label"); return
        }
        #expect(label.get() == "intro")

        guard case .ref(let ref) = singleExpr("@target") else {
            Issue.record("expected ref"); return
        }
        #expect(ref.target() == "target")
    }

    @Test func literals() {
        guard case .bool(let b) = singleExpr("#true") else {
            Issue.record("expected bool"); return
        }
        #expect(b.get())

        guard case .int(let i) = singleExpr("#120") else {
            Issue.record("expected int"); return
        }
        #expect(try! i.get().get() == 120)

        guard case .int(let hex) = singleExpr("#0xFF") else {
            Issue.record("expected hex int"); return
        }
        #expect(try! hex.get().get() == 255)

        guard case .float(let f) = singleExpr("#1.5") else {
            Issue.record("expected float"); return
        }
        #expect(f.get() == 1.5)

        guard case .numeric(let n) = singleExpr("#12pt") else {
            Issue.record("expected numeric"); return
        }
        #expect(n.get().0 == 12)
        #expect(n.get().1 == .pt)

        guard case .str(let s) = singleExpr("#\"a\\nb\"") else {
            Issue.record("expected str"); return
        }
        #expect(s.get() == "a\nb")

        guard case .none = singleExpr("#none") else {
            Issue.record("expected none"); return
        }
    }

    @Test func intErrors() {
        // 2^63 overflows i64; exactly i64.max + 1 marks maxPlusOne.
        let big = SyntaxNode.leaf(.int, "9223372036854775808")
        let expr = IntExpr(node: big)!
        switch expr.get() {
        case .failure(.posOverflow(_, let maxPlusOne)):
            #expect(maxPlusOne)
        default:
            Issue.record("expected posOverflow(maxPlusOne)")
        }

        let bad = SyntaxNode.leaf(.int, "0xGG")
        let badExpr = IntExpr(node: bad)!
        switch badExpr.get() {
        case .failure(.invalidDigit(let base, let digits)):
            #expect(base == .hex)
            #expect(digits == "GG")
        default:
            Issue.record("expected invalidDigit")
        }
    }

    @Test func codeExprs() {
        // Binary op.
        guard case .binary(let bin) = codeExpr("1 + 2") else {
            Issue.record("expected binary"); return
        }
        #expect(bin.op() == .add)
        #expect(bin.lhs().node.kind == .int)
        #expect(bin.rhs().node.kind == .int)

        // `not in` composite operator.
        guard case .binary(let notIn) = codeExpr("1 not in x") else {
            Issue.record("expected binary"); return
        }
        #expect(notIn.op() == .notIn)

        // Field access.
        guard case .fieldAccess(let fa) = codeExpr("a.b") else {
            Issue.record("expected field access"); return
        }
        #expect(fa.field().get() == "b")

        // Function call with trailing comma.
        guard case .funcCall(let call) = codeExpr("f(1, 2,)") else {
            Issue.record("expected func call"); return
        }
        #expect(call.args().items().count == 2)
        #expect(call.args().trailingComma())

        // Array & dict.
        guard case .array(let arr) = codeExpr("(1, ..rest)") else {
            Issue.record("expected array"); return
        }
        #expect(arr.items().count == 2)
        guard case .spread = arr.items()[1] else {
            Issue.record("expected spread item"); return
        }

        guard case .dict(let dict) = codeExpr("(a: 1, \"b c\": 2)") else {
            Issue.record("expected dict"); return
        }
        #expect(dict.items().count == 2)
    }

    @Test func bindings() {
        guard case .letBinding(let lb) = codeExpr("let x = 1") else {
            Issue.record("expected let binding"); return
        }
        #expect(lb.kind().bindings().map { $0.get() } == ["x"])
        guard case .int = lb.initExpr() else {
            Issue.record("expected int init"); return
        }

        // Closure sugar: `let f(x) = x`.
        guard case .letBinding(let cl) = codeExpr("let f(x) = x") else {
            Issue.record("expected closure let"); return
        }
        guard case .closure(let ident) = cl.kind() else {
            Issue.record("expected closure kind"); return
        }
        #expect(ident.get() == "f")

        // Destructuring bindings.
        guard case .letBinding(let db) = codeExpr("let (a, b) = (1, 2)") else {
            Issue.record("expected destructuring let"); return
        }
        #expect(db.kind().bindings().map { $0.get() } == ["a", "b"])
    }

    @Test func controlFlow() {
        guard case .conditional(let cond) = codeExpr("if x { 1 } else { 2 }") else {
            Issue.record("expected conditional"); return
        }
        #expect(cond.condition().node.kind == .ident)
        #expect(cond.ifBody().node.kind == .codeBlock)
        #expect(cond.elseBody()?.node.kind == .codeBlock)

        guard case .forLoop(let loop) = codeExpr("for x in y { z }") else {
            Issue.record("expected for loop"); return
        }
        #expect(loop.iterable().node.kind == .ident)
        #expect(loop.body().node.kind == .codeBlock)

        guard case .setRule(let set) = codeExpr("set text(size: 1pt) if x") else {
            Issue.record("expected set rule"); return
        }
        #expect(set.condition()?.node.kind == .ident)
    }

    @Test func imports() {
        guard case .moduleImport(let imp) = codeExpr("import \"foo.typ\": a, b as c") else {
            Issue.record("expected import"); return
        }
        #expect(try! imp.bareName().get() == "foo")
        guard case .items(let items) = imp.imports() else {
            Issue.record("expected import items"); return
        }
        let list = items.items()
        #expect(list.count == 2)
        #expect(list[0].boundName().get() == "a")
        #expect(list[1].boundName().get() == "c")
        #expect(list[1].originalName().get() == "b")
    }

    @Test func mathExprs() {
        guard case .equation(let eq) = singleExpr("$x_1^2$") else {
            Issue.record("expected equation"); return
        }
        #expect(!eq.block())
        let math = eq.body()
        #expect(!math.exprs().isEmpty)
    }

    @Test func mathAttach() {
        let root = parse("$a_1^2$")
        // Find the MathAttach node anywhere in the tree.
        var found: MathAttach? = nil
        root.traverse { node in
            if let attach = node.cast(MathAttach.self) { found = attach }
            return node.children
        }
        guard let attach = found else {
            Issue.record("expected math attach"); return
        }
        #expect(attach.base().node.kind == .mathLetter)
        #expect(attach.bottom()?.node.kind == .mathNumber)
        #expect(attach.top()?.node.kind == .mathNumber)
    }

    @Test func shorthandGet() {
        let root = parse("a ~ b -- c")
        var shorthands: [Shorthand] = []
        root.traverse { node in
            if let s = node.cast(Shorthand.self) { shorthands.append(s) }
            return node.children
        }
        #expect(shorthands.count == 2)
        #expect(shorthands.first?.get() == "\u{00A0}")
        #expect(shorthands.last?.get() == "–")
    }
}
