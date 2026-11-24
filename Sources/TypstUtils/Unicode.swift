import Foundation

/// XID_Start / XID_Continue lookups, ported from the `unicode-ident` crate
/// (Unicode 18.0.0) tables. Table data lives in `UnicodeIdentTables.swift`.
public enum UnicodeIdent {
    /// Whether the scalar has the Unicode property XID_Start.
    public static func isXIDStart(_ ch: Unicode.Scalar) -> Bool {
        let value = ch.value
        if value < 128 {
            let t = UnicodeIdentTables.self
            if value < 64 {
                return (t.asciiStartLo & (UInt64(1) << value)) != 0
            }
            return (t.asciiStartHi & (UInt64(1) << (value - 64))) != 0
        }
        let t = UnicodeIdentTables.self
        let idx = Int(value) / 8 / t.chunk
        let chunk = idx < t.trieStart.count
            ? t.trieStart[idx]
            : t.trieStart[t.zeroStart]
        let offset = t.leafStart + Int(chunk) * t.chunk / 2
            + Int(value) / 8 % t.chunk
        return (t.leaf[offset] >> UInt8(value % 8)) & 1 != 0
    }

    /// Whether the scalar has the Unicode property XID_Continue.
    public static func isXIDContinue(_ ch: Unicode.Scalar) -> Bool {
        let value = ch.value
        if value < 128 {
            let t = UnicodeIdentTables.self
            if value < 64 {
                return (t.asciiContinueLo & (UInt64(1) << value)) != 0
            }
            return (t.asciiContinueHi & (UInt64(1) << (value - 64))) != 0
        }
        let t = UnicodeIdentTables.self
        let idx = Int(value) / 8 / t.chunk
        let chunk = idx < t.trieContinue.count
            ? t.trieContinue[idx]
            : t.trieContinue[t.zeroContinue]
        let offset = t.leafContinue + Int(chunk) * t.chunk / 2
            + Int(value) / 8 % t.chunk
        return (t.leaf[offset] >> UInt8(value % 8)) & 1 != 0
    }
}

extension Unicode.Scalar {
    /// `char::is_whitespace` equivalent (Unicode White_Space property).
    public var isTypstWhitespace: Bool { properties.isWhitespace }

    /// `char::is_numeric` equivalent (Nd, Nl, No general categories).
    public var isTypstNumeric: Bool {
        switch properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// `char::is_alphanumeric` equivalent.
    public var isTypstAlphanumeric: Bool {
        properties.isAlphabetic || isTypstNumeric
    }

    /// `char::is_ascii_alphanumeric` equivalent.
    public var isASCIIAlphanumeric: Bool {
        (value >= 48 && value <= 57)
            || (value >= 65 && value <= 90)
            || (value >= 97 && value <= 122)
    }

    /// `char::is_ascii_digit` equivalent.
    public var isASCIIDigit: Bool { value >= 48 && value <= 57 }

    /// `char::is_ascii_hexdigit`-style alphanumeric for escape parsing.
    public var isASCIIAlphaNumeric: Bool { isASCIIAlphanumeric }

    /// Whether the scalar's script is one of the CJK scripts excluded from
    /// "word" characters (Han, Hiragana, Katakana, Hangul), matching
    /// `unicode_script::Script` usage in the lexer. Range-based approximation
    /// of the script property for the allocated blocks of those scripts.
    public var isCJKScript: Bool {
        switch value {
        // Hiragana, Katakana, Katakana phonetic extensions, halfwidth katakana.
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF,
             0x32D0...0x32FF, 0xFF66...0xFF9D:
            return true
        // CJK Unified Ideographs (+ ext A, compat, ext B+ ranges).
        case 0x2E80...0x2EFF, 0x2F00...0x2FDF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF,
             0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF,
             0x2CEB0...0x2EBEF, 0x30000...0x3134F:
            return true
        // Hangul syllables, Jamo, compatibility Jamo, Jamo extended.
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
             0xAC00...0xD7AF, 0xD7B0...0xD7FF:
            return true
        default:
            return false
        }
    }
}
