import Foundation
import Testing
import TypstSyntax
@testable import TypstLibrary

/// Tests for the container/transform/repeat element constructors ported
/// from `typst-library/src/layout/{container,transform,repeat}.rs`.
@Suite("ContainerElements")
struct ContainerElementTests {
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

    private func pt(_ rel: Rel<Length>?) -> Double {
        rel?.abs.abs.toPt() ?? -1
    }

    // MARK: - box

    @Test func boxDefaultsAndFields() throws {
        let plain = try markup("#box[x]")
        let box = try #require(firstElem(plain)?.element as? BoxElem)
        #expect(box.width == .auto)
        #expect(box.height == .auto)
        #expect(box.clip == false)
        #expect(box.body != nil)

        let styled = try markup("#box(width: 50%, height: 20pt, clip: true)[x]")
        let box2 = try #require(firstElem(styled)?.element as? BoxElem)
        guard case .rel(let rel) = box2.width else {
            Issue.record("expected rel width"); return
        }
        #expect(rel.rel.get == 0.5)
        #expect(box2.height == .custom(.init(rel: .zero, abs: lengthPt(20))))
        #expect(box2.clip == true)
    }

    @Test func boxInsetDictCast() throws {
        // `x` feeds left/right only; `y` feeds top/bottom; unspecified → nil.
        let content = try markup("#box(inset: (left: 1pt, x: 2pt, y: 3pt))[x]")
        let box = try #require(firstElem(content)?.element as? BoxElem)
        #expect(pt(box.inset.left) == 1)
        #expect(pt(box.inset.right) == 2)
        #expect(pt(box.inset.top) == 3)
        #expect(pt(box.inset.bottom) == 3)

        // Scalar splats to all sides.
        let uniform = try markup("#box(inset: 4pt)[x]")
        let box2 = try #require(firstElem(uniform)?.element as? BoxElem)
        #expect(pt(box2.inset.left) == 4)
        #expect(pt(box2.inset.top) == 4)
    }

    @Test func boxBaselineForms() throws {
        // Relative length → shift.
        let shifted = try markup("#box(baseline: 40%)[x]")
        let box = try #require(firstElem(shifted)?.element as? BoxElem)
        #expect(box.baseline.at == nil)
        #expect(box.baseline.shift?.rel.get == 0.4)

        // Dict form → at + shift.
        let dicted = try markup("#box(baseline: (at: bottom, shift: 2pt))[x]")
        let box2 = try #require(firstElem(dicted)?.element as? BoxElem)
        #expect(box2.baseline.at == .custom(.bottom))
        #expect(pt(box2.baseline.shift) == 2)
    }

    @Test func boxStrokeUniform() throws {
        // Uniform stroke value splats to all sides.
        let content = try markup("#box(stroke: 2pt)[x]")
        let box = try #require(firstElem(content)?.element as? BoxElem)
        let left = try #require(box.stroke.left)
        let stroke = try #require(left)
        #expect(stroke.thickness == .custom(lengthPt(2)))
    }

    // MARK: - block

    @Test func blockSpacingFallback() throws {
        // `spacing` feeds both above/below unless individually set.
        let content = try markup("#block(spacing: 2em)[x]")
        let block = try #require(firstElem(content)?.element as? BlockElem)
        #expect(block.above == .custom(.rel(spacingRel(em: 2))))
        #expect(block.below == .custom(.rel(spacingRel(em: 2))))

        // `above` overrides `spacing` for the top only.
        let mixed = try markup("#block(spacing: 2em, above: 1em)[x]")
        let block2 = try #require(firstElem(mixed)?.element as? BlockElem)
        #expect(block2.above == .custom(.rel(spacingRel(em: 1))))
        #expect(block2.below == .custom(.rel(spacingRel(em: 2))))
    }

    @Test func blockDefaults() throws {
        let content = try markup("#block[x]")
        let block = try #require(firstElem(content)?.element as? BlockElem)
        #expect(block.width == .auto)
        #expect(block.height == .auto)
        #expect(block.breakable == true)
        #expect(block.clip == false)
        #expect(block.sticky == false)
        #expect(block.above == .auto)
        #expect(block.below == .auto)
        guard case .content = block.body else {
            Issue.record("expected content body"); return
        }
    }

