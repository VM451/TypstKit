import Foundation
import Testing
import TypstSyntax
@testable import TypstLibrary

/// Tests for the codex numeral-system port and `Numbering`/`NumberingPattern`
/// from upstream `model/numbering.rs`.
@Suite("Numbering")
struct NumberingTests {
    private func rep(_ system: NamedNumeralSystem, _ n: UInt64) -> String? {
        try? system.represent(n).get()
    }

    // MARK: - numeral systems (upstream codex test vectors)

    @Test func arabic() {
        for n in 0...11 {
            #expect(rep(.arabic, UInt64(n)) == "\(n)")
        }
        #expect(rep(.arabic, 12345) == "12345")
    }

    @Test func latin() {
        #expect(rep(.lowerLatin, 1) == "a")
        #expect(rep(.lowerLatin, 26) == "z")
        #expect(rep(.lowerLatin, 27) == "aa")
        #expect(rep(.lowerLatin, 28) == "ab")
        #expect(rep(.upperLatin, 1) == "A")
        #expect(rep(.upperLatin, 28) == "AB")
        #expect(rep(.lowerLatin, 0) == nil) // zero not representable
    }

    @Test func roman() {
        let expected = [
            "n", "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
            "xi", "xii", "xiii", "xiv", "xv", "xvi", "xvii", "xviii", "xix",
            "xx", "xxi", "xxii", "xxiii", "xxiv", "xxv", "xxvi", "xxvii",
            "xxviii", "xxix", "xxx", "xxxi", "xxxii", "xxxiii", "xxxiv",
            "xxxv", "xxxvi", "xxxvii", "xxxviii", "xxxix", "xl", "xli",
            "xlii", "xliii", "xliv", "xlv", "xlvi",
        ]
        for (n, want) in expected.enumerated() {
            #expect(rep(.lowerRoman, UInt64(n)) == want)
            #expect(rep(.upperRoman, UInt64(n)) == want.uppercased())
        }
    }

    @Test func greek() {
        #expect(rep(.lowerGreek, 0) == "𐆊")
        #expect(rep(.lowerGreek, 1) == "α")
        #expect(rep(.lowerGreek, 6) == "στ")
        #expect(rep(.upperGreek, 7) == "Ζ")
    }

    @Test func symbolic() {
        let sys = NumeralSystem.symbolic(["a", "b"])
        let expected = ["a", "b", "aa", "bb", "aaa", "bbb", "aaaa", "bbbb"]
        for (i, want) in expected.enumerated() {
            #expect((try? sys.represent(UInt64(i + 1)).get()) == want)
        }
        #expect((try? sys.represent(0).get()) == nil)
    }

    @Test func fixed() {
        let sys = NumeralSystem.fixed(["⓪", "①", "②"])
        #expect((try? sys.represent(0).get()) == "⓪")
        #expect((try? sys.represent(2).get()) == "②")
        #expect((try? sys.represent(3).get()) == nil)
        let zl = NumeralSystem.zerolessFixed(["⓵", "⓶"])
        #expect((try? zl.represent(1).get()) == "⓵")
        #expect((try? zl.represent(0).get()) == nil)
        #expect((try? zl.represent(3).get()) == nil)
    }

    @Test func circled() {
        #expect(rep(.circledArabic, 0) == "⓪")
        #expect(rep(.circledArabic, 10) == "⑩")
        #expect(rep(.doubleCircledArabic, 1) == "⓵")
        #expect(rep(.doubleCircledArabic, 10) == "⓾")
        #expect(rep(.doubleCircledArabic, 11) == nil)
    }

