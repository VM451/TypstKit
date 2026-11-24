import Foundation
import TypstSyntax

/// Port of `fields.rs` — fallback field access producing the
/// "type has no field" error message.
func fields_field(_ value: Value, _ field: String) -> HintedStrResult<Value> {
    if field == "func" {
        if let funcValue = tryExtractFunc(value) {
            return .success(.function(funcValue))
        }
    }
    return .failure(HintedString("type \(value.type.longName) has no field \(field.typstRepr)"))
}

/// Extract the callable function from a value that supports `.func`.
func tryExtractFunc(_ value: Value) -> Func? {
    switch value {
    case let .function(f): return f
    case let .content(c): return c.`func`
    default: return nil
    }
}
