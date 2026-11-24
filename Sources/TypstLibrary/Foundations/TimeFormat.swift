import Foundation

// A port of the `time` crate's runtime format-description parser
// (`format_description::parse_owned::<2>`) and formatter, restricted to
// what `datetime.display` needs: naive dates, times, and datetimes.
//
// Reference: `time-0.3.55/src/format_description/parse/{lexer_ast,
// format_item}.rs` and `time-0.3.55/src/formatting/{mod,formattable,
// component_provider}.rs`.
//
// Only version-2 syntax (`[component modifier:value]`, `\`-escapes) is
// supported, matching upstream's `parse_owned::<2>` call. The `large-dates`
// feature is disabled in upstream's dependency, so `range` modifiers are
// always rejected and year components always use the standard range.

// MARK: - Errors

/// Port of `time::error::InvalidFormatDescription` (parse-time errors).
enum TimeFormatParseError: Error, Sendable, Hashable {
    case unclosedOpeningBracket(index: Int)
    case invalidComponentName(name: String, index: Int)
    case invalidModifier(value: String, index: Int)
    case invalidModifierCombination(modifier: String, context: String, index: Int)
    case expected(what: String, index: Int)
    case missingComponentName(index: Int)
    case missingRequiredModifier(name: String, index: Int)
    case notSupported(what: String, context: String, index: Int)
}

/// Port of `time::error::Format` for the cases reachable with naive
/// date/time values (format-time errors).
enum TimeFormatFailure: Error, Sendable, Hashable {
    /// The value doesn't carry enough information for the component.
    case insufficientTypeInformation
    /// A component value is outside the range its modifiers allow.
    case componentRange(String)
}

extension TimeFormatParseError {
    /// The message produced by upstream `format_time_invalid_format_description_error`.
    var typstMessage: String {
        switch self {
        case let .unclosedOpeningBracket(index):
            return "missing closing bracket for bracket at index \(index)"
        case let .invalidComponentName(name, index):
            return "invalid component name '\(name)' at index \(index)"
        case let .invalidModifier(value, index):
            return "invalid modifier '\(value)' at index \(index)"
        case let .invalidModifierCombination(modifier, context, index):
            // Falls through to upstream's `err =>` arm: the public
            // Display of `InvalidFormatDescription::InvalidModifierCombination`.
            return "failed to parse datetime format (the `\(modifier)` modifier is not valid at byte index \(index) \(context))"
        case let .expected(what, index):
            return "expected \(what) at index \(index)"
        case let .missingComponentName(index):
            return "expected component name at index \(index)"
        case let .missingRequiredModifier(name, index):
            return "missing required modifier \(name) for component at index \(index)"
        case let .notSupported(what, context, index):
            return "\(what) is not supported in \(context) at index \(index)"
        }
    }
}

extension TimeFormatFailure {
    /// The message produced by upstream `format_time_format_error`.
    var typstMessage: String {
        switch self {
        case .insufficientTypeInformation:
            return "failed to format datetime (insufficient information)"
        case let .componentRange(name):
            return "failed to format datetime in the requested format (\(name) was not in range)"
        }
    }
}

// MARK: - Components

/// Numeric padding for formatted components (time crate `Padding`).
enum TimePadding: Sendable, Hashable {
    case space, zero, none
}

/// Subsecond digit count (time crate `SubsecondDigits`).
enum SubsecondDigits: Sendable, Hashable {
    case one, two, three, four, five, six, seven, eight, nine, oneOrMore

    var count: Int {
        switch self {
        case .one: return 1
        case .two: return 2
        case .three: return 3
        case .four: return 4
        case .five: return 5
        case .six: return 6
        case .seven: return 7
        case .eight: return 8
        case .nine: return 9
        case .oneOrMore: return -1
        }
    }
}

/// A resolved format component — the concrete `time::format_description::Component`
/// variants reachable from the v2 parser (the deprecated umbrella variants
/// `Month`/`Weekday`/`WeekNumber`/`Hour`/`Year`/`UnixTimestamp` are never
/// produced by parsing, and the extended-range year variants are
/// `cfg`'d out without the `large-dates` feature).
enum TimeComponent: Sendable, Hashable {
    case day(padding: TimePadding)
    case monthShort(caseSensitive: Bool)
    case monthLong(caseSensitive: Bool)
    case monthNumerical(padding: TimePadding)
    case ordinal(padding: TimePadding)
    case weekdayShort(caseSensitive: Bool)
    case weekdayLong(caseSensitive: Bool)
    case weekdaySunday(oneIndexed: Bool)
    case weekdayMonday(oneIndexed: Bool)
    case weekNumberIso(padding: TimePadding)
    case weekNumberSunday(padding: TimePadding)
    case weekNumberMonday(padding: TimePadding)
    case calendarYearFullStandard(padding: TimePadding, signMandatory: Bool)
    case calendarYearCenturyStandard(padding: TimePadding, signMandatory: Bool)
    case calendarYearLastTwo(padding: TimePadding)
    case isoYearFullStandard(padding: TimePadding, signMandatory: Bool)
    case isoYearCenturyStandard(padding: TimePadding, signMandatory: Bool)
    case isoYearLastTwo(padding: TimePadding)
    case hour12(padding: TimePadding)
    case hour24(padding: TimePadding)
    case minute(padding: TimePadding)
    case period(isUppercase: Bool, caseSensitive: Bool)
    case second(padding: TimePadding)
    case subsecond(digits: SubsecondDigits)
    case offsetHour(signMandatory: Bool, padding: TimePadding)
    case offsetMinute(padding: TimePadding)
    case offsetSecond(padding: TimePadding)
    case ignore
    case unixTimestampSecond(signMandatory: Bool)
    case unixTimestampMillisecond(signMandatory: Bool)
    case unixTimestampMicrosecond(signMandatory: Bool)
    case unixTimestampNanosecond(signMandatory: Bool)
    case end
}

