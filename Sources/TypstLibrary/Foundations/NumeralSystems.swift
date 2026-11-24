import Foundation

// Numeral systems, ported from `codex-0.3.0/src/numeral_systems.rs` and the
// `chinese-number` crate's `number_to_chinese` ten-thousand path. Used by
// `NumberingPattern` in `model/numbering.rs`.

/// Why a number cannot be represented in a numeral system.
/// Port of `RepresentationError` in codex.
public enum RepresentationError: Error, Sendable, Hashable {
    /// Zero cannot be represented in the numeral system.
    case zero
    /// The number is too large for the numeral system.
    case tooLarge
}

/// A list of named numeral systems. Port of `NamedNumeralSystem`.
public enum NamedNumeralSystem: Sendable, Hashable, CaseIterable {
    case arabic
    case circledArabic
    case doubleCircledArabic
    case lowerLatin
    case upperLatin
    case lowerRoman
    case upperRoman
    case lowerGreek
    case upperGreek
    case lowerArmenian
    case upperArmenian
    case hebrew
    case lowerSimplifiedChinese
    case upperSimplifiedChinese
    case lowerTraditionalChinese
    case upperTraditionalChinese
    case hiraganaAiueo
    case hiraganaIroha
    case katakanaAiueo
    case katakanaIroha
    case koreanJamo
    case koreanSyllable
    case easternArabic
    case arabicAbjad
    case persian
    case devanagari
    case tibetan
    case bengali
    case bengaliLetters
    case symbols

    /// The name used to look the system up.
    public var name: String {
        switch self {
        case .arabic: return "arabic"
        case .circledArabic: return "arabic.o"
        case .doubleCircledArabic: return "arabic.oo"
        case .lowerLatin: return "latin"
        case .upperLatin: return "Latin"
        case .lowerRoman: return "roman"
        case .upperRoman: return "Roman"
        case .lowerGreek: return "greek"
        case .upperGreek: return "Greek"
        case .lowerArmenian: return "armenian"
        case .upperArmenian: return "Armenian"
        case .hebrew: return "hebrew"
        case .lowerSimplifiedChinese: return "chinese.simple"
        case .upperSimplifiedChinese: return "Chinese.simple"
        case .lowerTraditionalChinese: return "chinese.trad"
        case .upperTraditionalChinese: return "Chinese.trad"
        case .hiraganaAiueo: return "hiragana.aiueo"
        case .hiraganaIroha: return "hiragana.iroha"
        case .katakanaAiueo: return "katakana.aiueo"
        case .katakanaIroha: return "katakana.iroha"
        case .koreanJamo: return "korean.jamo"
        case .koreanSyllable: return "korean.syllable"
        case .easternArabic: return "arabic.eastern"
        case .arabicAbjad: return "arabic.abjad"
        case .persian: return "persian"
        case .devanagari: return "devanagari"
        case .tibetan: return "tibetan"
        case .bengali: return "bengali"
        case .bengaliLetters: return "bengali.letter"
        case .symbols: return "symbol"
        }
    }

    /// Look up a named numeral system by name.
    public static func fromName(_ name: String) -> NamedNumeralSystem? {
        allCases.first { $0.name == name }
    }

    /// The shorthand identifying this system (the number one rendered in it).
    public var shorthand: String? {
        switch self {
        case .arabic: return "1"
        case .circledArabic: return "①"
        case .doubleCircledArabic: return "⓵"
        case .lowerLatin: return "a"
        case .upperLatin: return "A"
        case .lowerRoman: return "i"
        case .upperRoman: return "I"
        case .lowerGreek: return "α"
        case .upperGreek: return "Α"
        case .lowerArmenian: return "ա"
        case .upperArmenian: return "Ա"
        case .hebrew: return "א"
        case .lowerSimplifiedChinese: return "一"
        case .upperSimplifiedChinese: return "壹"
        case .lowerTraditionalChinese: return nil
        case .upperTraditionalChinese: return nil
        case .hiraganaAiueo: return "あ"
        case .hiraganaIroha: return "い"
        case .katakanaAiueo: return "ア"
        case .katakanaIroha: return "イ"
        case .koreanJamo: return "ㄱ"
        case .koreanSyllable: return "가"
        case .easternArabic: return "١"
        case .arabicAbjad: return "أ"
        case .persian: return "۱"
        case .devanagari: return "१"
        case .tibetan: return "༡"
        case .bengali: return "১"
        case .bengaliLetters: return "ক"
        case .symbols: return "*"
        }
    }

