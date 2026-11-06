import Foundation
import Testing
@testable import YoumuFeature

@MainActor
@Suite(.serialized)
final class LocalTranslationRoutingTests {
    @Test
    func testIsolatedInterfaceLabelsUseTheirActionMeaning() {
        let pair = LocalTranslationRouting.Pair(sourceIdentifier: "en", targetIdentifier: "zh-Hans")
        for (source, target) in [("Save", "保存"), ("Copy", "复制"), ("Open", "打开"),
                                 ("View", "查看"), ("Play", "播放"), ("  SAVE… ", "  保存… ")] {
            #expect((LocalTranslationRouting.chineseInterfaceTranslation(source, pair: pair)) == (target))
        }
        #expect((LocalTranslationRouting.chineseInterfaceTranslation("Copy...", pair:
            .init(sourceIdentifier: "en", targetIdentifier: "zh-Hant"))) == ("複製..."))
    }

    @Test
    func testInterfaceTerminologyDoesNotRewriteSentencesOrOtherLanguagePairs() {
        let pair = LocalTranslationRouting.Pair(sourceIdentifier: "en", targetIdentifier: "zh-Hans")
        for source in ["Save this document.", "Open air", "Copy 2", "Reopen", "Bonjour", "AI"] {
            #expect((LocalTranslationRouting.chineseInterfaceTranslation(source, pair: pair)) == nil, Comment(rawValue: source))
        }
        for pair in [LocalTranslationRouting.Pair(sourceIdentifier: "fr", targetIdentifier: "zh-Hans"),
                     .init(sourceIdentifier: "en", targetIdentifier: "ja"),
                     .init(sourceIdentifier: "en", targetIdentifier: "en")] {
            #expect((LocalTranslationRouting.chineseInterfaceTranslation("Save", pair: pair)) == nil)
        }
    }

    @Test
    func testEnglishInterfaceWordsAndAcronymsNeverAskSystemToDetectLanguage() {
        for text in ["OK", "AI", "Hi", "Save", "Copy", "Open", "PDF", "RAM", "CPU 66%", "Settings", "Download"] {
            let pair = LocalTranslationRouting.pair(for: [text], targetLanguage: .zhHans)
            #expect((pair?.sourceIdentifier) == ("en"), Comment(rawValue: text))
            #expect((pair?.targetIdentifier) == ("zh-Hans"), Comment(rawValue: text))
        }
    }

    @Test
    func testMixedOCRIsPartitionedByLanguageWithoutLosingIndices() {
        let texts = ["OK", "使用", "Save", "123 / 45%", "こんにちは", "Copy", "图片翻译", "안녕하세요"]
        let groups = LocalTranslationRouting.groups(for: texts, targetLanguage: .zhHans)
        #expect((groups.map(\.pair.sourceIdentifier)) == (["en", "ja", "ko"]))
        #expect((groups.map(\.indices)) == ([[0, 2, 5], [4], [7]]))
        #expect(groups.allSatisfy { $0.pair.targetIdentifier == "zh-Hans" })
    }

    @Test
    func testClearForeignLanguageEvidenceIsNotForcedToEnglish() {
        for (text, source) in [("Bonjour", "fr"), ("Hola", "es"), ("Guten Tag", "de"),
                               ("こんにちは", "ja"), ("안녕하세요", "ko"), ("東京大阪", "ja")] {
            #expect((LocalTranslationRouting.pair(for: [text], targetLanguage: .zhHans)?.sourceIdentifier) == (source), Comment(rawValue: text))
        }
    }

    @Test
    func testSameLanguageAndNumbersDoNotEnterUnsupportedPairCheck() {
        #expect(LocalTranslationRouting.groups(for: ["Save", "Copy", "OK"], targetLanguage: .en).isEmpty)
        #expect(LocalTranslationRouting.groups(for: ["使用", "保存", "图片翻译", "42%"], targetLanguage: .zhHans).isEmpty)
        #expect((LocalTranslationRouting.pair(for: ["42 / 100%", "⚙️"], targetLanguage: .zhHans)) == nil)
    }

    @Test
    func testAutomaticDirectionIsExplicitAndDoesNotTranslateLanguageIntoItself() {
        #expect((LocalTranslationRouting.pair(for: ["Save"], targetLanguage: .auto,
            preferredTargetIdentifier: "zh_CN")?.targetIdentifier) == ("zh-Hans"))
        #expect((LocalTranslationRouting.pair(for: ["图片翻译"], targetLanguage: .auto,
            preferredTargetIdentifier: "zh-Hans-CN")?.targetIdentifier) == ("en"))
        #expect((LocalTranslationRouting.pair(for: ["Save"], targetLanguage: .auto,
            preferredTargetIdentifier: "en-US")?.targetIdentifier) == ("zh-Hans"))
        #expect((LocalTranslationRouting.pair(for: ["こんにちは"], targetLanguage: .auto,
            preferredTargetIdentifier: "zh-TW")?.targetIdentifier) == ("zh-Hant"))
    }

    @Test
    func testChineseScriptVariantsConvertWithoutRequestingUnsupportedApplePair() {
        let pair = LocalTranslationRouting.Pair(sourceIdentifier: "zh-Hant", targetIdentifier: "zh-Hans")
        #expect((LocalTranslationRouting.convertChineseVariant("繁體中文與設定", pair: pair)) == ("繁体中文与设定"))
        #expect((LocalTranslationRouting.convertChineseVariant("简体中文与设置", pair:
            .init(sourceIdentifier: "zh-Hans", targetIdentifier: "zh-Hant"))) == ("簡體中文與設置"))
        #expect((LocalTranslationRouting.convertChineseVariant("Save", pair:
            .init(sourceIdentifier: "en", targetIdentifier: "zh-Hans"))) == nil)
    }

    @Test
    func testGroupedResultsReturnToOriginalOCRSlots() async throws {
        let texts = ["Copy", "使用", "こんにちは", "Save", "45%"]
        var called: [[String]] = []
        let outcome = try await LocalTranslationBatchExecutor.run(texts: texts,
            groups: LocalTranslationRouting.groups(for: texts, targetLanguage: .zhHans)) { pair, input in
                called.append(input)
                return pair.sourceIdentifier == "en" ? ["复制", "保存"] : ["你好"]
            }
        #expect((called) == ([["Copy", "Save"], ["こんにちは"]]))
        #expect((outcome.blocks.map(\.index)) == ([0, 1, 2, 3, 4]))
        #expect((outcome.blocks.map(\.text)) == (["复制", "使用", "你好", "保存", "45%"]))
        let containsFailedBlock = outcome.blocks.contains(where: \.failed)
        #expect(!containsFailedBlock)
        #expect((outcome.firstError) == nil)
    }

    @Test
    func testOneUnsupportedLanguagePreservesOtherSuccessfulBlocks() async throws {
        let texts = ["Copy", "こんにちは", "Save"]
        let outcome = try await LocalTranslationBatchExecutor.run(texts: texts,
            groups: LocalTranslationRouting.groups(for: texts, targetLanguage: .zhHans)) { pair, _ in
                if pair.sourceIdentifier == "ja" { throw AppleLocalTranslationError.unsupportedLanguages(source: "ja", target: "zh-Hans") }
                return ["复制", "保存"]
            }
        #expect((outcome.blocks.map(\.text)) == (["复制", "こんにちは", "保存"]))
        #expect((outcome.blocks.map(\.failed)) == ([false, true, false]))
        #expect((outcome.successfulGroups) == (1))
        #expect((outcome.firstError) != nil)
    }

    @Test
    func testIncompleteResponsesCannotShiftLaterBlocksOrClaimSuccess() async throws {
        let texts = ["Copy", "こんにちは", "Save"]
        let outcome = try await LocalTranslationBatchExecutor.run(texts: texts,
            groups: LocalTranslationRouting.groups(for: texts, targetLanguage: .zhHans)) { pair, _ in
                pair.sourceIdentifier == "en" ? ["只有一个"] : ["你好"]
            }
        #expect((outcome.blocks.map(\.text)) == (["Copy", "你好", "Save"]))
        #expect((outcome.blocks.map(\.failed)) == ([true, false, true]))
    }

    @Test
    func testCancellationDoesNotStartNextLanguageOrReturnPartialSuccess() async throws {
        let texts = ["Copy", "こんにちは"]
        var calls = 0
        do {
            _ = try await LocalTranslationBatchExecutor.run(texts: texts,
                groups: LocalTranslationRouting.groups(for: texts, targetLanguage: .zhHans)) { _, _ in
                    calls += 1
                    throw CancellationError()
                }
            Issue.record(Comment(rawValue: "Cancellation must propagate"))
        } catch { #expect(error is CancellationError) }
        #expect((calls) == (1))
    }
}