/// A parsed format description — port of `OwnedFormatItem`.
indirect enum TimeFormatItem: Sendable, Hashable {
    case literal(String)
    case component(TimeComponent)
    case compound([TimeFormatItem])
    /// `format` mirrors the `format:` modifier; `false` is rejected for v2.
    case optional(Bool, TimeFormatItem)
    /// Alternative nested descriptions; only the first is formatted.
    case first([TimeFormatItem])
}

// MARK: - Lexer

/// A `key:value` modifier token inside a component header.
private struct ParsedModifier {
    /// Original key text (case preserved for error messages).
    let key: String
    /// ASCII-lowercased key for matching.
    let loweredKey: String
    let value: String
    /// Byte index where the key starts.
    let keyIndex: Int
    /// Byte index where the value starts.
    let valueIndex: Int
}

/// A nested format description `[...]` inside a component header.
private struct NestedDescription {
    var leadingWhitespace: Bool
    let openingBracket: Int
    var items: [TimeFormatItem]
    let closingBracket: Int
}

/// Byte-level lexer mirroring `time`'s `Lexer<2, true>`.
private struct FormatLexer {
    let bytes: [UInt8]
    var pos: Int = 0
    var depth: Int = 0

    init(_ string: String) {
        bytes = Array(string.utf8)
    }

    var isAtEnd: Bool { pos >= bytes.count }

    /// `depth` is a `u8` upstream; 255 nested levels is the cap.
    private mutating func enterDepth(at index: Int) throws {
        guard depth < 255 else {
            throw TimeFormatParseError.notSupported(
                what: "highly-nested format description", context: "", index: index)
        }
        depth += 1
    }

    /// Literal context when depth is even, component context when odd.
    private var inLiteralContext: Bool { depth % 2 == 0 }

    private mutating func advance(_ count: Int = 1) {
        pos += count
    }

    private func byte(_ offset: Int = 0) -> UInt8? {
        let i = pos + offset
        return i < bytes.count ? bytes[i] : nil
    }

    private static func isASCIISpace(_ b: UInt8) -> Bool {
        b == 0x20 || (0x09...0x0D).contains(b)
    }

    /// Consume a run of ASCII whitespace in component context.
    private mutating func consumeWhitespace() -> Bool {
        var consumed = false
        while let b = byte(), Self.isASCIISpace(b) {
            advance(); consumed = true
        }
        return consumed
    }

    /// Consume a run of non-whitespace, non-`\[]` bytes.
    /// Returns (string, startIndex).
    private mutating func consumeComponentPart() -> (String, Int)? {
        let start = pos
        while let b = byte(),
              !Self.isASCIISpace(b), b != UInt8(ascii: "\\"),
              b != UInt8(ascii: "["), b != UInt8(ascii: "]") {
            advance()
        }
        guard pos > start else { return nil }
        return (String(decoding: bytes[start..<pos], as: UTF8.self), start)
    }

    /// Consume `]` if present (component context only).
    private mutating func consumeClosingBracket() -> Int? {
        guard byte() == UInt8(ascii: "]") else { return nil }
        let index = pos
        depth -= 1
        advance()
        return index
    }

    /// The component name: optional leading whitespace, then a part.
    private mutating func consumeComponentName(
        openingBracket: Int
    ) throws -> (name: String, index: Int) {
        let hadLeadingWhitespace = consumeWhitespace()
        guard let (name, index) = consumeComponentPart() else {
            let errorIndex = hadLeadingWhitespace ? openingBracket + 1 : openingBracket
            throw TimeFormatParseError.missingComponentName(index: errorIndex)
        }
        return (name, index)
    }

    /// Parse `key:value` modifier tokens until none remain.
    private mutating func parseModifiers() throws -> (modifiers: [ParsedModifier], trailingWhitespace: Bool) {
        var modifiers: [ParsedModifier] = []
        while true {
            guard consumeWhitespace() else { return (modifiers, false) }
            guard let (token, tokenIndex) = consumeComponentPart() else {
                return (modifiers, true)
            }
            modifiers.append(try parseModifierToken(token, at: tokenIndex))
        }
    }

