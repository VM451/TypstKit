import Foundation
import Testing
import TypstSyntax
@testable import TypstLibrary

/// Tests for `AssetElem`/`AssetData`/`BundlePath` (`model/asset.rs`,
/// `foundations/path.rs`) and `FigureElem`/`FigureCaption`/`FigureKind`/
/// `Figurable` (`model/figure.rs`).
@Suite("FigureAsset")
struct FigureAssetTests {
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

    private func firstElem(_ content: Content) -> PackedElement? {
        if let seq = content.packed.element as? SequenceElem,
           let first = seq.children.first {
            return first.packed
        }
        return content.packed
    }

    // MARK: - asset

    @Test func assetElement() throws {
        let content = try markup("#asset(\"dir/a.txt\", \"hi\")")
        let elem = try #require(firstElem(content)?.element as? AssetElem)
        #expect(elem.path.path.withSlash == "/dir/a.txt")
        #expect(elem.data.bytes.storage == Array("hi".utf8))
    }

    @Test func assetDataCast() throws {
        let fromStr = try AssetData.fromValue(.str(Str("abc"))).get()
        #expect(fromStr.bytes.storage == Array("abc".utf8))
        let fromBytes = try AssetData.fromValue(.bytes(Bytes([1, 2]))).get()
        #expect(fromBytes.bytes.storage == [1, 2])
        if case .success = AssetData.fromValue(.int(1)) {
            Issue.record("expected cast failure")
        }
    }

    @Test func bundlePathCast() throws {
        let p = try BundlePath.fromValue(.str(Str("a/b.txt"))).get()
        #expect(p.path.withSlash == "/a/b.txt")
        #expect(p.intoValue() == .str(Str("/a/b.txt")))
        // Root path is rejected.
        if case .success = BundlePath.fromValue(.str(Str("/"))) {
            Issue.record("expected root rejection")
        }
        // Escaping paths are rejected.
        if case .success = BundlePath.fromValue(.str(Str("../x"))) {
            Issue.record("expected escape rejection")
        }
        // Backslashes produce the dedicated hint.
        if case let .failure(e) = BundlePath.fromValue(.str(Str("a\\b"))) {
            #expect(e.hints.contains { $0.contains("forward slashes") })
        } else {
            Issue.record("expected backslash failure")
        }
    }

    // MARK: - figure

    @Test func figureDefaults() throws {
        let content = try markup("#figure[body]")
        let elem = try #require(firstElem(content)?.element as? FigureElem)
        #expect(elem.scope == .column)
        #expect(elem.placement == nil)
        #expect(elem.caption == nil)
        #expect(elem.kind.isAuto)
        #expect(elem.supplement.isAuto)
        #expect(elem.numbering == .pattern(
            NumberingPattern(pieces: [("", .arabic)], suffix: "")))
        #expect(elem.gap == Length(Em(0.65)))
        #expect(elem.outlined)
        #expect(elem.alt == nil)
    }

    @Test func figureFields() throws {
        let content = try markup(
            "#figure([x], alt: \"desc\", placement: bottom, scope: \"parent\"," +
            " caption: [cap], kind: \"atom\", supplement: [Atom]," +
            " numbering: \"1.\", gap: 1em, outlined: false)")
        let elem = try #require(firstElem(content)?.element as? FigureElem)
        #expect(elem.alt == Str("desc"))
        #expect(elem.placement == .some(.custom(.bottom)))
        #expect(elem.scope == .parent)
        #expect(elem.caption != nil)
        #expect(!elem.supplement.isAuto)
        #expect(elem.kind == .custom(.name(Str("atom"))))
        #expect(elem.numbering != nil)
        #expect(elem.gap == Length(Em(1.0)))
        #expect(!elem.outlined)
    }

    @Test func figureCaptionWrapsContent() throws {
        // `caption: [cap]` wraps plain content into a FigureCaption.
        let content = try markup("#figure([x], caption: [A glacier])")
        let elem = try #require(firstElem(content)?.element as? FigureElem)
        let caption = try #require(elem.caption)
        #expect(caption.position == .bottom)
        #expect(caption.separator.isAuto)
        #expect(caption.body.packed(TextElem.self) != nil)
    }

    @Test func figureCaptionElement() throws {
        let content = try markup("#figure.caption(position: top)[cap]")
        let elem = try #require(firstElem(content)?.element as? FigureCaption)
        #expect(elem.position == .top)
        #expect(elem.body.packed(TextElem.self) != nil)
    }

    @Test func figureCaptionScope() throws {
        let world = MockWorld()
        let figure = world.library.value.scope.get("figure")
        guard let figure,
              case let .function(f) = figure.value,
              let scope = f.element?.info.scope,
              let binding = scope.get("caption"),
              case let .function(c) = binding.value else {
            Issue.record("figure.caption not registered"); return
        }
        #expect(c.element?.info.name == "caption")
    }

    @Test func figureKindCast() throws {
        // Element function -> .elem
        let world = MockWorld()
        let tableFn = world.library.value.scope.get("table")?.value
        guard case let .function(f) = tableFn else {
            Issue.record("table not registered"); return
        }
        let kind = try FigureKind.fromValue(.function(f)).get()
        guard case let .elem(e) = kind else {
            Issue.record("expected elem kind"); return
        }
        #expect(e == Element(TableElem.self))
        // String -> .name
        let named = try FigureKind.fromValue(.str(Str("atom"))).get()
        #expect(named == .name(Str("atom")))
        // Round-trip.
        #expect(kind.intoValue() == .function(f))
        // Invalid values fail.
        if case .success = FigureKind.fromValue(.int(1)) {
            Issue.record("expected cast failure")
        }
    }

    @Test func figureKindField() throws {
        let content = try markup("#figure([x], kind: table)")
        let elem = try #require(firstElem(content)?.element as? FigureElem)
        guard case let .custom(.elem(e)) = elem.kind else {
            Issue.record("expected elem kind"); return
        }
        #expect(e == Element(TableElem.self))
    }

    @Test func figurable() {
        // Marker conformance for auto-detection (upstream impls on
        // ImageElem/TableElem/RawElem; ImageElem lands later).
        func accepts<T: Figurable>(_: T.Type) {}
        accepts(TableElem.self)
        accepts(RawElem.self)
    }

    @Test func figureShowSet() {
        let elem = FigureElem(body: TextElem.packed("x"))
        let styles = elem.showSet(styles: StyleChain())
        var found = Set<String>()
        for style in styles.items {
            guard case let .property(p) = style.value else { continue }
            found.insert("\(p.elem.name).\(p.field)")
        }
        #expect(found.contains("block.2"))
        #expect(found.contains("align.0"))
    }

    @Test func captionCastWraps() throws {
        // Any content casts into a FigureCaption body.
        let c = TextElem.packed("plain")
        let caption = try FigureCaption.fromValue(c.intoValue()).get()
        #expect(caption.body == c)
        // An existing caption unpacks unchanged.
        let existing = FigureCaption(body: c)
        let again = try FigureCaption.fromValue(existing.pack().intoValue()).get()
        #expect(again.body == c)
        if case .success = FigureCaption.fromValue(.int(1)) {
            Issue.record("expected cast failure")
        }
    }
}