    /// Look up a named numeral system by shorthand.
    public static func fromShorthand(_ shorthand: String) -> NamedNumeralSystem? {
        allCases.first { $0.shorthand == shorthand }
    }

    /// The underlying numeral system.
    public var system: NumeralSystem {
        switch self {
        case .arabic:
            return .positional(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
        case .circledArabic:
            return .fixed([
                "⓪", "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩", "⑪", "⑫", "⑬",
                "⑭", "⑮", "⑯", "⑰", "⑱", "⑲", "⑳", "㉑", "㉒", "㉓", "㉔", "㉕", "㉖",
                "㉗", "㉘", "㉙", "㉚", "㉛", "㉜", "㉝", "㉞", "㉟", "㊱", "㊲", "㊳",
                "㊴", "㊵", "㊶", "㊷", "㊸", "㊹", "㊺", "㊻", "㊼", "㊽", "㊾", "㊿",
            ])
        case .doubleCircledArabic:
            return .zerolessFixed(["⓵", "⓶", "⓷", "⓸", "⓹", "⓺", "⓻", "⓼", "⓽", "⓾"])
        case .lowerLatin:
            return .bijective(Array("abcdefghijklmnopqrstuvwxyz").map { String($0) })
        case .upperLatin:
            return .bijective(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map { String($0) })
        case .lowerRoman:
            return .additive([
                ("m̅", 1000000), ("d̅", 500000), ("c̅", 100000), ("l̅", 50000),
                ("x̅", 10000), ("v̅", 5000), ("i̅v̅", 4000),
                ("m", 1000), ("cm", 900), ("d", 500), ("cd", 400), ("c", 100),
                ("xc", 90), ("l", 50), ("xl", 40), ("x", 10), ("ix", 9), ("v", 5),
                ("iv", 4), ("i", 1), ("n", 0),
            ])
        case .upperRoman:
            return .additive([
                ("M̅", 1000000), ("D̅", 500000), ("C̅", 100000), ("L̅", 50000),
                ("X̅", 10000), ("V̅", 5000), ("I̅V̅", 4000),
                ("M", 1000), ("CM", 900), ("D", 500), ("CD", 400), ("C", 100),
                ("XC", 90), ("L", 50), ("XL", 40), ("X", 10), ("IX", 9), ("V", 5),
                ("IV", 4), ("I", 1), ("N", 0),
            ])
        case .lowerGreek:
            return .additive([
                ("͵θ", 9000), ("͵η", 8000), ("͵ζ", 7000), ("͵ϛ", 6000),
                ("͵ε", 5000), ("͵δ", 4000), ("͵γ", 3000), ("͵β", 2000),
                ("͵α", 1000), ("ϡ", 900), ("ω", 800), ("ψ", 700), ("χ", 600),
                ("φ", 500), ("υ", 400), ("τ", 300), ("σ", 200), ("ρ", 100),
                ("ϟ", 90), ("π", 80), ("ο", 70), ("ξ", 60), ("ν", 50), ("μ", 40),
                ("λ", 30), ("κ", 20), ("ι", 10), ("θ", 9), ("η", 8), ("ζ", 7),
                ("στ", 6), ("ε", 5), ("δ", 4), ("γ", 3), ("β", 2), ("α", 1),
                ("𐆊", 0),
            ])
        case .upperGreek:
            return .additive([
                ("͵Θ", 9000), ("͵Η", 8000), ("͵Ζ", 7000), ("͵Ϛ", 6000),
                ("͵Ε", 5000), ("͵Δ", 4000), ("͵Γ", 3000), ("͵Β", 2000),
                ("͵Α", 1000), ("Ϡ", 900), ("Ω", 800), ("Ψ", 700), ("Χ", 600),
                ("Φ", 500), ("Υ", 400), ("Τ", 300), ("Σ", 200), ("Ρ", 100),
                ("Ϟ", 90), ("Π", 80), ("Ο", 70), ("Ξ", 60), ("Ν", 50), ("Μ", 40),
                ("Λ", 30), ("Κ", 20), ("Ι", 10), ("Θ", 9), ("Η", 8), ("Ζ", 7),
                ("ΣΤ", 6), ("Ε", 5), ("Δ", 4), ("Γ", 3), ("Β", 2), ("Α", 1),
                ("𐆊", 0),
            ])
        case .lowerArmenian:
            return .additive([
                ("ք", 9000), ("փ", 8000), ("ւ", 7000), ("ց", 6000), ("ր", 5000),
                ("տ", 4000), ("վ", 3000), ("ս", 2000), ("ռ", 1000), ("ջ", 900),
                ("պ", 800), ("չ", 700), ("ո", 600), ("շ", 500), ("ն", 400),
                ("յ", 300), ("մ", 200), ("ճ", 100), ("ղ", 90), ("ձ", 80),
                ("հ", 70), ("կ", 60), ("ծ", 50), ("խ", 40), ("լ", 30), ("ի", 20),
                ("ժ", 10), ("թ", 9), ("ը", 8), ("է", 7), ("զ", 6), ("ե", 5),
                ("դ", 4), ("գ", 3), ("բ", 2), ("ա", 1),
            ])
        case .upperArmenian:
            return .additive([
                ("Ք", 9000), ("Փ", 8000), ("Ւ", 7000), ("Ց", 6000), ("Ր", 5000),
                ("Տ", 4000), ("Վ", 3000), ("Ս", 2000), ("Ռ", 1000), ("Ջ", 900),
                ("Պ", 800), ("Չ", 700), ("Ո", 600), ("Շ", 500), ("Ն", 400),
                ("Յ", 300), ("Մ", 200), ("Ճ", 100), ("Ղ", 90), ("Ձ", 80),
                ("Հ", 70), ("Կ", 60), ("Ծ", 50), ("Խ", 40), ("Լ", 30), ("Ի", 20),
                ("Ժ", 10), ("Թ", 9), ("Ը", 8), ("Է", 7), ("Զ", 6), ("Ե", 5),
                ("Դ", 4), ("Գ", 3), ("Բ", 2), ("Ա", 1),
            ])
        case .hebrew:
            return .additive([
                ("ת", 400), ("ש", 300), ("ר", 200), ("ק", 100), ("צ", 90),
                ("פ", 80), ("ע", 70), ("ס", 60), ("נ", 50), ("מ", 40), ("ל", 30),
                ("כ", 20), ("יט", 19), ("יח", 18), ("יז", 17), ("טז", 16),
                ("טו", 15), ("י", 10), ("ט", 9), ("ח", 8), ("ז", 7), ("ו", 6),
                ("ה", 5), ("ד", 4), ("ג", 3), ("ב", 2), ("א", 1),
            ])
        case .lowerSimplifiedChinese:
            return .chinese(.simple, .lower)
        case .upperSimplifiedChinese:
            return .chinese(.simple, .upper)
        case .lowerTraditionalChinese:
            return .chinese(.traditional, .lower)
        case .upperTraditionalChinese:
            return .chinese(.traditional, .upper)
        case .hiraganaAiueo:
            return .bijective([
                "あ", "い", "う", "え", "お", "か", "き", "く", "け", "こ", "さ", "し",
                "す", "せ", "そ", "た", "ち", "つ", "て", "と", "な", "に", "ぬ", "ね",
                "の", "は", "ひ", "ふ", "へ", "ほ", "ま", "み", "む", "め", "も", "や",
                "ゆ", "よ", "ら", "り", "る", "れ", "ろ", "わ", "を", "ん",
            ])
        case .hiraganaIroha:
            return .bijective([
                "い", "ろ", "は", "に", "ほ", "へ", "と", "ち", "り", "ぬ", "る", "を",
                "わ", "か", "よ", "た", "れ", "そ", "つ", "ね", "な", "ら", "む", "う",
                "ゐ", "の", "お", "く", "や", "ま", "け", "ふ", "こ", "え", "て", "あ",
                "さ", "き", "ゆ", "め", "み", "し", "ゑ", "ひ", "も", "せ", "す",
            ])
        case .katakanaAiueo:
            return .bijective([
                "ア", "イ", "ウ", "エ", "オ", "カ", "キ", "ク", "ケ", "コ", "サ", "シ",
                "ス", "セ", "ソ", "タ", "チ", "ツ", "テ", "ト", "ナ", "ニ", "ヌ", "ネ",
                "ノ", "ハ", "ヒ", "フ", "ヘ", "ホ", "マ", "ミ", "ム", "メ", "モ", "ヤ",
                "ユ", "ヨ", "ラ", "リ", "ル", "レ", "ロ", "ワ", "ヲ", "ン",
            ])
        case .katakanaIroha:
            return .bijective([
                "イ", "ロ", "ハ", "ニ", "ホ", "ヘ", "ト", "チ", "リ", "ヌ", "ル", "ヲ",
                "ワ", "カ", "ヨ", "タ", "レ", "ソ", "ツ", "ネ", "ナ", "ラ", "ム", "ウ",
                "ヰ", "ノ", "オ", "ク", "ヤ", "マ", "ケ", "フ", "コ", "エ", "テ", "ア",
                "サ", "キ", "ユ", "メ", "ミ", "シ", "ヱ", "ヒ", "モ", "セ", "ス",
            ])
        case .koreanJamo:
            return .bijective([
                "ㄱ", "ㄴ", "ㄷ", "ㄹ", "ㅁ", "ㅂ", "ㅅ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ",
                "ㅍ", "ㅎ",
            ])
        case .koreanSyllable:
            return .bijective([
                "가", "나", "다", "라", "마", "바", "사", "아", "자", "차", "카", "타",
                "파", "하",
            ])
        case .easternArabic:
            return .positional(["٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"])
        case .arabicAbjad:
            return .bijective([
                "أ", "ب", "ج", "د", "ه‍", "و", "ز", "ح", "ط", "ي", "ك", "ل", "م", "ن",
                "س", "ع", "ف", "ص", "ق", "ر", "ش", "ت", "ث", "خ", "ذ", "ض", "ظ", "غ",
            ])
        case .persian:
            return .positional(["۰", "۱", "۲", "۳", "۴", "۵", "۶", "۷", "۸", "۹"])
        case .devanagari:
            return .positional(["०", "१", "२", "३", "४", "५", "६", "७", "८", "९"])
        case .tibetan:
            return .positional(["༠", "༡", "༢", "༣", "༤", "༥", "༦", "༧", "༨", "༩"])
        case .bengali:
            return .positional(["০", "১", "২", "৩", "৪", "৫", "৬", "৭", "৮", "৯"])
        case .bengaliLetters:
            return .bijective([
                "ক", "খ", "গ", "ঘ", "ঙ", "চ", "ছ", "জ", "ঝ", "ঞ", "ট", "ঠ", "ড", "ঢ",
                "ণ", "ত", "থ", "দ", "ধ", "ন", "প", "ফ", "ব", "ভ", "ম", "য", "র", "ল",
                "শ", "ষ", "স", "হ",
            ])
        case .symbols:
            return .symbolic(["*", "†", "‡", "§", "¶", "‖"])
        }
    }

    /// Try to represent a number in this named system.
    /// Convenience for `system.represent` (`NamedNumeralSystem::system().represent`).
    public func represent(_ number: UInt64) -> Result<String, RepresentationError> {
        system.represent(number)
    }
}

/// A numeral system of one of multiple predefined kinds.
/// Port of `NumeralSystem` in codex.
public enum NumeralSystem: Sendable {
    /// Big-endian positional notation.
    case positional([String])
    /// Big-endian bijective numeration.
    case bijective([String])
    /// Additive sign-value notation, numerals by decreasing value.
    case additive([(String, UInt64)])
    /// Repeating symbols.
    case symbolic([String])
    /// Fixed set of symbols for the first non-negative integers.
    case fixed([String])
    /// Fixed set of symbols for the first positive integers.
    case zerolessFixed([String])
    /// Chinese numerals.
    case chinese(ChineseVariant, ChineseCase)