    private func parseModifierToken(_ token: String, at tokenIndex: Int) throws -> ParsedModifier {
        guard let colonRel = token.firstIndex(of: ":") else {
            throw TimeFormatParseError.invalidModifier(value: token, index: tokenIndex)
        }
        let key = String(token[..<colonRel])
        let value = String(token[token.index(after: colonRel)...])
        if key.isEmpty {
            throw TimeFormatParseError.invalidModifier(value: "", index: tokenIndex)
        }
        if value.isEmpty {
            // Index of the colon = token start + key length.
            throw TimeFormatParseError.invalidModifier(
                value: "", index: tokenIndex + key.utf8.count)
        }
        return ParsedModifier(
            key: key,
            loweredKey: key.lowercased(),
            value: value,
            keyIndex: tokenIndex,
            valueIndex: tokenIndex + key.utf8.count + 1)
    }

    /// Whether the upcoming non-whitespace byte starts a nested `[`.
    private func isNestedDescriptionStart() -> Bool {
        var i = pos
        while i < bytes.count, Self.isASCIISpace(bytes[i]) { i += 1 }
        return i < bytes.count && bytes[i] == UInt8(ascii: "[")
    }

    /// Parse a nested `[...]` description. Errors are swallowed by the
    /// caller (`while let Ok(...)` upstream), except depth overflow.
    private mutating func consumeNested(lastLocation: Int) throws -> NestedDescription {
        let leadingWhitespace = consumeWhitespace()
        try enterDepth(at: lastLocation)
        let openingBracket = pos
        advance()  // consume `[`

        var items: [TimeFormatItem] = []
        while !isAtEnd {
            if inLiteralContext, byte() == UInt8(ascii: "]") { break }
            items.append(try parseNextItem())
        }

        guard consumeClosingBracket() != nil else {
            // Restore depth as upstream does before propagating.
            depth -= 1
            throw TimeFormatParseError.unclosedOpeningBracket(index: openingBracket)
        }

        return NestedDescription(
            leadingWhitespace: leadingWhitespace,
            openingBracket: openingBracket,
            items: items,
            closingBracket: pos - 1)
    }

