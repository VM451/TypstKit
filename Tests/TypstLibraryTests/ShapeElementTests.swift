import Foundation
import Testing
import TypstSyntax
@testable import TypstLibrary

/// Tests for the shape element definitions ported from
/// `typst-library/src/visualize/{shape,line,polygon}.rs`.
@Suite("ShapeElements")
struct ShapeElementTests {
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

    private func pt(_ length: Length) -> Double { length.abs.toPt() }

    // MARK: - rect

    @Test func rectDefaults() throws {
        let content = try markup("#rect[x]")
        let rect = try #require(firstElem(content)?.element as? RectElem)
        #expect(rect.width.isAuto)
        #expect(rect.height.isAuto)
        #expect(rect.stroke.isAuto)
        // Default inset: 5pt on all sides.
        for side in [rect.inset.left, rect.inset.top, rect.inset.right, rect.inset.bottom] {
            #expect(side.map { pt($0.abs) } == 5)
        }
    }

    @Test func rectFields() throws {
        let content = try markup("#rect(width: 50%, height: 20pt)[x]")
        let rect = try #require(firstElem(content)?.element as? RectElem)
        guard case .custom(let width) = rect.width else {
            Issue.record("expected custom width"); return
        }
        #expect(width.rel.get == 0.5)
        guard case .rel(let rel) = rect.height else {
            Issue.record("expected rel height"); return
        }
        #expect(pt(rel.abs) == 20)
        #expect(rect.fill == nil)
    }

    @Test func rectSidesStroke() throws {
        let content = try markup("#rect(stroke: (left: 1pt, rest: 2pt))[x]")
        let rect = try #require(firstElem(content)?.element as? RectElem)
        guard case .custom(let sides) = rect.stroke else {
            Issue.record("expected custom sides stroke"); return
        }
        for side in [sides.left, sides.right, sides.top, sides.bottom] {
            guard case .some(.some) = side else {
                Issue.record("expected inner stroke on all sides"); return
            }
        }
    }

    // MARK: - square / circle

    @Test func squareSize() throws {
        let content = try markup("#square(size: 20pt)")
        let square = try #require(firstElem(content)?.element as? SquareElem)
        guard case .custom(let width) = square.width else {
            Issue.record("expected custom width"); return
        }
        #expect(pt(width.abs) == 20)
        guard case .rel(let rel) = square.height else {
            Issue.record("expected rel height"); return
        }
        #expect(pt(rel.abs) == 20)
    }

    @Test func squareWidthHeight() throws {
        let content = try markup("#square(width: 10pt, height: 30%)")
        let square = try #require(firstElem(content)?.element as? SquareElem)
        guard case .custom(let width) = square.width else {
            Issue.record("expected custom width"); return
        }
        #expect(pt(width.abs) == 10)
        guard case .rel(let rel) = square.height else {
            Issue.record("expected rel height"); return
        }
        #expect(rel.rel.get == 0.3)
    }

    @Test func circleRadius() throws {
        let content = try markup("#circle(radius: 10pt)")
        let circle = try #require(firstElem(content)?.element as? CircleElem)
        guard case .custom(let width) = circle.width else {
            Issue.record("expected custom width"); return
        }
        // radius → diameter.
        #expect(pt(width.abs) == 20)
        guard case .rel(let rel) = circle.height else {
            Issue.record("expected rel height"); return
        }
        #expect(pt(rel.abs) == 20)
    }

    // MARK: - ellipse

    @Test func ellipseFields() throws {
        let content = try markup("#ellipse(width: 40pt, height: 20pt)[x]")
        let ellipse = try #require(firstElem(content)?.element as? EllipseElem)
        guard case .custom(let width) = ellipse.width else {
            Issue.record("expected custom width"); return
        }
        #expect(pt(width.abs) == 40)
        guard case .rel(let rel) = ellipse.height else {
            Issue.record("expected rel height"); return
        }
        #expect(pt(rel.abs) == 20)
    }

    // MARK: - line

    @Test func lineDefaults() throws {
        let content = try markup("#line()")
        let line = try #require(firstElem(content)?.element as? LineElem)
        #expect(line.end == nil)
        #expect(pt(line.length.abs) == 30)
        #expect(line.angle == .zero)
    }

    @Test func lineEndpoints() throws {
        let content = try markup("#line(start: (0pt, 0pt), end: (10pt, 20pt), angle: 45deg)")
        let line = try #require(firstElem(content)?.element as? LineElem)
        #expect(pt(line.start.x.abs) == 0)
        #expect(pt(line.start.y.abs) == 0)
        let end = try #require(line.end)
        #expect(pt(end.x.abs) == 10)
        #expect(pt(end.y.abs) == 20)
        #expect(abs(line.angle.toDeg() - 45) < 0.001)
    }

