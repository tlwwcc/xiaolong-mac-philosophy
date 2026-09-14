import Foundation
import XCTest
@testable import YoumuFeature

@MainActor
final class LocalTranslationRoutingTests: XCTestCase {
    func testIsolatedInterfaceLabelsUseTheirActionMeaning() {
        let pair = LocalTranslationRouting.Pair(sourceIdentifier: "en", targetIdentifier: "zh-Hans")
        for (source, target) in [("Save", "保存"), ("Copy", "复制"), ("Open", "打开"),
                                 ("View", "查看"), ("Play", "播放"), ("  SAVE… ", "  保存… ")] {
            XCTAssertEqual(LocalTranslationRouting.chineseInterfaceTranslation(source, pair: pair), target)
        }
        XCTAssertEqual(LocalTranslationRouting.chineseInterfaceTranslation("Copy...", pair:
            .init(sourceIdentifier: "en", targetIdentifier: "zh-Hant")), "複製...")
    }

    func testInterfaceTerminologyDoesNotRewriteSentencesOrOtherLanguagePairs() {
        let pair = LocalTranslationRouting.Pair(sourceIdentifier: "en", targetIdentifier: "zh-Hans")
        for source in ["Save this document.", "Open air", "Copy 2", "Reopen", "Bonjour", "AI"] {
            XCTAssertNil(LocalTranslationRouting.chineseInterfaceTranslation(source, pair: pair), source)
        }
        for pair in [LocalTranslationRouting.Pair(sourceIdentifier: "fr", targetIdentifier: "zh-Hans"),
                     .init(sourceIdentifier: "en", targetIdentifier: "ja"),
                     .init(sourceIdentifier: "en", targetIdentifier: "en")] {
            XCTAssertNil(LocalTranslationRouting.chineseInterfaceTranslation("Save", pair: pair))
        }
    }

    func testEnglishInterfaceWordsAndAcronymsNeverAskSystemToDetectLanguage() {
        for text in ["OK", "AI", "Hi", "Save", "Copy", "Open", "PDF", "RAM", "CPU 66%", "Settings", "Download"] {
            let pair = LocalTranslationRouting.pair(for: [text], targetLanguage: .zhHans)
            XCTAssertEqual(pair?.sourceIdentifier, "en", text)
            XCTAssertEqual(pair?.targetIdentifier, "zh-Hans", text)
        }
    }

    func testMixedOCRIsPartitionedByLanguageWithoutLosingIndices() {
        let texts = ["OK", "使用", "Save", "123 / 45%", "こんにちは", "Copy", "图片翻译", "안녕하세요"]
        let groups = LocalTranslationRouting.groups(for: texts, targetLanguage: .zhHans)
        XCTAssertEqual(groups.map(\.pair.sourceIdentifier), ["en", "ja", "ko"])
        XCTAssertEqual(groups.map(\.indices), [[0, 2, 5], [4], [7]])
        XCTAssertTrue(groups.allSatisfy { $0.pair.targetIdentifier == "zh-Hans" })
    }

    func testClearForeignLanguageEvidenceIsNotForcedToEnglish() {
        for (text, source) in [("Bonjour", "fr"), ("Hola", "es"), ("Guten Tag", "de"),
                               ("こんにちは", "ja"), ("안녕하세요", "ko"), ("東京大阪", "ja")] {
            XCTAssertEqual(LocalTranslationRouting.pair(for: [text], targetLanguage: .zhHans)?.sourceIdentifier, source, text)
        }
    }

    func testSameLanguageAndNumbersDoNotEnterUnsupportedPairCheck() {
        XCTAssertTrue(LocalTranslationRouting.groups(for: ["Save", "Copy", "OK"], targetLanguage: .en).isEmpty)
        XCTAssertTrue(LocalTranslationRouting.groups(for: ["使用", "保存", "图片翻译", "42%"], targetLanguage: .zhHans).isEmpty)
        XCTAssertNil(LocalTranslationRouting.pair(for: ["42 / 100%", "⚙️"], targetLanguage: .zhHans))
    }