    /// Try to represent a number in this numeral system.
    /// Port of `NumeralSystem::represent`.
    public func represent(_ number: UInt64) -> Result<String, RepresentationError> {
        switch self {
        case .positional, .chinese:
            break
        case .bijective, .symbolic:
            if number == 0 { return .failure(.zero) }
        case let .additive(numerals):
            if number == 0, numerals.last?.1 != 0 { return .failure(.zero) }
        case let .fixed(symbols):
            if number >= UInt64(symbols.count) { return .failure(.tooLarge) }
        case let .zerolessFixed(symbols):
            if number == 0 { return .failure(.zero) }
            if number > UInt64(symbols.count) { return .failure(.tooLarge) }
        }
        return .success(render(number))
    }

    /// Render a number known to be representable (the `Display` impl).
    private func render(_ number: UInt64) -> String {
        switch self {
        case let .positional(digits):
            var n = number
            if n == 0 { return digits[0] }
            let radix = UInt64(digits.count)
            var size = ilog(n, radix) + 1
            var msdPlace = pow64(radix, UInt64(size - 1))
            var out = ""
            while size > 0 {
                let msd = n / msdPlace
                out += digits[Int(msd)]
                n -= msd * msdPlace
                msdPlace /= radix
                size -= 1
            }
            return out

        case let .bijective(digits):
            var n = number
            precondition(n != 0)
            let radix = UInt64(digits.count)
            // Number of digits when representing `n` in this system.
            // `(n + 1) * (radix - 1)` wraps for huge n like Rust release
            // arithmetic.
            let size = ilog((n &+ 1) &* (radix &- 1), radix)
            n = n &- ((pow64(radix, UInt64(size)) &- 1) / (radix &- 1))
            var msdPlace = pow64(radix, UInt64(size - 1))
            var out = ""
            var remaining = size
            while remaining > 0 {
                let msd = n / msdPlace
                out += digits[Int(msd)]
                n -= msd * msdPlace
                msdPlace /= radix
                remaining -= 1
            }
            return out

        case let .additive(numerals):
            var n = number
            if n == 0 {
                if let last = numerals.last, last.1 == 0 { return last.0 }
                preconditionFailure()
            }
            var out = ""
            for (numeral, weight) in numerals {
                if weight == 0 || weight > n { continue }
                let reps = n / weight
                for _ in 0..<reps { out += numeral }
                n -= weight * reps
            }
            return out

        case let .symbolic(symbols):
            let count = UInt64(symbols.count)
            var out = ""
            var reps = number / count + (number % count == 0 ? 0 : 1)
            while reps > 0 {
                out += symbols[Int((number - 1) % count)]
                reps -= 1
            }
            return out

        case let .fixed(symbols):
            return symbols[Int(number)]

        case let .zerolessFixed(symbols):
            return symbols[Int(number - 1)]

        case let .chinese(variant, chineseCase):
            return chineseNumberToString(variant: variant, chineseCase: chineseCase,
                                        number: number)
        }
    }
}

/// `u64::ilog` equivalent: floor(log_base(n)) for n >= 1.
private func ilog(_ n: UInt64, _ base: UInt64) -> Int {
    var result = 0
    var m = n
    while m >= base {
        m /= base
        result += 1
    }
    return result
}

/// Wrapping `pow` — matches Rust release-mode `u64::pow` overflow behavior.
private func pow64(_ base: UInt64, _ exp: UInt64) -> UInt64 {
    var result: UInt64 = 1
    var e = exp
    var b = base
    while e > 0 {
        if e & 1 == 1 { result = result &* b }
        b = b &* b
        e >>= 1
    }
    return result
}

/// Chinese numeral variant. Port of `ChineseVariant` in `chinese-number`.
public enum ChineseVariant: Sendable, Hashable {
    case simple
    case traditional
}

/// Chinese numeral case (financial/upper vs everyday/lower).
/// Port of `ChineseCase` in `chinese-number`.
public enum ChineseCase: Sendable, Hashable {
    case upper
    case lower
}

// MARK: - Chinese numerals
// Port of `chinese-number`'s `number_to_chinese` ten-thousand path:
// `from_u64_to_chinese_ten_thousand` → `unsigned_integer_to_chinese_ten_thousand`
// + `unsigned_integer_to_chinese_low`, with the `ChineseNumber`/`ChineseExponent`
// digit tables.

// Port of `ChineseNumber::to_str` (ordinals 零一二三四五六七八九十).
private func chineseDigit(_ ordinal: Int, variant: ChineseVariant,
                          chineseCase: ChineseCase) -> String {
    if chineseCase == .lower {
        return ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"][ordinal]
    }
    switch ordinal {
    case 0: return "零"
    case 1: return "壹"
    case 2: return variant == .traditional ? "貳" : "贰"
    case 3: return variant == .traditional ? "參" : "叁"
    case 4: return "肆"
    case 5: return "伍"
    case 6: return variant == .traditional ? "陸" : "陆"
    case 7: return "柒"
    case 8: return "捌"
    case 9: return "玖"
    case 10: return "拾"
    default: preconditionFailure()
    }
}

// Port of `ChineseExponent::to_str` (ordinals 分角個十百千萬億兆京垓秭穰溝澗正載極).
private func chineseExponent(_ ordinal: Int, variant: ChineseVariant,
                             chineseCase: ChineseCase) -> String {
    switch ordinal {
    case 0: return "分"
    case 1: return "角"
    case 2: return variant == .traditional ? "個" : "个"
    case 3: return chineseCase == .upper ? "拾" : "十"
    case 4: return chineseCase == .upper ? "佰" : "百"
    case 5: return chineseCase == .upper ? "仟" : "千"
    case 6: return variant == .traditional ? "萬" : "万"
    case 7: return variant == .traditional ? "億" : "亿"
    case 8: return "兆"
    case 9: return "京"
    case 10: return "垓"
    case 11: return "秭"
    case 12: return "穰"
    case 13: return variant == .traditional ? "溝" : "沟"
    case 14: return variant == .traditional ? "澗" : "涧"
    case 15: return "正"
    case 16: return variant == .traditional ? "載" : "载"
    case 17: return variant == .traditional ? "極" : "极"
    default: preconditionFailure()
    }
}

/// `from_u64_to_chinese_ten_thousand` — 万進 (ten-thousand) grouping.
private func chineseNumberToString(variant: ChineseVariant,
                                   chineseCase: ChineseCase,
                                   number: UInt64) -> String {
    chineseIntegerToString(variant: variant, chineseCase: chineseCase,
                           dependent: false, value: UInt64(number))
}

private func chineseIntegerToString(variant: ChineseVariant,
                                    chineseCase: ChineseCase,
                                    dependent: Bool,
                                    value: UInt64) -> String {
    // `unsigned_integer_to_chinese_ten_thousand`.
    var value = value
    var lowerD = value % 10000
    value /= 10000
    var hasMore = value > 0

    var s = ""
    if lowerD > 0 {
        s = chineseLowToString(variant: variant, chineseCase: chineseCase,
                               dependent: dependent || hasMore, value: lowerD)
    } else if value == 0 {
        return chineseDigit(0, variant: variant, chineseCase: chineseCase)
    }

    if !hasMore { return s }

    var i = 6 // ChineseExponent::萬 ordinal.
    while true {
        let d = value % 10000
        value /= 10000
        hasMore = value > 0

        if d > 0 {
            if lowerD < 1000 && !s.isEmpty {
                s.insert(contentsOf: chineseDigit(0, variant: variant,
                                     chineseCase: chineseCase), at: s.startIndex)
            }
            s.insert(contentsOf: chineseExponent(i, variant: variant,
                                     chineseCase: chineseCase), at: s.startIndex)
            let low = chineseLowToString(variant: variant, chineseCase: chineseCase,
                                         dependent: dependent || hasMore, value: d)
            s.insert(contentsOf: low, at: s.startIndex)
        }

        if !hasMore { break }
        lowerD = d
        i += 1
    }
    return s
}

/// `unsigned_integer_to_chinese_low` — for values < 10000.
private func chineseLowToString(variant: ChineseVariant,
                                chineseCase: ChineseCase,
                                dependent: Bool,
                                value: UInt64) -> String {
    var value = value
    var s = ""

    var lowerD = Int(value % 10)
    value /= 10

    if lowerD > 0 {
        s += chineseDigit(lowerD, variant: variant, chineseCase: chineseCase)
    } else if value == 0 {
        return chineseDigit(0, variant: variant, chineseCase: chineseCase)
    }

    let d = Int(value % 10)
    value /= 10

    if d > 0 {
        s.insert(contentsOf: chineseExponent(3, variant: variant, // 十
                                 chineseCase: chineseCase), at: s.startIndex)
        if value > 0 || dependent || d > 1 {
            s.insert(contentsOf: chineseDigit(d, variant: variant,
                                  chineseCase: chineseCase), at: s.startIndex)
        }
    }

    if value == 0 { return s }

    lowerD = d
    var i = 4 // ChineseExponent::百 ordinal.

    while true {
        let d = Int(value % 10)
        value /= 10

        if d > 0 {
            if lowerD < 1 && !s.isEmpty {
                s.insert(contentsOf: chineseDigit(0, variant: variant,
                                     chineseCase: chineseCase), at: s.startIndex)
            }
            s.insert(contentsOf: chineseExponent(i, variant: variant,
                                     chineseCase: chineseCase), at: s.startIndex)
            s.insert(contentsOf: chineseDigit(d, variant: variant,
                                  chineseCase: chineseCase), at: s.startIndex)
        }

        if value == 0 { break }
        lowerD = d
        i += 1
    }
    return s
}