    /// Consume literal text up to the next `[`, `]`, or `\`.
    private mutating func consumeLiteral() -> String {
        let start = pos
        while let b = byte(),
              b != UInt8(ascii: "["), b != UInt8(ascii: "]"),
              b != UInt8(ascii: "\\") {
            advance()
        }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    /// `\` escape: only `\\`, `\[`, `\]` are valid in v2.
    private mutating func consumeEscape(at backslashIndex: Int) throws -> String {
        guard let next = byte(1) else {
            throw TimeFormatParseError.expected(
                what: "valid escape sequence", index: backslashIndex)
        }
        guard next == UInt8(ascii: "\\") || next == UInt8(ascii: "[")
                || next == UInt8(ascii: "]") else {
            throw TimeFormatParseError.expected(
                what: "valid escape sequence", index: pos + 1)
        }
        let char = String(decoding: bytes[(pos + 1)..<(pos + 2)], as: UTF8.self)
        advance(2)
        return char
    }

    mutating func parseNextItem() throws -> TimeFormatItem {
        let b = bytes[pos]
        switch b {
        case UInt8(ascii: "["):
            return try consumeComponent()
        case UInt8(ascii: "]"):
            // v2: unescaped `]` is a literal.
            advance()
            return .literal("]")
        case UInt8(ascii: "\\"):
            let index = pos
            return .literal(try consumeEscape(at: index))
        default:
            return .literal(consumeLiteral())
        }
    }

    /// Parse `[...]` — a component, `optional`, or `first` item.
    private mutating func consumeComponent() throws -> TimeFormatItem {
        let openingBracket = pos
        try enterDepth(at: openingBracket)
        advance()  // consume `[`

        let (name, nameIndex) = try consumeComponentName(openingBracket: openingBracket)
        let (modifiers, trailingWhitespace) = try parseModifiers()

        var nested: [NestedDescription] = []
        while isNestedDescriptionStart() {
            // Upstream swallows errors from `consume_nested` here.
            if let description = try? consumeNested(lastLocation: modifiers.endLocation) {
                nested.append(description)
            } else {
                break
            }
        }

        if trailingWhitespace, !nested.isEmpty {
            nested[0].leadingWhitespace = true
        }
        if !trailingWhitespace || !nested.isEmpty {
            _ = consumeWhitespace()
        }

        guard let closingBracket = consumeClosingBracket() else {
            throw TimeFormatParseError.unclosedOpeningBracket(index: openingBracket)
        }

        if let firstNested = nested.first, !firstNested.leadingWhitespace {
            throw TimeFormatParseError.expected(
                what: "whitespace before nested format description",
                index: firstNested.openingBracket)
        }

        let loweredName = name.lowercased()
        if loweredName == "optional" {
            let format = try parseOptionalFormatModifier(modifiers)
            guard nested.count == 1 else {
                if nested.count >= 2 {
                    throw TimeFormatParseError.notSupported(
                        what: "more than one nested format description",
                        context: "`optional` components",
                        index: nested[1].openingBracket)
                }
                throw TimeFormatParseError.expected(
                    what: "nested format description", index: closingBracket)
            }
            if !format {
                throw TimeFormatParseError.notSupported(
                    what: "optional item with `format:false`",
                    context: "v1 and v2 format descriptions",
                    index: openingBracket)
            }
            return .optional(true, itemsToOwned(nested[0].items))
        }

        if loweredName == "first" {
            if let first = modifiers.first {
                throw TimeFormatParseError.invalidModifier(
                    value: first.key, index: first.keyIndex)
            }
            return .first(nested.map { itemsToOwned($0.items) })
        }

        guard nested.isEmpty else {
            throw TimeFormatParseError.notSupported(
                what: "nested format descriptions",
                context: "on this component",
                index: openingBracket)
        }

        return .component(try componentFromAst(name: name, nameIndex: nameIndex, modifiers: modifiers))
    }
}

private extension ParsedModifier {
    /// End of the value span — used as `last_location` for nested
    /// descriptions (only surfaces in depth-overflow errors).
    var endLocation: Int { valueIndex + value.utf8.count }
}

private extension [ParsedModifier] {
    /// Upstream `Modifiers::end_location` — `Location::DUMMY` when empty;
    /// only used for the (unreachable-in-practice) depth overflow index.
    var endLocation: Int {
        last?.endLocation ?? 0
    }
}

/// `items_to_owned_format_item`: a single item is used directly,
/// multiple items become a compound.
private func itemsToOwned(_ items: [TimeFormatItem]) -> TimeFormatItem {
    if items.count == 1 { return items[0] }
    return .compound(items)
}

// MARK: - Component construction

/// Parse the `format` modifier of `optional` — the only allowed key.
private func parseOptionalFormatModifier(_ modifiers: [ParsedModifier]) throws -> Bool {
    var format: Bool? = nil
    for modifier in modifiers {
        guard modifier.loweredKey == "format" else {
            throw TimeFormatParseError.invalidModifier(
                value: modifier.key, index: modifier.keyIndex)
        }
        switch modifier.value.lowercased() {
        case "true": format = true
        case "false": format = false
        default:
            throw TimeFormatParseError.invalidModifier(
                value: modifier.value, index: modifier.valueIndex)
        }
    }
    return format ?? true
}

/// Errors for modifier combinations, mirroring `reject_modifier!`.
private func rejectCombination(
    _ modifier: ParsedModifier?, _ name: String, _ context: String
) throws {
    if let modifier {
        throw TimeFormatParseError.invalidModifierCombination(
            modifier: name, context: context, index: modifier.keyIndex)
    }
}

/// Throw `InvalidModifier` for an unrecognized modifier key.
private func rejectKey(_ modifier: ParsedModifier) throws -> Never {
    throw TimeFormatParseError.invalidModifier(
        value: modifier.key, index: modifier.keyIndex)
}

private func parsePadding(_ modifier: ParsedModifier) throws -> TimePadding {
    switch modifier.value.lowercased() {
    case "space": return .space
    case "zero": return .zero
    case "none": return .none
    default:
        throw TimeFormatParseError.invalidModifier(
            value: modifier.value, index: modifier.valueIndex)
    }
}

private func parseBool(_ modifier: ParsedModifier) throws -> Bool {
    switch modifier.value.lowercased() {
    case "true": return true
    case "false": return false
    default:
        throw TimeFormatParseError.invalidModifier(
            value: modifier.value, index: modifier.valueIndex)
    }
}

private func parseSign(_ modifier: ParsedModifier) throws -> Bool {
    switch modifier.value.lowercased() {
    case "automatic": return false
    case "mandatory": return true
    default:
        throw TimeFormatParseError.invalidModifier(
            value: modifier.value, index: modifier.valueIndex)
    }
}

/// The `month` `repr` modifier values.
private enum MonthReprValue {
    case numerical, long, short
    init(_ modifier: ParsedModifier) throws {
        switch modifier.value.lowercased() {
        case "numerical": self = .numerical
        case "long": self = .long
        case "short": self = .short
        default:
            throw TimeFormatParseError.invalidModifier(
                value: modifier.value, index: modifier.valueIndex)
        }
    }
}

private enum WeekdayReprValue {
    case short, long, sunday, monday
    init(_ modifier: ParsedModifier) throws {
        switch modifier.value.lowercased() {
        case "short": self = .short
        case "long": self = .long
        case "sunday": self = .sunday
        case "monday": self = .monday
        default:
            throw TimeFormatParseError.invalidModifier(
                value: modifier.value, index: modifier.valueIndex)
        }
    }
}

private enum WeekNumberReprValue {
    case iso, sunday, monday
    init(_ modifier: ParsedModifier) throws {
        switch modifier.value.lowercased() {
        case "iso": self = .iso
        case "sunday": self = .sunday
        case "monday": self = .monday
        default:
            throw TimeFormatParseError.invalidModifier(
                value: modifier.value, index: modifier.valueIndex)
        }
    }
}

private enum YearReprValue {
    case full, century, lastTwo
    init(_ modifier: ParsedModifier) throws {
        switch modifier.value.lowercased() {
        case "full": self = .full
        case "century": self = .century
        case "last_two": self = .lastTwo
        default:
            throw TimeFormatParseError.invalidModifier(
                value: modifier.value, index: modifier.valueIndex)
        }
    }
}

private enum YearBaseValue {
    case calendar, isoWeek
    init(_ modifier: ParsedModifier) throws {
        switch modifier.value.lowercased() {
        case "calendar": self = .calendar
        case "iso_week": self = .isoWeek
        default:
            throw TimeFormatParseError.invalidModifier(
                value: modifier.value, index: modifier.valueIndex)
        }
    }
}

private enum HourBaseValue {
    case twelve, twentyFour
    init(_ modifier: ParsedModifier) throws {
        switch modifier.value.lowercased() {
        case "12": self = .twelve
        case "24": self = .twentyFour
        default:
            throw TimeFormatParseError.invalidModifier(
                value: modifier.value, index: modifier.valueIndex)
        }
    }
}

private enum PeriodCaseValue {
    case upper, lower
    init(_ modifier: ParsedModifier) throws {
        switch modifier.value.lowercased() {
        case "upper": self = .upper
        case "lower": self = .lower
        default:
            throw TimeFormatParseError.invalidModifier(
                value: modifier.value, index: modifier.valueIndex)
        }
    }
}

private enum TrailingInputValue {
    case prohibit, discard
    init(_ modifier: ParsedModifier) throws {
        switch modifier.value.lowercased() {
        case "prohibit": self = .prohibit
        case "discard": self = .discard
        default:
            throw TimeFormatParseError.invalidModifier(
                value: modifier.value, index: modifier.valueIndex)
        }
    }
}

private enum UnixTimestampPrecisionValue {
    case second, millisecond, microsecond, nanosecond
    init(_ modifier: ParsedModifier) throws {
        switch modifier.value.lowercased() {
        case "second": self = .second
        case "millisecond": self = .millisecond
        case "microsecond": self = .microsecond
        case "nanosecond": self = .nanosecond
        default:
            throw TimeFormatParseError.invalidModifier(
                value: modifier.value, index: modifier.valueIndex)
        }
    }
}

private enum SubsecondDigitsValue {
    case one, two, three, four, five, six, seven, eight, nine, oneOrMore
    init(_ modifier: ParsedModifier) throws {
        switch modifier.value {
        case "1": self = .one
        case "2": self = .two
        case "3": self = .three
        case "4": self = .four
        case "5": self = .five
        case "6": self = .six
        case "7": self = .seven
        case "8": self = .eight
        case "9": self = .nine
        case "1+": self = .oneOrMore
        default:
            throw TimeFormatParseError.invalidModifier(
                value: modifier.value, index: modifier.valueIndex)
        }
    }

