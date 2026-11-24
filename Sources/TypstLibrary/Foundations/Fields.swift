import Foundation
import TypstSyntax
import TypstUtils

/// Port of `fields.rs` — field access on values with predefined fields
/// (length, relative, stroke, alignment). Special cases (symbol, version,
/// dict, args, content, type, func, module) are handled by `Value.field`
/// before this fallback runs.
func fields_field(_ value: Value, _ field: String) -> HintedStrResult<Value> {
    if field == "func" {
        if let funcValue = tryExtractFunc(value) {
            return .success(.function(funcValue))
        }
    }

    let ty = value.type
    func noFields() -> HintedStrResult<Value> {
        .failure(HintedString("cannot access fields on type \(ty)"))
    }
    func missing() -> HintedStrResult<Value> {
        .failure(HintedString("\(ty) does not contain field \"\(field)\""))
    }

    switch value {
    case let .length(length):
        switch field {
        case "em": return .success(.float(length.em.get))
        case "abs": return .success(.length(Length(length.abs)))
        default: return missing()
        }
    case let .relative(rel):
        switch field {
        case "ratio": return .success(.ratio(rel.rel))
        case "length": return .success(.length(rel.abs))
        default: return missing()
        }
    case let .dynamic(dynamic):
        if let stroke = dynamic.downcast(Stroke.self) {
            switch field {
            case "paint": return .success(stroke.paint.intoValue())
            case "thickness": return .success(stroke.thickness.intoValue())
            case "cap": return .success(stroke.cap.intoValue())
            case "join": return .success(stroke.join.intoValue())
            case "dash": return .success(dashFieldValue(stroke.dash))
            case "miter-limit":
                return .success(stroke.miterLimit.map { $0.get }.intoValue())
            default: return missing()
            }
        } else if let align = dynamic.downcast(Alignment.self) {
            switch field {
            case "x": return .success(align.horizontal.intoValue())
            case "y": return .success(align.vertical.intoValue())
            default: return missing()
            }
        }
        return noFields()
    default:
        return noFields()
    }
}

/// List the available fields for a type (upstream `fields_on`).
func fieldsOn(_ ty: Type) -> [String] {
    if ty == Type.of(Version.self) {
        return Version.componentNames
    } else if ty == Type.of(Length.self) {
        return ["em", "abs"]
    } else if ty == Type.of(Rel<Length>.self) {
        return ["ratio", "length"]
    } else if ty == Type.of(Stroke.self) {
        return ["paint", "thickness", "cap", "join", "dash", "miter-limit"]
    } else if ty == Type.of(Alignment.self) {
        return ["x", "y"]
    }
    return []
}

/// `stroke.dash` field value — `Smart<Option<DashPattern>>` rendered
/// without requiring the full `DashPattern` cast (which lands with the
/// stroke port).
private func dashFieldValue(_ dash: Smart<DashPattern<Length>?>) -> Value {
    switch dash {
    case .auto: return .auto
    case let .custom(pattern):
        guard let pattern else { return .none }
        return .dict(Dict([
            ("array", .array(ArrayValue(pattern.array.map { $0.intoValue() }))),
            ("phase", pattern.phase.intoValue()),
        ]))
    }
}

/// Extract the callable function from a value that supports `.func`.
func tryExtractFunc(_ value: Value) -> Func? {
    switch value {
    case let .function(f): return f
    case let .content(c): return c.`func`
    default: return nil
    }
}