    // MARK: - polygon

    @Test func polygonVertices() throws {
        let content = try markup("#polygon((0pt, 0pt), (10pt, 0pt), (5pt, 10pt))")
        let polygon = try #require(firstElem(content)?.element as? PolygonElem)
        #expect(polygon.vertices.count == 3)
        #expect(pt(polygon.vertices[0].x.abs) == 0)
        #expect(pt(polygon.vertices[1].x.abs) == 10)
        #expect(pt(polygon.vertices[2].y.abs) == 10)
        #expect(polygon.fillRule == .nonZero)
    }

    @Test func polygonFillRule() throws {
        let content = try markup("#polygon(fill-rule: \"even-odd\", (0pt, 0pt), (1pt, 1pt))")
        let polygon = try #require(firstElem(content)?.element as? PolygonElem)
        #expect(polygon.fillRule == .evenOdd)
    }

    @Test func polygonRegular() throws {
        let content = try markup("#polygon.regular(vertices: 5, size: 20pt)")
        let polygon = try #require(firstElem(content)?.element as? PolygonElem)
        // Upstream emits `0..=vertices` points (vertices + 1, closed).
        #expect(polygon.vertices.count == 6)
        // First and last points coincide (the polygon is closed).
        let first = polygon.vertices[0]
        let last = polygon.vertices[polygon.vertices.count - 1]
        #expect(abs(pt(first.x.abs) - pt(last.x.abs)) < 0.001)
        #expect(abs(pt(first.y.abs) - pt(last.y.abs)) < 0.001)
        // All points fit in the size × size box.
        for v in polygon.vertices {
            #expect(pt(v.x.abs) >= -0.001 && pt(v.x.abs) <= 20.001)
            #expect(pt(v.y.abs) >= -0.001 && pt(v.y.abs) <= 20.001)
        }
    }
}

/// Tests for the curve element definitions ported from
/// `typst-library/src/visualize/curve.rs`.
@Suite("CurveElements")
struct CurveElementTests {
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

    private func pt(_ length: Length) -> Double { length.abs.toPt() }

    @Test func curveComponents() throws {
        let content = try markup(
            "#curve(curve.move((0pt, 0pt)), curve.line((10pt, 10pt)), curve.close())")
        let curve = try #require(firstElem(content)?.element as? CurveElem)
        #expect(curve.components.count == 3)
        guard case .move(let moveContent) = curve.components[0],
              case .line(let lineContent) = curve.components[1],
              case .close(let closeContent) = curve.components[2] else {
            Issue.record("unexpected component kinds"); return
        }
        let move = try #require(moveContent.packed.element as? CurveMove)
        #expect(pt(move.start.x.abs) == 0)
        #expect(move.relative == false)
        let line = try #require(lineContent.packed.element as? CurveLine)
        #expect(pt(line.end.x.abs) == 10)
        #expect(pt(line.end.y.abs) == 10)
        _ = closeContent
    }

    @Test func curveComponentArgs() throws {
        // Relative flag + quad/cubic optionals.
        let content = try markup(
            "#curve(curve.line((5pt, 5pt), relative: true), "
            + "curve.quad(auto, (3pt, 3pt)), "
            + "curve.cubic(none, (1pt, 1pt), (2pt, 2pt)), "
            + "curve.close(mode: \"straight\"))")
        let curve = try #require(firstElem(content)?.element as? CurveElem)
        #expect(curve.components.count == 4)
        guard case .line(let lineContent) = curve.components[0],
              case .quad(let quadContent) = curve.components[1],
              case .cubic(let cubicContent) = curve.components[2],
              case .close(let closeContent) = curve.components[3] else {
            Issue.record("unexpected component kinds"); return
        }
        let line = try #require(lineContent.packed.element as? CurveLine)
        #expect(line.relative == true)
        let quad = try #require(quadContent.packed.element as? CurveQuad)
        #expect(quad.control.isAuto)
        let cubic = try #require(cubicContent.packed.element as? CurveCubic)
        #expect(cubic.controlStart == nil)
        #expect(cubic.controlEnd != nil)
        let close = try #require(closeContent.packed.element as? CurveClose)
        #expect(close.mode == .straight)
    }

    @Test func curveRejectsNonComponent() throws {
        // Plain content is not a curve component — the variadic cast
        // rejects it eagerly, matching upstream `TryFrom<Content>`.
        #expect(throws: (any Error).self) {
            _ = try markup("#curve([x])")
        }
    }
}