    var digits: SubsecondDigits {
        switch self {
        case .one: return .one
        case .two: return .two
        case .three: return .three
        case .four: return .four
        case .five: return .five
        case .six: return .six
        case .seven: return .seven
        case .eight: return .eight
        case .nine: return .nine
        case .oneOrMore: return .oneOrMore
        }
    }
}

/// Map a component name + modifiers to a resolved `TimeComponent`.
///
/// Mirrors upstream's two-phase construction: `with_modifiers` validates
/// each modifier key and parses its value in order (so the first bad key
/// *or* value in list order wins), then `TryFrom<AstComponent>` resolves
/// `repr`/`base`/`range` combinations into the concrete component.
private func componentFromAst(
    name: String, nameIndex: Int, modifiers: [ParsedModifier]
) throws -> TimeComponent {
    let lowered = name.lowercased()
    switch lowered {
    case "day":
        var padding: TimePadding?
        for m in modifiers {
            if m.loweredKey == "padding" { padding = try parsePadding(m) }
            else { try rejectKey(m) }
        }
        return .day(padding: padding ?? .zero)
    case "end":
        for m in modifiers {
            if m.loweredKey == "trailing_input" {
                _ = try TrailingInputValue(m)
            } else { try rejectKey(m) }
        }
        return .end
    case "hour":
        var padding: TimePadding?
        var base: HourBaseValue?
        for m in modifiers {
            switch m.loweredKey {
            case "padding": padding = try parsePadding(m)
            case "repr": base = try HourBaseValue(m)
            default: try rejectKey(m)
            }
        }
        switch base ?? .twentyFour {
        case .twelve: return .hour12(padding: padding ?? .zero)
        case .twentyFour: return .hour24(padding: padding ?? .zero)
        }
    case "ignore":
        var count: Int?
        for m in modifiers {
            if m.loweredKey == "count" {
                let digits = m.value.hasPrefix("+")
                    ? String(m.value.dropFirst()) : m.value
                guard let v = UInt16(digits), v != 0 else {
                    throw TimeFormatParseError.invalidModifier(
                        value: m.value, index: m.valueIndex)
                }
                count = Int(v)
            } else { try rejectKey(m) }
        }
        guard count != nil else {
            throw TimeFormatParseError.missingRequiredModifier(
                name: "count", index: nameIndex)
        }
        return .ignore
    case "minute":
        var padding: TimePadding?
        for m in modifiers {
            if m.loweredKey == "padding" { padding = try parsePadding(m) }
            else { try rejectKey(m) }
        }
        return .minute(padding: padding ?? .zero)
    case "month":
        var padding: TimePadding?, paddingMod: ParsedModifier?
        var repr: MonthReprValue?
        var caseSensitive: Bool?, csMod: ParsedModifier?
        for m in modifiers {
            switch m.loweredKey {
            case "padding":
                padding = try parsePadding(m); paddingMod = m
            case "repr":
                repr = try MonthReprValue(m)
            case "case_sensitive":
                caseSensitive = try parseBool(m); csMod = m
            default: try rejectKey(m)
            }
        }
        switch repr ?? .numerical {
        case .numerical:
            try rejectCombination(csMod, "case_sensitive", "for numerical month")
            return .monthNumerical(padding: padding ?? .zero)
        case .long:
            try rejectCombination(paddingMod, "padding", "for long month")
            return .monthLong(caseSensitive: caseSensitive ?? true)
        case .short:
            try rejectCombination(paddingMod, "padding", "for short month")
            return .monthShort(caseSensitive: caseSensitive ?? true)
        }
    case "offset_hour":
        var mandatory = false
        var padding: TimePadding?
        for m in modifiers {
            switch m.loweredKey {
            case "sign": mandatory = try parseSign(m)
            case "padding": padding = try parsePadding(m)
            default: try rejectKey(m)
            }
        }
        return .offsetHour(signMandatory: mandatory, padding: padding ?? .zero)
    case "offset_minute":
        var padding: TimePadding?
        for m in modifiers {
            if m.loweredKey == "padding" { padding = try parsePadding(m) }
            else { try rejectKey(m) }
        }
        return .offsetMinute(padding: padding ?? .zero)
    case "offset_second":
        var padding: TimePadding?
        for m in modifiers {
            if m.loweredKey == "padding" { padding = try parsePadding(m) }
            else { try rejectKey(m) }
        }
        return .offsetSecond(padding: padding ?? .zero)
    case "ordinal":
        var padding: TimePadding?
        for m in modifiers {
            if m.loweredKey == "padding" { padding = try parsePadding(m) }
            else { try rejectKey(m) }
        }
        return .ordinal(padding: padding ?? .zero)
    case "period":
        var uppercase = true
        var caseSensitive = true
        for m in modifiers {
            switch m.loweredKey {
            case "case":
                switch try PeriodCaseValue(m) {
                case .upper: uppercase = true
                case .lower: uppercase = false
                }
            case "case_sensitive": caseSensitive = try parseBool(m)
            default: try rejectKey(m)
            }
        }
        return .period(isUppercase: uppercase, caseSensitive: caseSensitive)
    case "second":
        var padding: TimePadding?
        for m in modifiers {
            if m.loweredKey == "padding" { padding = try parsePadding(m) }
            else { try rejectKey(m) }
        }
        return .second(padding: padding ?? .zero)
    case "subsecond":
        var digits = SubsecondDigits.oneOrMore
        for m in modifiers {
            if m.loweredKey == "digits" {
                digits = try SubsecondDigitsValue(m).digits
            } else { try rejectKey(m) }
        }
        return .subsecond(digits: digits)
    case "unix_timestamp":
        var mandatory = false
        var precision: UnixTimestampPrecisionValue?
        for m in modifiers {
            switch m.loweredKey {
            case "sign": mandatory = try parseSign(m)
            case "precision": precision = try UnixTimestampPrecisionValue(m)
            default: try rejectKey(m)
            }
        }
        switch precision ?? .second {
        case .second: return .unixTimestampSecond(signMandatory: mandatory)
        case .millisecond: return .unixTimestampMillisecond(signMandatory: mandatory)
        case .microsecond: return .unixTimestampMicrosecond(signMandatory: mandatory)
        case .nanosecond: return .unixTimestampNanosecond(signMandatory: mandatory)
        }
    case "weekday":
        var repr: WeekdayReprValue?
        var oneIndexed: Bool?, oiMod: ParsedModifier?
        var caseSensitive: Bool?, csMod: ParsedModifier?
        for m in modifiers {
            switch m.loweredKey {
            case "repr": repr = try WeekdayReprValue(m)
            case "one_indexed":
                oneIndexed = try parseBool(m); oiMod = m
            case "case_sensitive":
                caseSensitive = try parseBool(m); csMod = m
            default: try rejectKey(m)
            }
        }
        switch repr ?? .long {
        case .short:
            try rejectCombination(oiMod, "one_indexed", "for short weekday")
            return .weekdayShort(caseSensitive: caseSensitive ?? true)
        case .long:
            try rejectCombination(oiMod, "one_indexed", "for long weekday")
            return .weekdayLong(caseSensitive: caseSensitive ?? true)
        case .sunday:
            try rejectCombination(csMod, "case_sensitive", "for numerical weekday")
            return .weekdaySunday(oneIndexed: oneIndexed ?? true)
        case .monday:
            try rejectCombination(csMod, "case_sensitive", "for numerical weekday")
            return .weekdayMonday(oneIndexed: oneIndexed ?? true)
        }
    case "week_number":
        var padding: TimePadding?
        var repr: WeekNumberReprValue?
        for m in modifiers {
            switch m.loweredKey {
            case "padding": padding = try parsePadding(m)
            case "repr": repr = try WeekNumberReprValue(m)
            default: try rejectKey(m)
            }
        }
        let p = padding ?? .zero
        switch repr ?? .iso {
        case .iso: return .weekNumberIso(padding: p)
        case .sunday: return .weekNumberSunday(padding: p)
        case .monday: return .weekNumberMonday(padding: p)
        }
    case "year":
        var padding: TimePadding?
        var repr: YearReprValue?
        var rangeMod: ParsedModifier?
        var base: YearBaseValue?
        var signMod: ParsedModifier?
        var mandatory = false
        for m in modifiers {
            switch m.loweredKey {
            case "padding": padding = try parsePadding(m)
            case "repr": repr = try YearReprValue(m)
            case "range":
                // The value is validated during the modifier pass
                // (upstream `YearRange::from_modifier_value`); the
                // `large-dates` rejection happens afterwards.
                switch m.value.lowercased() {
                case "standard", "extended": rangeMod = m
                default:
                    throw TimeFormatParseError.invalidModifier(
                        value: m.value, index: m.valueIndex)
                }
            case "base": base = try YearBaseValue(m)
            case "sign": mandatory = try parseSign(m); signMod = m
            default: try rejectKey(m)
            }
        }
        if let rangeMod {
            throw TimeFormatParseError.invalidModifierCombination(
                modifier: "range",
                context: "when the `large-dates` feature is not enabled",
                index: rangeMod.keyIndex)
        }
        let isoWeek = (base ?? .calendar) == .isoWeek
        let p = padding ?? .zero
        switch repr ?? .full {
        case .full:
            return isoWeek
                ? .isoYearFullStandard(padding: p, signMandatory: mandatory)
                : .calendarYearFullStandard(padding: p, signMandatory: mandatory)
        case .century:
            return isoWeek
                ? .isoYearCenturyStandard(padding: p, signMandatory: mandatory)
                : .calendarYearCenturyStandard(padding: p, signMandatory: mandatory)
        case .lastTwo:
            try rejectCombination(signMod, "sign", "when `repr:last_two` is used")
            return isoWeek ? .isoYearLastTwo(padding: p) : .calendarYearLastTwo(padding: p)
        }
    default:
        throw TimeFormatParseError.invalidComponentName(
            name: name, index: nameIndex)
    }
}

// MARK: - Formatting

private let monthNames = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
]