    @Test func blockSizingForms() throws {
        let auto = try markup("#block(height: auto)[x]")
        let b1 = try #require(firstElem(auto)?.element as? BlockElem)
        #expect(b1.height == .auto)

        let rel = try markup("#block(height: 50%)[x]")
        let b2 = try #require(firstElem(rel)?.element as? BlockElem)
        guard case .rel(let r) = b2.height else {
            Issue.record("expected rel height"); return
        }
        #expect(r.rel.get == 0.5)

        let fr = try markup("#block(height: 1fr)[x]")
        let b3 = try #require(firstElem(fr)?.element as? BlockElem)
        guard case .fr = b3.height else {
            Issue.record("expected fr height"); return
        }
    }

    // MARK: - transforms

    @Test func moveConstruct() throws {
        let content = try markup("#move(dx: 1em, dy: 2pt)[x]")
        let move = try #require(firstElem(content)?.element as? MoveElem)
        #expect(move.dx.abs.em.get == 1)
        #expect(move.dy.abs.abs.toPt() == 2)
    }

    @Test func rotateConstruct() throws {
        let content = try markup("#rotate(90deg)[x]")
        let rotate = try #require(firstElem(content)?.element as? RotateElem)
        #expect(rotate.angle.toDeg() == 90)
        #expect(rotate.origin == .both(.center, .horizon))
        #expect(rotate.reflow == false)

        let reflow = try markup("#rotate(45deg, reflow: true, origin: left)[x]")
        let r2 = try #require(firstElem(reflow)?.element as? RotateElem)
        #expect(r2.reflow == true)
        #expect(r2.origin == .h(.left))
    }

    @Test func scaleFactorFeedsBothAxes() throws {
        // External `factor` positional → x and y.
        let content = try markup("#scale(50%)[x]")
        let scale = try #require(firstElem(content)?.element as? ScaleElem)
        #expect(scale.x == .custom(.ratio(Ratio(0.5))))
        #expect(scale.y == .custom(.ratio(Ratio(0.5))))

        // Named axes override the shared factor.
        let named = try markup("#scale(x: 200%, y: 50%)[x]")
        let s2 = try #require(firstElem(named)?.element as? ScaleElem)
        #expect(s2.x == .custom(.ratio(Ratio(2.0))))
        #expect(s2.y == .custom(.ratio(Ratio(0.5))))
    }

    @Test func scaleLengthAmount() throws {
        // Length scale amount casts to `.length`.
        let content = try markup("#scale(x: 10pt)[x]")
        let scale = try #require(firstElem(content)?.element as? ScaleElem)
        guard case .custom(.length(let l)) = scale.x else {
            Issue.record("expected length scale amount"); return
        }
        #expect(l.abs.toPt() == 10)
    }

    @Test func skewConstruct() throws {
        let content = try markup("#skew(ax: 30deg, ay: -10deg)[x]")
        let skew = try #require(firstElem(content)?.element as? SkewElem)
        #expect(abs(skew.ax.toDeg() - 30) < 0.001)
        #expect(abs(skew.ay.toDeg() + 10) < 0.001)
        #expect(skew.origin == .both(.center, .horizon))
    }

    // MARK: - repeat

    @Test func repeatConstruct() throws {
        let content = try markup("#repeat(gap: 4pt, justify: false)[x]")
        let repeatElem = try #require(firstElem(content)?.element as? RepeatElem)
        #expect(repeatElem.gap.abs.toPt() == 4)
        #expect(repeatElem.justify == false)
        #expect(RepeatElem.info.capabilities.contains(.tagged))

        let plain = try markup("#repeat[x]")
        let r2 = try #require(firstElem(plain)?.element as? RepeatElem)
        #expect(r2.gap == .zero)
        #expect(r2.justify == true)
    }

    // MARK: - helpers

    private func lengthPt(_ pt: Double) -> Length {
        Length(abs: .pt(pt), em: .zero)
    }

    private func spacingRel(em: Double) -> Rel<Length> {
        Rel(rel: .zero, abs: Length(abs: .zero, em: Em(em)))
    }
}
