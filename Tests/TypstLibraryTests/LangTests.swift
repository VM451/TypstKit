import Foundation
import Testing
import TypstSyntax
import TypstUtils
@testable import TypstLibrary

/// Tests for `Locale`/`Lang`/`TextRegion`/`WritingScript` and the
/// `localizedStr` machinery from upstream `text/lang.rs`, including the
/// embedded translation bundles in `Translations.swift`.
@Suite("Lang")
struct LangTests {
    // MARK: - Lang parsing

    @Test func langParsesValidCodes() {
        #expect(Lang(parsing: "en") == .ENGLISH)
        #expect(Lang(parsing: "fr") == .FRENCH)
        #expect(Lang(parsing: "und") == .UNKNOWN_LANGUAGE)
        // Three-letter codes are fine even when a two-letter code exists.
        #expect(Lang(parsing: "deu") != nil)
        #expect(Lang(parsing: "deu") != .GERMAN)
    }

    @Test func langNormalizesToLowercase() {
        #expect(Lang(parsing: "EN") == .ENGLISH)
        #expect(Lang(parsing: "En") == .ENGLISH)
        #expect(Lang(parsing: "DEU") == Lang(parsing: "deu"))
    }

    @Test func langAcceptsUnvalidatedAscii() {
        // Upstream performs no validation against the constant table.
        let xy = Lang(parsing: "xy")
        #expect(xy != nil)
        #expect(xy?.asStr == "xy")
        // Even non-letter ASCII (digits) parses, mirroring upstream.
        #expect(Lang(parsing: "12") != nil)
    }

    @Test func langRejectsInvalidCodes() {
        #expect(Lang(parsing: "") == nil)
        #expect(Lang(parsing: "e") == nil)
        #expect(Lang(parsing: "engx") == nil) // four letters
        #expect(Lang(parsing: "é") == nil) // non-ASCII, two UTF-8 bytes
        #expect(Lang(parsing: "日本") == nil)
    }

    @Test func langOrderingMatchesPaddedByteOrder() {
        // `en` pads to `en ` and space sorts before any letter.
        #expect(Lang(parsing: "en")! < Lang(parsing: "enu")!)
        #expect(Lang.AFAR < Lang.ABKHAZIAN) // "aa" < "ab" by code, not by name
        #expect(!(Lang.ENGLISH < Lang.ENGLISH))
    }

    // MARK: - TextRegion parsing

    @Test func regionParsesAndUppercases() {
        #expect(TextRegion(parsing: "us")?.asStr == "US")
        #expect(TextRegion(parsing: "US")?.asStr == "US")
        #expect(TextRegion(parsing: "uS")?.asStr == "US")
    }

    @Test func regionRejectsInvalidCodes() {
        #expect(TextRegion(parsing: "u") == nil)
        #expect(TextRegion(parsing: "usa") == nil)
        #expect(TextRegion(parsing: "") == nil)
        #expect(TextRegion(parsing: "éé") == nil)
    }

    // MARK: - WritingScript parsing

    @Test func writingScriptParsesAndLowercases() {
        #expect(WritingScript(parsing: "latn")?.asStr == "latn")
        #expect(WritingScript(parsing: "LATN")?.asStr == "latn")
        #expect(WritingScript(parsing: "math")?.asStr == "math")
        #expect(WritingScript(parsing: "abc")?.asStr == "abc")
    }

    @Test func writingScriptRejectsInvalidCodes() {
        #expect(WritingScript(parsing: "la") == nil)
        #expect(WritingScript(parsing: "latin") == nil)
        #expect(WritingScript(parsing: "") == nil)
    }

    @Test func writingScriptAsBytesIsSpacePadded() {
        #expect(WritingScript(parsing: "latn")?.asBytes == Array("latn".utf8))
        #expect(WritingScript(parsing: "abc")?.asBytes == Array("abc ".utf8))
    }

    // MARK: - Direction

    @Test func directionIsRtlForExactlyTheElevenUpstreamLanguages() {
        let rtlCodes = ["ar", "dv", "fa", "he", "ks", "pa", "ps", "sd", "ug", "ur", "yi"]
        #expect(rtlCodes.count == 11)
        for code in rtlCodes {
            #expect(Lang(parsing: code)?.dir() == .rtl, "\(code) should be RTL")
        }
        #expect(Lang.ARABIC.dir() == .rtl)
        #expect(Lang.YIDDISH.dir() == .rtl)
    }

    @Test func directionIsLtrOtherwise() {
        #expect(Lang.ENGLISH.dir() == .ltr)
        #expect(Lang.GERMAN.dir() == .ltr)
        #expect(Lang.CHINESE.dir() == .ltr)
        #expect(Lang(parsing: "xy")?.dir() == .ltr)
    }