private let weekdayNames = [
    "Monday", "Tuesday", "Wednesday", "Thursday",
    "Friday", "Saturday", "Sunday",
]

/// Format a non-negative integer padded to `width` per `padding`.
private func formatPadded(_ value: Int, _ width: Int, _ padding: TimePadding) -> String {
    let digits = String(value)
    guard digits.count < width, padding != .none else { return digits }
    let fill = padding == .space ? " " : "0"
    return String(repeating: fill, count: width - digits.count) + digits
}

/// The sign prefix for year-like components.
private func formatSign(_ isNegative: Bool, _ mandatory: Bool) -> String {
    if isNegative { return "-" }
    if mandatory { return "+" }
    return ""
}

extension TypstDate {
    /// ISO-8601 `(year, week)` pair — port of `time`'s `iso_year_week`.
    var isoYearWeek: (year: Int, week: Int) {
        let dowMonday = weekday  // 1 = Monday ... 7 = Sunday
        let raw = (ordinal + 10 - dowMonday) / 7
        if raw == 0 {
            return (year - 1, TypstDate.weeksInYear(year - 1))
        }
        if raw == 53, TypstDate.weeksInYear(year) == 52 {
            return (year + 1, 1)
        }
        return (year, raw)
    }

    /// Whether the ISO year has 53 weeks (Jan 1 Thursday, or leap + Wednesday).
    static func weeksInYear(_ year: Int) -> Int {
        guard let jan1 = TypstDate(year: year, month: 1, day: 1) else { return 52 }
        let dow = jan1.weekday  // 1 = Monday ... 7 = Sunday
        if dow == 4 { return 53 }          // Thursday
        if dow == 3, isLeap(year) { return 53 }  // Wednesday in leap year
        return 52
    }

