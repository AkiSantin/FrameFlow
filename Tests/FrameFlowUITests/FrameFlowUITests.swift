import XCTest
@testable import FrameFlowUI

final class FrameFlowUITests: XCTestCase {
    func testAllLocalizedTablesHaveIdenticalKeysAndPlaceholderSignatures() {
        let english = L10n.strings(language: .english)
        XCTAssertGreaterThan(english.count, 80)
        for language in [AppLanguagePreference.english, .traditionalChinese, .japanese] {
            let table = L10n.strings(language: language)
            XCTAssertEqual(Set(table.keys), Set(english.keys), "Key mismatch for \(language.rawValue)")
            for key in english.keys {
                XCTAssertNotEqual(table[key], key, "Visible key leaked for \(language.rawValue): \(key)")
                XCTAssertEqual(
                    placeholderSignature(table[key] ?? ""),
                    placeholderSignature(english[key] ?? ""),
                    "Placeholder mismatch for \(language.rawValue): \(key)"
                )
            }
        }
    }

    func testExplicitLanguagesResolveExpectedStrings() {
        XCTAssertEqual(L10n.string("drop.title", language: .english), "Drop Videos or Folders")
        XCTAssertEqual(L10n.string("drop.title", language: .traditionalChinese), "拖入影片或資料夾")
        XCTAssertEqual(L10n.string("drop.title", language: .japanese), "動画またはフォルダをドロップ")
    }

    func testSystemLanguageFallbackDoesNotMapSimplifiedChineseToTraditional() {
        XCTAssertEqual(
            AppLanguagePreference.effectiveResourceCode(preferredLanguages: ["zh-Hans-CN"]),
            "en"
        )
        XCTAssertEqual(
            AppLanguagePreference.effectiveResourceCode(preferredLanguages: ["zh-Hant-TW"]),
            "zh-Hant"
        )
        XCTAssertEqual(
            AppLanguagePreference.effectiveResourceCode(preferredLanguages: ["ja-JP"]),
            "ja"
        )
        XCTAssertEqual(
            AppLanguagePreference.effectiveResourceCode(preferredLanguages: ["fr-FR"]),
            "en"
        )
    }

    private func placeholderSignature(_ value: String) -> [String] {
        let pattern = "%(?:[0-9]+\\$)?[-+0-9.]*[a-zA-Z@]"
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }
}