    @Test func chinese() {
        let lower = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九",
                     "十", "十一", "十二"]
        for (n, want) in lower.enumerated() {
            #expect(rep(.lowerSimplifiedChinese, UInt64(n)) == want)
            #expect(rep(.lowerTraditionalChinese, UInt64(n)) == want)
        }
        #expect(rep(.upperSimplifiedChinese, 0) == "零")
        #expect(rep(.upperSimplifiedChinese, 1) == "壹")
        #expect(rep(.upperSimplifiedChinese, 2) == "贰")
        #expect(rep(.upperSimplifiedChinese, 3) == "叁")
        #expect(rep(.upperSimplifiedChinese, 6) == "陆")
        #expect(rep(.upperSimplifiedChinese, 10) == "拾")
        #expect(rep(.upperSimplifiedChinese, 11) == "拾壹")
        #expect(rep(.upperSimplifiedChinese, 12) == "拾贰")
        #expect(rep(.upperTraditionalChinese, 2) == "貳")
        #expect(rep(.upperTraditionalChinese, 3) == "參")
        #expect(rep(.upperTraditionalChinese, 6) == "陸")
        #expect(rep(.upperTraditionalChinese, 12) == "拾貳")
        // Larger groupings exercise the ten-thousand path.
        #expect(rep(.lowerSimplifiedChinese, 10000) == "一万")
        #expect(rep(.lowerTraditionalChinese, 10000) == "一萬")
        #expect(rep(.lowerSimplifiedChinese, 100000000) == "一亿")
        #expect(rep(.lowerTraditionalChinese, 100000000) == "一億")
    }

    @Test func positionalNonLatin() {
        #expect(rep(.persian, 0) == "۰")
        #expect(rep(.persian, 11) == "۱۱")
        #expect(rep(.devanagari, 9) == "९")
        #expect(rep(.easternArabic, 10) == "١٠")
        #expect(rep(.tibetan, 11) == "༡༡")
        #expect(rep(.bengali, 11) == "১১")
    }

    @Test func lookup() {
        #expect(NamedNumeralSystem.fromName("roman") == .lowerRoman)
        #expect(NamedNumeralSystem.fromName("Roman") == .upperRoman)
        #expect(NamedNumeralSystem.fromName("chinese.simple") == .lowerSimplifiedChinese)
        #expect(NamedNumeralSystem.fromShorthand("i") == .lowerRoman)
        #expect(NamedNumeralSystem.fromShorthand("I") == .upperRoman)
        #expect(NamedNumeralSystem.fromShorthand("1") == .arabic)
        #expect(NamedNumeralSystem.fromShorthand("①") == .circledArabic)
        #expect(NamedNumeralSystem.fromName("bogus") == nil)
        // Shorthand equals the representation of one.
        for system in NamedNumeralSystem.allCases {
            if let s = system.shorthand {
                #expect(rep(system, 1) == s)
            }
        }
    }

    // MARK: - NumberingPattern

    @Test func patternParsing() throws {
        let p = try NumberingPattern(parsing: "1.1)")
        #expect(p.pieceCount == 2)
        #expect(p.pieces[0].prefix == "")
        #expect(p.pieces[0].system == .arabic)
        #expect(p.pieces[1].prefix == ".")
        #expect(p.pieces[1].system == .arabic)
        #expect(p.suffix == ")")
        #expect(p.description == "1.1)")

        do {
            _ = try NumberingPattern(parsing: "no symbols")
            Issue.record("expected parse failure")
        } catch {}
    }

    @Test func patternApply() throws {
        let p = try NumberingPattern(parsing: "1.1)")
        #expect(try p.apply(numbers: [1, 2]).get() == "1.2)")
        // More numbers than symbols: last piece repeats with its prefix.
        #expect(try p.apply(numbers: [1, 2, 3]).get() == "1.2.3)")

        let q = try NumberingPattern(parsing: "1)")
        #expect(try q.apply(numbers: [1, 2]).get() == "1)2)")

        let r = try NumberingPattern(parsing: "a.")
        #expect(try r.apply(numbers: [1, 2]).get() == "a.b.")

        let s = try NumberingPattern(parsing: "*")
        #expect(try s.apply(numbers: [1, 2, 3, 4, 5, 6, 7]).get()
                == "*†‡§¶‖**")
    }

    @Test func patternApplyZeroError() throws {
        let p = try! NumberingPattern(parsing: "a")
        // Latin cannot represent zero — pure apply returns an error.
        if case .success = p.apply(numbers: [0]) {
            Issue.record("expected failure for zero")
        }
        let arabic = try! NumberingPattern(parsing: "1")
        #expect(try arabic.apply(numbers: [0]).get() == "0")
    }

    @Test func patternTrimmed() throws {
        var p = try NumberingPattern(parsing: "(1)")
        p.trimmed = true
        #expect(try p.apply(numbers: [5]).get() == "5")
        // Overflow numbers still emit the last piece's prefix.
        #expect(try p.apply(numbers: [5, 6]).get() == "5(6")
    }

    @Test func patternCast() throws {
        let v = try NumberingPattern(parsing: "1.").intoValue()
        #expect(v == .str(Str("1.")))
        #expect(try NumberingPattern.fromValue(v).get()
                == NumberingPattern(parsing: "1."))
        #expect(NumberingPattern.castable(.str(Str("1."))))
        #expect(!NumberingPattern.castable(.str(Str("none"))))
    }

    // MARK: - numbering() func

    @Test func numberingFunc() throws {
        let harness = FuncHarness()
        // Resolve `numbering` through the global scope — also verifies
        // registration in `defineModelElements`.
        guard let binding = harness.world.library.value.scope.get("numbering"),
              case let .function(f) = binding.value,
              let data = f.nativeData else {
            Issue.record("numbering not registered"); return
        }
        func call(_ args: [Value]) throws -> Value {
            try harness.unwrap(harness.call(data, harness.args(args)))
        }
        #expect(try call([.str(Str("1.")), .int(1), .int(2), .int(3)])
                == .str(Str("1.2.3.")))
        #expect(try call([.str(Str("I")), .int(4)]) == .str(Str("IV")))
        #expect(try call([.str(Str("1.1)")), .int(1), .int(2), .int(3)])
                == .str(Str("1.2.3)")))
        // Missing numbering argument errors.
        if case .success = harness.call(data, harness.args([])) {
            Issue.record("expected failure for missing numbering")
        }
    }
}