    func testAutomaticDirectionIsExplicitAndDoesNotTranslateLanguageIntoItself() {
        XCTAssertEqual(LocalTranslationRouting.pair(for: ["Save"], targetLanguage: .auto,
            preferredTargetIdentifier: "zh_CN")?.targetIdentifier, "zh-Hans")
        XCTAssertEqual(LocalTranslationRouting.pair(for: ["图片翻译"], targetLanguage: .auto,
            preferredTargetIdentifier: "zh-Hans-CN")?.targetIdentifier, "en")
        XCTAssertEqual(LocalTranslationRouting.pair(for: ["Save"], targetLanguage: .auto,
            preferredTargetIdentifier: "en-US")?.targetIdentifier, "zh-Hans")
        XCTAssertEqual(LocalTranslationRouting.pair(for: ["こんにちは"], targetLanguage: .auto,
            preferredTargetIdentifier: "zh-TW")?.targetIdentifier, "zh-Hant")
    }

    func testChineseScriptVariantsConvertWithoutRequestingUnsupportedApplePair() {
        let pair = LocalTranslationRouting.Pair(sourceIdentifier: "zh-Hant", targetIdentifier: "zh-Hans")
        XCTAssertEqual(LocalTranslationRouting.convertChineseVariant("繁體中文與設定", pair: pair), "繁体中文与设定")
        XCTAssertEqual(LocalTranslationRouting.convertChineseVariant("简体中文与设置", pair:
            .init(sourceIdentifier: "zh-Hans", targetIdentifier: "zh-Hant")), "簡體中文與設置")
        XCTAssertNil(LocalTranslationRouting.convertChineseVariant("Save", pair:
            .init(sourceIdentifier: "en", targetIdentifier: "zh-Hans")))
    }

    func testGroupedResultsReturnToOriginalOCRSlots() async throws {
        let texts = ["Copy", "使用", "こんにちは", "Save", "45%"]
        var called: [[String]] = []
        let outcome = try await LocalTranslationBatchExecutor.run(texts: texts,
            groups: LocalTranslationRouting.groups(for: texts, targetLanguage: .zhHans)) { pair, input in
                called.append(input)
                return pair.sourceIdentifier == "en" ? ["复制", "保存"] : ["你好"]
            }
        XCTAssertEqual(called, [["Copy", "Save"], ["こんにちは"]])
        XCTAssertEqual(outcome.blocks.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(outcome.blocks.map(\.text), ["复制", "使用", "你好", "保存", "45%"])
        XCTAssertFalse(outcome.blocks.contains(where: \.failed))
        XCTAssertNil(outcome.firstError)
    }

    func testOneUnsupportedLanguagePreservesOtherSuccessfulBlocks() async throws {
        let texts = ["Copy", "こんにちは", "Save"]
        let outcome = try await LocalTranslationBatchExecutor.run(texts: texts,
            groups: LocalTranslationRouting.groups(for: texts, targetLanguage: .zhHans)) { pair, _ in
                if pair.sourceIdentifier == "ja" { throw AppleLocalTranslationError.unsupportedLanguages(source: "ja", target: "zh-Hans") }
                return ["复制", "保存"]
            }
        XCTAssertEqual(outcome.blocks.map(\.text), ["复制", "こんにちは", "保存"])
        XCTAssertEqual(outcome.blocks.map(\.failed), [false, true, false])
        XCTAssertEqual(outcome.successfulGroups, 1)
        XCTAssertNotNil(outcome.firstError)
    }

    func testIncompleteResponsesCannotShiftLaterBlocksOrClaimSuccess() async throws {
        let texts = ["Copy", "こんにちは", "Save"]
        let outcome = try await LocalTranslationBatchExecutor.run(texts: texts,
            groups: LocalTranslationRouting.groups(for: texts, targetLanguage: .zhHans)) { pair, _ in
                pair.sourceIdentifier == "en" ? ["只有一个"] : ["你好"]
            }
        XCTAssertEqual(outcome.blocks.map(\.text), ["Copy", "你好", "Save"])
        XCTAssertEqual(outcome.blocks.map(\.failed), [true, false, true])
    }

    func testCancellationDoesNotStartNextLanguageOrReturnPartialSuccess() async throws {
        let texts = ["Copy", "こんにちは"]
        var calls = 0
        do {
            _ = try await LocalTranslationBatchExecutor.run(texts: texts,
                groups: LocalTranslationRouting.groups(for: texts, targetLanguage: .zhHans)) { _, _ in
                    calls += 1
                    throw CancellationError()
                }
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }
}