    // MARK: - Casts

    @Test func langCastFromString() {
        switch Lang.fromValue(.str(Str("de"))) {
        case let .success(lang): #expect(lang == .GERMAN)
        case let .failure(err): Issue.record("cast failed: \(err)")
        }
        #expect(Lang.castable(.str(Str("de"))))
        #expect(!Lang.castable(.str(Str("english"))))
        #expect(!Lang.castable(.int(1)))
    }

    @Test func langCastErrorHasExactMessage() {
        guard case let .failure(err) = Lang.fromValue(.str(Str("english"))) else {
            Issue.record("expected cast failure")
            return
        }
        #expect(err.message ==
            "expected two or three letter language code (ISO 639-1/2/3)")
        #expect(err.hints.isEmpty)
    }

    @Test func langCastHintForCombinedLanguageRegionTag() {
        guard case let .failure(err) = Lang.fromValue(.str(Str("en-US"))) else {
            Issue.record("expected cast failure")
            return
        }
        #expect(err.message ==
            "expected two or three letter language code (ISO 639-1/2/3)")
        #expect(err.hints == [
            "you should leave only \"en\" in the `lang` parameter and specify \"US\" in the `region` parameter",
        ])
    }

    @Test func langCastHintPreservesInputCase() {
        guard case let .failure(err) = Lang.fromValue(.str(Str("EN-us"))) else {
            Issue.record("expected cast failure")
            return
        }
        #expect(err.hints == [
            "you should leave only \"EN\" in the `lang` parameter and specify \"us\" in the `region` parameter",
        ])
    }

    @Test func langCastHintRequiresBothHalvesToParse() {
        // Region half too long → no hint.
        guard case let .failure(err) = Lang.fromValue(.str(Str("en-USA"))) else {
            Issue.record("expected cast failure")
            return
        }
        #expect(err.hints.isEmpty)
        // Lang half invalid → no hint.
        guard case let .failure(err2) = Lang.fromValue(.str(Str("e-US"))) else {
            Issue.record("expected cast failure")
            return
        }
        #expect(err2.hints.isEmpty)
    }

    @Test func langCastIntoValueRoundTrips() {
        #expect(Lang.ENGLISH.intoValue() == .str(Str("en")))
        #expect(Lang.UNKNOWN_LANGUAGE.intoValue() == .str(Str("und")))
    }

    @Test func regionCast() {
        switch TextRegion.fromValue(.str(Str("ch"))) {
        case let .success(region): #expect(region.asStr == "CH")
        case let .failure(err): Issue.record("cast failed: \(err)")
        }
        guard case let .failure(err) = TextRegion.fromValue(.str(Str("che"))) else {
            Issue.record("expected cast failure")
            return
        }
        #expect(err.message == "expected two letter region code (ISO 3166-1 alpha-2)")
        #expect(TextRegion(parsing: "ch")?.intoValue() == .str(Str("CH")))
    }

    @Test func writingScriptCast() {
        switch WritingScript.fromValue(.str(Str("Latn"))) {
        case let .success(script): #expect(script.asStr == "latn")
        case let .failure(err): Issue.record("cast failed: \(err)")
        }
        guard case let .failure(err) = WritingScript.fromValue(.str(Str("la"))) else {
            Issue.record("expected cast failure")
            return
        }
        #expect(err.message ==
            "expected three or four letter script code (ISO 15924 or 'math')")
    }

    // MARK: - Locale

    @Test func localeDefaultIsEnglishWithoutRegion() {
        #expect(Locale.DEFAULT == Locale(lang: .ENGLISH, region: nil))
    }

    @Test func rfc3066Formatting() {
        #expect(Locale.DEFAULT.rfc3066() == "en")
        let us = Locale(lang: .ENGLISH, region: TextRegion(parsing: "us"))
        #expect(us.rfc3066() == "en-US")
    }

    @Test func localeOrdering() {
        let plain = Locale(lang: .ENGLISH, region: nil)
        let us = Locale(lang: .ENGLISH, region: TextRegion(parsing: "US"))
        // A nil region sorts before any present region (upstream `Ord`).
        #expect(plain < us)
        #expect(!(us < plain))
        #expect(Locale(lang: .DANISH, region: nil) < plain)
    }

    // MARK: - Locale.getIn

    /// Build a style chain with one `TextElem` property.
    private func chain(_ field: UInt8, _ value: Value) -> StyleChain {
        let prop = LazyHash(Style.property(Property(
            elem: Element(TextElem.self),
            field: field,
            value: value
        )))
        return StyleChain(head: [prop][...])
    }

    @Test func getInDefaultsToEnglish() {
        #expect(Locale.getIn(StyleChain()) == Locale.DEFAULT)
    }

    @Test func getInReadsLangAndRegion() {
        let langChain = chain(1, .str(Str("de")))
        #expect(Locale.getIn(langChain).lang == .GERMAN)
        #expect(Locale.getIn(langChain).region == nil)

        let prop = { (field: UInt8, value: Value) in
            LazyHash(Style.property(Property(
                elem: Element(TextElem.self), field: field, value: value)))
        }
        let both = StyleChain(head: [
            prop(1, .str(Str("de"))),
            prop(2, .str(Str("ch"))),
        ][...])
        let locale = Locale.getIn(both)
        #expect(locale.lang == .GERMAN)
        #expect(locale.region?.asStr == "CH")
        #expect(locale.rfc3066() == "de-CH")
    }

    @Test func getInParsesLeniently() {
        // Unparseable tags fall back to the default instead of failing.
        let invalid = chain(1, .str(Str("not-a-language-tag")))
        #expect(Locale.getIn(invalid).lang == .ENGLISH)
        // `auto` and non-string values are ignored.
        let auto = chain(1, .auto)
        #expect(Locale.getIn(auto).lang == .ENGLISH)
        // Invalid region yields no region.
        let badRegion = chain(2, .str(Str("xxx")))
        #expect(Locale.getIn(badRegion).region == nil)
    }

    // MARK: - localizedStr

    @Test func localizedStrGerman() {
        #expect(localizedStr(lang: .GERMAN, region: nil, key: "figure") == "Abbildung")
        #expect(localizedStr(lang: .GERMAN, region: nil, key: "footnote") == "Fußnote")
    }

    @Test func localizedStrRegionOverride() {
        // fr-CA only defines `email = Courriel`.
        let ca = TextRegion(parsing: "CA")
        #expect(localizedStr(lang: .FRENCH, region: ca, key: "email") == "Courriel")
        // Region codes normalize: lowercase input hits the same bundle.
        let caLower = TextRegion(parsing: "ca")
        #expect(localizedStr(lang: .FRENCH, region: caLower, key: "email") == "Courriel")
    }

    @Test func localizedStrFallsBackPerKeyToLanguageBundle() {
        // `figure` is not in the fr-CA bundle, so the fr bundle wins.
        let ca = TextRegion(parsing: "CA")
        #expect(localizedStr(lang: .FRENCH, region: ca, key: "figure") == "Fig.")
        // pt-PT overrides `heading` but not `figure`.
        let pt = TextRegion(parsing: "PT")
        #expect(localizedStr(lang: .PORTUGUESE, region: pt, key: "heading") == "Secção")
        #expect(localizedStr(lang: .PORTUGUESE, region: pt, key: "figure") == "Figura")
    }

    @Test func localizedStrFallsBackPerKeyToEnglish() {
        // The af bundle comments out `equation` — per-key English fallback.
        let af = Lang(parsing: "af")!
        #expect(localizedStr(lang: af, region: nil, key: "figure") == "Figuur")
        #expect(localizedStr(lang: af, region: nil, key: "equation") == "Equation")
    }

    @Test func localizedStrMissingFileIsEmptyMap() {
        // No `xy` translation file exists — everything falls to English.
        let xy = Lang(parsing: "xy")!
        #expect(localizedStr(lang: xy, region: nil, key: "figure") == "Figure")
        // Same with a region: neither `xy-ZZ` nor `xy` exists.
        let zz = TextRegion(parsing: "ZZ")
        #expect(localizedStr(lang: xy, region: zz, key: "figure") == "Figure")
        // A valid language with an unbundled region: no `de-AT` file, so the
        // region bundle is empty and the `de` bundle still hits.
        let at = TextRegion(parsing: "AT")
        #expect(localizedStr(lang: .GERMAN, region: at, key: "figure") == "Abbildung")
    }

    @Test func localizedStrEnglishUltimateFallback() {
        #expect(localizedStr(lang: .ENGLISH, region: nil, key: "figure") == "Figure")
        #expect(localizedStr(lang: .ENGLISH, region: nil, key: "page") == "page")
    }

    // MARK: - Translation data

    @Test func translationDataHasAll100Files() {
        #expect(Translations.translationData.count == 100)
    }

    @Test func englishBundleDefinesAllElevenKeys() {
        let keys = ["figure", "table", "equation", "bibliography", "heading",
                    "outline", "raw", "page", "footnote", "email", "telephone"]
        for key in keys {
            // Would hit the precondition failure if English lacked the key.
            #expect(!localizedStr(lang: .ENGLISH, region: nil, key: key).isEmpty)
        }
        #expect(localizedStr(lang: .ENGLISH, region: nil, key: "heading") == "Section")
        #expect(localizedStr(lang: .ENGLISH, region: nil, key: "outline") == "Contents")
    }
}