    /// Week number where week 1 starts on the first Sunday (0-53).
    var sundayBasedWeek: Int {
        // `number_days_from_sunday`: Sunday = 0, Monday = 1, ..., Saturday = 6.
        let daysFromSunday = weekday % 7
        return (ordinal - daysFromSunday + 6) / 7
    }

    /// Week number where week 1 starts on the first Monday (0-53).
    var mondayBasedWeek: Int {
        // `number_days_from_monday`: Monday = 0, ..., Sunday = 6.
        let daysFromMonday = weekday - 1
        return (ordinal - daysFromMonday + 6) / 7
    }
}

/// Format one component against the available date/time parts.
/// `nil` date/time models upstream's `SUPPLIES_DATE`/`SUPPLIES_TIME`.
private func formatComponent(
    _ component: TimeComponent, date: TypstDate?, time: TypstTime?
) throws -> String {
    switch component {
    // MARK: date components (require a date)
    case let .day(padding):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded(d.day, 2, padding)
    case .monthShort(_):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }  // no effect on formatting
        return String(monthNames[d.month - 1].prefix(3))
    case .monthLong(_):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        return monthNames[d.month - 1]
    case let .monthNumerical(padding):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded(d.month, 2, padding)
    case let .ordinal(padding):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded(d.ordinal, 3, padding)
    case .weekdayShort(_):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        return String(weekdayNames[d.weekday - 1].prefix(3))
    case .weekdayLong(_):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        return weekdayNames[d.weekday - 1]
    case let .weekdaySunday(oneIndexed):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        // `number_days_from_sunday` + one_indexed.
        return String(d.weekday % 7 + (oneIndexed ? 1 : 0))
    case let .weekdayMonday(oneIndexed):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        // `number_days_from_monday` + one_indexed.
        return String(d.weekday - 1 + (oneIndexed ? 1 : 0))
    case let .weekNumberIso(padding):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded(d.isoYearWeek.week, 2, padding)
    case let .weekNumberSunday(padding):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded(d.sundayBasedWeek, 2, padding)
    case let .weekNumberMonday(padding):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded(d.mondayBasedWeek, 2, padding)

    // MARK: year components (require a date)
    case let .calendarYearFullStandard(padding, signMandatory):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        guard abs(d.year) <= 9999 else { throw TimeFormatFailure.componentRange("year") }
        return formatSign(d.year < 0, signMandatory)
            + formatPadded(abs(d.year), 4, padding)
    case let .calendarYearCenturyStandard(padding, signMandatory):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        let century = d.year / 100  // truncates toward zero, like Rust
        guard abs(century) <= 99 else { throw TimeFormatFailure.componentRange("year") }
        return formatSign(d.year < 0, signMandatory)
            + formatPadded(abs(century), 2, padding)
    case let .calendarYearLastTwo(padding):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded(abs(d.year) % 100, 2, padding)
    case let .isoYearFullStandard(padding, signMandatory):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        let year = d.isoYearWeek.year
        guard abs(year) <= 9999 else { throw TimeFormatFailure.componentRange("year") }
        return formatSign(year < 0, signMandatory)
            + formatPadded(abs(year), 4, padding)
    case let .isoYearCenturyStandard(padding, signMandatory):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        let year = d.isoYearWeek.year
        let century = year / 100
        guard abs(century) <= 99 else { throw TimeFormatFailure.componentRange("year") }
        return formatSign(year < 0, signMandatory)
            + formatPadded(abs(century), 2, padding)
    case let .isoYearLastTwo(padding):
        guard let d = date else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded(abs(d.isoYearWeek.year) % 100, 2, padding)

    // MARK: time components (require a time)
    case let .hour12(padding):
        guard let t = time else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded((t.hour + 11) % 12 + 1, 2, padding)
    case let .hour24(padding):
        guard let t = time else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded(t.hour, 2, padding)
    case let .minute(padding):
        guard let t = time else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded(t.minute, 2, padding)
    case let .period(isUppercase, _):
        guard let t = time else { throw TimeFormatFailure.insufficientTypeInformation }
        let base = t.hour < 12 ? "am" : "pm"
        return isUppercase ? base.uppercased() : base
    case let .second(padding):
        guard let t = time else { throw TimeFormatFailure.insufficientTypeInformation }
        return formatPadded(t.second, 2, padding)
    case let .subsecond(digits):
        guard let t = time else { throw TimeFormatFailure.insufficientTypeInformation }
        // Nine decimal digits of the nanosecond.
        let all = String(format: "%09d", t.nanosecond)
        let count: Int
        if digits == .oneOrMore {
            // Trailing zeros are trimmed, but at least one digit remains.
            var end = all.endIndex
            while end > all.startIndex {
                let prev = all.index(before: end)
                if all[prev] != "0" { break }
                end = prev
            }
            if end == all.startIndex { end = all.index(after: all.startIndex) }
            count = all.distance(from: all.startIndex, to: end)
        } else {
            count = digits.count
        }
        return String(all.prefix(count))

    // MARK: components a naive value can never supply
    case .offsetHour, .offsetMinute, .offsetSecond,
         .unixTimestampSecond, .unixTimestampMillisecond,
         .unixTimestampMicrosecond, .unixTimestampNanosecond:
        throw TimeFormatFailure.insufficientTypeInformation

    // MARK: formatting no-ops
    case .ignore, .end:
        return ""
    }
}

