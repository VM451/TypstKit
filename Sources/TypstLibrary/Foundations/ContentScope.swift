import Foundation
import TypstSyntax
import TypstUtils

// The `content` type's associated scope — port of the `#[scope] impl
// Content` block in upstream `foundations/content/mod.rs`.

/// `content.func()` — port of `Content::func`: the element function.
let contentFunc = nativeFunc(
    "func",
    since: .forever,
    docs: """
        The content's element function. This function can be used to \
        create the element contained in this content.
        """,
    params: [
        NativeParamInfo(name: "self", input: Content.input, required: true),
    ],
    returns: Func.output
) { _, _, args in
    let selfValue: Content = try args.expectT("self")
    try args.finishT()
    return selfValue.elem.function
}

/// `content.has(field)` — port of `Content::has`.
let contentHas = nativeFunc(
    "has",
    since: .forever,
    docs: "Whether the content has the specified field.",
    params: [
        NativeParamInfo(name: "self", input: Content.input, required: true),
        NativeParamInfo(name: "field", input: Str.input, required: true),
    ],
    returns: Bool.output
) { _, _, args in
    let selfValue: Content = try args.expectT("self")
    let field: Str = try args.expectT("field")
    try args.finishT()

    if field.value == "label" {
        return selfValue.label != nil
    }
    guard let id = selfValue.elem.fieldID(field.value) else {
        return false
    }
    return selfValue.packed.element.field(id) != nil
}

/// `content.at(field, default:)` — port of `Content::at`.
let contentAt = nativeFunc(
    "at",
    since: .forever,
    docs: """
        Access the specified field on the content. Returns the default \
        value if the field does not exist or fails with an error if no \
        default value was specified.
        """,
    params: [
        NativeParamInfo(name: "self", input: Content.input, required: true),
        NativeParamInfo(name: "field", input: Str.input, required: true),
        NativeParamInfo(
            name: "default",
            input: Value.input,
            defaultValue: { .none },
            positional: false,
            named: true),
    ],
    returns: Value.output
) { _, _, args in
    let selfValue: Content = try args.expectT("self")
    let field: Str = try args.expectT("field")
    let fallback: Value? = try args.namedT("default")
    try args.finishT()

    switch selfValue.getByName(field.value) {
    case .success(let value):
        return value
    case .failure(let error):
        if let fallback { return fallback }
        throw bailSpan(.detached, error.messageNoDefault(selfValue, field.value).message)
    }
}

/// `content.fields()` — port of `Content::fields`, including the label
/// entry upstream appends.
let contentFields = nativeFunc(
    "fields",
    since: .version([0, 5, 0]),
    docs: "Returns the fields of this content.",
    params: [
        NativeParamInfo(name: "self", input: Content.input, required: true),
    ],
    returns: Dict.output
) { _, _, args in
    let selfValue: Content = try args.expectT("self")
    try args.finishT()
    var dict = selfValue.fields()
    if let label = selfValue.label {
        dict.insert("label", .label(label))
    }
    return dict
}

/// `content.location()` — port of `Content::location`.
let contentLocation = nativeFunc(
    "location",
    since: .forever,
    docs: """
        The location of the content. This is only available on content \
        returned by query or provided by a show rule; for other content \
        it will be `{none}`.
        """,
    params: [
        NativeParamInfo(name: "self", input: Content.input, required: true),
    ],
    returns: Location.output
) { _, _, args in
    let selfValue: Content = try args.expectT("self")
    try args.finishT()
    guard let location = selfValue.location else { return Value.none }
    return location.intoValue()
}

/// Build the scope containing all `content` methods.
func contentScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(contentFunc)
    scope.defineFunc(contentHas)
    scope.defineFunc(contentAt)
    scope.defineFunc(contentFields)
    scope.defineFunc(contentLocation)
    return scope
}
