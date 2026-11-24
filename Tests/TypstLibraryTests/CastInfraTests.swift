import Testing
import TypstSyntax
@testable import TypstLibrary

/// Tests for the cast/fold infrastructure ported for the container-element
/// slice: `OptionalCast` + `Sides`/`Corners` optional-component casts,
/// `DashLength`/`DashPattern`/`Stroke` value casts, and the `Fold`
/// conformances (`Bool`/`Optional`/`Smart`/`Array`/`Spanned`).
@Suite struct CastInfraTests {

    private func length(_ pt: Double) -> Length {
        Length(abs: .pt(pt), em: .zero)
    }

    private func dict(_ pairs: [(String, Value)]) -> Value {
        var d = Dict()
        for (k, v) in pairs { d.insert(k, v) }
        return .dict(d)
    }

    // MARK: - Sides<Option<T>> casts

    @Test func sidesDictFallbackChain() throws {
        // `{left: 1pt, x: 2pt, rest: 3pt}` → left=1, top=3 (rest),
        // right=2 (x), bottom=3 (rest).
        let value = dict([
            ("left", .length(length(1))),
            ("x", .length(length(2))),
            ("rest", .length(length(3))),
        ])
        let sides = try Sides<Optional<Length>>.fromValue(value).get()
        #expect(sides.left == length(1))
        #expect(sides.top == length(3))
        #expect(sides.right == length(2))
        #expect(sides.bottom == length(3))
    }

    @Test func sidesUniformAndEmpty() throws {
        // Uniform value → splat.
        let uniform = try Sides<Optional<Length>>.fromValue(
            .length(length(5))).get()
        #expect(uniform.left == length(5))
        #expect(uniform.top == length(5))
        #expect(uniform.right == length(5))
        #expect(uniform.bottom == length(5))

        // Empty dict → all unspecified.
        let empty = try Sides<Optional<Length>>.fromValue(.dict(Dict())).get()
        #expect(empty.left == nil)
        #expect(empty.top == nil)
    }

    @Test func sidesAxisOverridesRest() throws {
        // `y` overrides `rest` for top/bottom; `x` overrides for left/right.
        let value = dict([
            ("y", .length(length(7))),
            ("rest", .length(length(3))),
        ])
        let sides = try Sides<Optional<Length>>.fromValue(value).get()
        #expect(sides.top == length(7))
        #expect(sides.bottom == length(7))
        #expect(sides.left == length(3))
        #expect(sides.right == length(3))
    }

    // MARK: - Corners<Option<T>> casts

    @Test func cornersFallbackChain() throws {
        // `{top-left: 1pt, top: 4pt, rest: 2pt}` →
        // topLeft=1, topRight=4 (top), bottomRight=2 (rest via bottom),
        // bottomLeft=2.
        let value = dict([
            ("top-left", .length(length(1))),
            ("top", .length(length(4))),
            ("rest", .length(length(2))),
        ])
        let corners = try Corners<Optional<Length>>.fromValue(value).get()
        #expect(corners.topLeft == length(1))
        #expect(corners.topRight == length(4))
        #expect(corners.bottomRight == length(2))
        #expect(corners.bottomLeft == length(2))
    }

    // MARK: - DashLength / DashPattern casts

    @Test func dashLengthDotAndLength() throws {
        #expect(try DashLength<Length>.fromValue(.str(Str("dot"))).get()
                == .lineWidth)
        let len = try DashLength<Length>.fromValue(.length(length(3))).get()
        #expect(len == .length(length(3)))
    }

    @Test func dashPatternPresetAndArray() throws {
        let dotted = try DashPattern<Length, DashLength<Length>>
            .fromValue(.str(Str("dotted"))).get()
        #expect(dotted.phase == .zero)
        #expect(dotted.array.count == 2)

        let arr = Value.array(ArrayValue(items: [
            .str(Str("dot")), .length(length(4)),
        ]))
        let pattern = try DashPattern<Length, DashLength<Length>>
            .fromValue(arr).get()
        #expect(pattern.array == [.lineWidth, .length(length(4))])
        #expect(pattern.phase == .zero)
    }

    @Test func dashPatternDictForm() throws {
        let value = dict([
            ("array", .array(ArrayValue(items: [.length(length(3))]))),
            ("phase", .length(length(1))),
        ])
        let pattern = try DashPattern<Length, DashLength<Length>>
            .fromValue(value).get()
        #expect(pattern.array == [.length(length(3))])
        #expect(pattern.phase == length(1))
    }

    // MARK: - Stroke casts

    @Test func strokeLengthShorthand() throws {
        let stroke = try Stroke<Length>.fromValue(.length(length(2))).get()
        #expect(stroke.thickness == .custom(length(2)))
        #expect(stroke.paint == .auto)
        #expect(stroke.dash == .auto)
    }

    @Test func strokeDictForm() throws {
        let value = dict([
            ("thickness", .length(length(1.5))),
            ("dash", .str(Str("dashed"))),
            ("cap", .str(Str("round"))),
        ])
        let stroke = try Stroke<Length>.fromValue(value).get()
        #expect(stroke.thickness == .custom(length(1.5)))
        if case .custom(let dash) = stroke.dash,
           case .some(let pattern) = dash {
            #expect(pattern.array.count == 2)
        } else {
            Issue.record("expected custom dash pattern")
        }
        #expect(stroke.cap == .custom(.round))
    }

    @Test func strokeRejectsInvalid() {
        guard case .failure = Stroke<Length>.fromValue(.int(3)) else {
            Issue.record("expected stroke cast to fail")
            return
        }
    }

    // MARK: - Fold conformances

    @Test func optionalFoldRespectsInnerNil() {
        // (nil, some) → nil; (some, some) folds; (some, nil) → some.
        let innerNil: Length? = nil
        let outer = length(2)
        #expect(Optional<Length>.fold(innerNil, outer) == nil)
        #expect(Optional<Length>.fold(outer, innerNil) == outer)
        // Length isn't Fold, so use Smart<Bool>… Bool: Fold exists.
        #expect(Optional<Bool>.fold(true, false) == true)
        #expect(Optional<Bool>.fold(nil, true) == nil)
    }

    @Test func smartFoldRespectsInnerAuto() {
        #expect(Smart<Bool>.fold(.auto, .custom(true)) == .auto)
        #expect(Smart<Bool>.fold(.custom(true), .custom(false)) == .custom(true))
        #expect(Smart<Bool>.fold(.custom(true), .auto) == .custom(true))
    }

    @Test func alternativeFoldPicksSpecified() {
        // foldOr: nil = "unspecified" → other side wins.
        #expect(Optional<Bool>.foldOr(nil, .some(true)) == .some(true))
        #expect(Optional<Bool>.foldOr(.some(true), nil) == .some(true))
        #expect(Optional<Bool>.foldOr(.some(true), .some(false)) == .some(true))
        #expect(Optional<Bool>.foldOr(nil, nil) == nil)
    }

    @Test func arrayAndSpannedFold() {
        // Vec fold: outer items first, then inner.
        #expect(Array<Int>.fold([3], [1, 2]) == [1, 2, 3])

        // Spanned fold: inner span wins unless detached.
        let inner = Spanned<Length, Span>(Length.zero, span: .detached)
        let outer = Spanned<Length, Span>(Length.zero, span: .detached)
        let folded = Spanned<Length, Span>.fold(inner, outer)
        #expect(folded.span == .detached)
    }
}
