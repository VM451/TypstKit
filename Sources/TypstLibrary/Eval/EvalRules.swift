import Foundation
import TypstSyntax
import TypstUtils

// Port of `typst-eval/src/rules.rs` — set rules and show rules.
//
// The `show page` / `show par: set block` migration warnings are deferred:
// they require the layout elements (`PageElem`, `ParElem`, `BlockElem`)
// which land with the layout milestone.

extension TypstSyntax.SetRule {
    /// Evaluate the set rule into a style map.
    /// Port of `SetRule::eval`.
    public func eval(_ vm: inout Vm) throws -> Styles {
        if let condition = condition() {
            let cond = try condition.eval(&vm)
            guard try unwrap(Bool.fromValue(cond).at(condition.span)) else {
                return Styles()
            }
        }

        let targetExpr = target()
        let targetValue = try targetExpr.eval(&vm)
        let funcValue = try unwrap(Func.fromValue(targetValue)
            .mapError { hintIfShadowedStd(vm, targetExpr, $0) }
            .at(targetExpr.span))
        guard let element = funcValue.element else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                targetExpr.span,
                "only element functions can be used in set rules"))
        }

        var args = try self.args().eval(&vm).spanned(span)
        var styles = try element.set(engine: &vm.engine, args: &args)
        styles = styles.spanned(span).liftable()
        return styles
    }
}

extension TypstSyntax.ShowRule {
    /// Evaluate the show rule into a recipe.
    /// Port of `ShowRule::eval`.
    public func eval(_ vm: inout Vm) throws -> Recipe {
        var selector: Selector?
        if let sel = self.selector() {
            let selValue = try sel.eval(&vm)
            let showable = try unwrap(ShowableSelector.fromValue(selValue)
                .mapError { hintIfShadowedStd(vm, sel, $0) }
                .at(sel.span))
            selector = showable.selector
        }

        let transformExpr = transform()
        let transform: Transformation
        if case let .setRule(set) = transformExpr {
            transform = .style(try set.eval(&vm))
        } else {
            let value = try transformExpr.eval(&vm)
            transform = try unwrap(Transformation.fromValue(value)
                .at(transformExpr.span))
        }

        let recipe = Recipe(selector: selector, transform: transform,
                            span: span)
        // check_show_page_rule / check_show_par_set_block deferred —
        // they need layout elements (see file header).
        return recipe
    }
}
