import Testing
import TypstUtils
@testable import TypstLibrary

/// Tests for the layout output primitives ported in Phase 3:
/// `Regions`, `Rect`, `Curve`/`Shape`/`Geometry`, `Stroke`/`FixedStroke`,
/// and the `TextSize` resolve chain.
@Suite struct LayoutPrimitiveTests {

    // MARK: - Regions

    @Test func regionsAdvanceThroughBacklog() {
        var regions = Regions.repeat(
            size: Size(x: .pt(100), y: .pt(50)),
            expand: Axes(x: false, y: false)
        )
        regions.backlog = [.pt(30), .pt(20), .pt(10)][...]
        regions.last = .pt(5)

        #expect(regions.size.y == .pt(50))
        regions.next()
        #expect(regions.size.y == .pt(30))
        #expect(regions.full == .pt(30))
        regions.next()
        #expect(regions.size.y == .pt(20))
        regions.next()
        #expect(regions.size.y == .pt(10))
        // Backlog drained: `last` repeats indefinitely.
        regions.next()
        #expect(regions.size.y == .pt(5))
        regions.next()
        #expect(regions.size.y == .pt(5))
        // size.y == last → next() changes nothing, so no progress is
        // possible (upstream `may_progress` semantics), though a break is
        // still permitted.
        #expect(!regions.mayProgress())
        #expect(regions.mayBreak())
    }

    @Test func regionsSingleRegionCannotProgress() {
        let regions = Regions(region: Region(
            size: Size(x: .pt(100), y: .pt(50)),
            expand: Axes(x: false, y: false)
        ))
        #expect(!regions.mayBreak())
        #expect(!regions.mayProgress())
        #expect(!regions.isFull())
    }

    @Test func regionsIsFull() {
        var regions = Regions(region: Region(
            size: Size(x: .pt(100), y: .pt(0)),
            expand: Axes(x: false, y: false)
        ))
        regions.last = .pt(50)
        // size.y == 0 fits and a next region differs → full.
        #expect(regions.isFull())
    }

    // MARK: - Curve

    @Test func curveRectBBox() {
        let curve = Curve.rect(Size(x: .pt(100), y: .pt(50)))
        let bbox = curve.bbox(stroke: nil)
        #expect(bbox.min == Point(x: .zero, y: .zero))
        #expect(bbox.max == Point(x: .pt(100), y: .pt(50)))
    }

    @Test func curveEllipseBBox() {
        let curve = Curve.ellipse(Size(x: .pt(100), y: .pt(50)))
        let bbox = curve.bbox(stroke: nil)
        // The four cubic extrema reach the ellipse's extremes.
        #expect(abs(bbox.min.x.toPt()) < 0.01)
        #expect(abs(bbox.min.y.toPt()) < 0.01)
        #expect(abs(bbox.max.x.toPt() - 100) < 0.01)
        #expect(abs(bbox.max.y.toPt() - 50) < 0.01)
    }

    @Test func curveContainsPoint() {
        let curve = Curve.rect(Size(x: .pt(100), y: .pt(50)))
        #expect(curve.contains(.nonZero, needle: Point(x: .pt(50), y: .pt(25))))
        #expect(!curve.contains(.nonZero, needle: Point(x: .pt(150), y: .pt(25))))
        #expect(curve.contains(.evenOdd, needle: Point(x: .pt(50), y: .pt(25))))
        #expect(!curve.contains(.evenOdd, needle: Point(x: .pt(150), y: .pt(25))))
    }

    @Test func curveTranslate() {
        var curve = Curve.rect(Size(x: .pt(10), y: .pt(10)))
        curve.translate(Point(x: .pt(5), y: .pt(7)))
        let bbox = curve.bbox(stroke: nil)
        #expect(bbox.min == Point(x: .pt(5), y: .pt(7)))
        #expect(bbox.max == Point(x: .pt(15), y: .pt(17)))
    }

    // MARK: - Shape / Geometry

    @Test func geometryLineBBoxUnstroked() {
        let shape = Geometry.line(Point(x: .pt(-10), y: .pt(20))).filled(.solid(.red))
        let bbox = shape.bbox(includeStroke: false)
        #expect(bbox.min == Point(x: .pt(-10), y: .zero))
        #expect(bbox.max == Point(x: .zero, y: .pt(20)))
    }