/// Format a parsed description against a date and/or time.
/// Mirrors `time`'s `format_into` for `Date`, `Time`, `PrimitiveDateTime`.
func formatTimeDescription(
    _ item: TimeFormatItem, date: TypstDate?, time: TypstTime?
) throws -> String {
    var out = ""
    try formatItem(item, into: &out, date: date, time: time)
    return out
}

private func formatItem(
    _ item: TimeFormatItem, into out: inout String,
    date: TypstDate?, time: TypstTime?
) throws {
    switch item {
    case let .literal(text):
        out += text
    case let .component(component):
        out += try formatComponent(component, date: date, time: time)
    case let .compound(items):
        for sub in items {
            try formatItem(sub, into: &out, date: date, time: time)
        }
    case let .optional(_, inner):
        try formatItem(inner, into: &out, date: date, time: time)
    case let .first(items):
        if let first = items.first {
            try formatItem(first, into: &out, date: date, time: time)
        }
    }
}

/// Parse a format description string (the `parse_owned::<2>` entry point).
func parseTimeFormatDescription(_ string: String) throws -> TimeFormatItem {
    var lexer = FormatLexer(string)
    var items: [TimeFormatItem] = []
    while !lexer.isAtEnd {
        items.append(try lexer.parseNextItem())
    }
    return itemsToOwned(items)
}