    @Test func strokedLineBBoxButtVsSquare() {
        var stroke = FixedStroke()
        stroke.thickness = .pt(10)
        stroke.cap = .butt
        let butt = Geometry.line(Point(x: .pt(100), y: .zero))
            .stroked(stroke).bbox(includeStroke: true)
        #expect(butt.min == Point(x: .zero, y: .pt(-5)))
        #expect(butt.max == Point(x: .pt(100), y: .pt(5)))

        stroke.cap = .square
        let square = Geometry.line(Point(x: .pt(100), y: .zero))
            .stroked(stroke).bbox(includeStroke: true)
        #expect(square.min == Point(x: .pt(-5), y: .pt(-5)))
        #expect(square.max == Point(x: .pt(105), y: .pt(5)))
    }

    @Test func rectBBoxAccountsForStroke() {
        var stroke = FixedStroke()
        stroke.thickness = .pt(4)
        let shape = Geometry.rect(Size(x: .pt(100), y: .pt(50)))
            .filledAndStroked(.solid(.blue), stroke)
        let bbox = shape.bbox(includeStroke: true)
        #expect(bbox.min == Point(x: .pt(-2), y: .pt(-2)))
        #expect(bbox.max == Point(x: .pt(102), y: .pt(52)))
    }

    // MARK: - Stroke

    @Test func fixedStrokeDefaults() {
        let stroke = FixedStroke()
        #expect(stroke.thickness == .pt(1))
        #expect(stroke.cap == .butt)
        #expect(stroke.join == .miter)
        #expect(stroke.dash == nil)
        #expect(stroke.miterLimit == Ratio(4))
    }

    @Test func strokeResolveAndUnwrap() {
        // 2pt absolute thickness + em component resolved against 11pt default.
        let stroke = Stroke<Length>(
            thickness: .custom(Length(abs: .pt(2), em: Em(0.5)))
        )
        let resolved = stroke.resolve(StyleChain())
        let fixed = resolved.unwrapOrDefault()
        #expect(fixed.thickness == .pt(2) + .pt(5.5))
        #expect(fixed.paint == .solid(.black))
    }

    @Test func strokeDashResolvesAndFinishes() throws {
        let stroke = Stroke<Length>(
            thickness: .custom(Length(abs: .pt(4), em: .zero)),
            dash: .custom(DashPattern.preset("dotted"))
        )
        let fixed = stroke.resolve(StyleChain()).unwrapOrDefault()
        let dash = try #require(fixed.dash)
        // "dotted" = {("dot", 2pt)} — lineWidth finishes to the 4pt thickness.
        #expect(dash.array.count == 2)
        #expect(dash.array[0] == .pt(4))
        #expect(dash.array[1] == .pt(2))
    }

    @Test func strokeOrPrefersInner() {
        let inner = Stroke<Length>(thickness: .custom(Length(abs: .pt(2), em: .zero)))
        let outer = Stroke<Length>(thickness: .custom(Length(abs: .pt(9), em: .zero)),
                                   cap: .custom(.round))
        let joined = inner.or(outer)
        #expect(joined.thickness.custom() == Length(abs: .pt(2), em: .zero))
        #expect(joined.cap.custom() == .round)
    }

    // MARK: - TextSize

    @Test func textSizeDefaultsTo11pt() {
        #expect(StyleChain().textSize() == .pt(11))
    }

    @Test func textSizeFoldsAcrossSetRules() {
        func sizeProp(_ length: Length) -> LazyHash<Style> {
            LazyHash(Style.property(Property(
                elem: Element(TextElem.self),
                field: TextElem.sizeFieldID,
                value: .length(length)
            )))
        }
        // Outer `#set text(size: 10pt)`, inner `#set text(size: 2em)`
        // → folded size is 2em * 10pt = 20pt (upstream TextSize::fold).
        let outer = StyleChain(head: [sizeProp(Length(abs: .pt(10), em: .zero))][...])
        let inner = StyleChain(head: [sizeProp(Length(abs: .zero, em: Em(2)))][...],
                               tail: outer)
        #expect(inner.textSize() == .pt(20))
    }

    @Test func emResolvesAgainstTextSize() {
        func sizeProp(_ length: Length) -> LazyHash<Style> {
            LazyHash(Style.property(Property(
                elem: Element(TextElem.self),
                field: TextElem.sizeFieldID,
                value: .length(length)
            )))
        }
        let chain = StyleChain(head: [sizeProp(Length(abs: .pt(10), em: .zero))][...])
        #expect(Em(2).resolve(chain) == .pt(20))
        #expect(Length(abs: .pt(1), em: Em(1)).resolve(chain) == .pt(11))
    }
}
