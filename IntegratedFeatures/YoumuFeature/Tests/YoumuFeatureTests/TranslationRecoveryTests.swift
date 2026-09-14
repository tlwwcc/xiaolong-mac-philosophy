import Foundation
import Translation
import XCTest
@testable import YoumuFeature

final class TranslationRecoveryTests: XCTestCase {
    @MainActor
    func testRepeatedSameLanguageJobsKeepIncreasingConfigurationVersion() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Translation requires macOS 15") }
        let coordinator = AppleLocalTranslationCoordinator()
        var versions: [Int] = []
        for index in 0..<5 {
            let id = UUID()
            let task = Task { @MainActor in
                try await coordinator.perform(
                    id: id, texts: ["Save document"],
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "zh-Hans"),
                    prepareFirst: index == 0, allowsSystemInteraction: index == 0)
            }
            while coordinator.requestID != id { await Task.yield() }
            versions.append(try XCTUnwrap(coordinator.configuration?.version))
            coordinator.finish(id: id, result: .success(["保存文档"]))
            let result = try await task.value
            XCTAssertEqual(result, ["保存文档"])
        }
        XCTAssertEqual(versions, [0, 1, 2, 3, 4])
    }

    @MainActor
    func testCancelledOwnerAndLateCompletionCannotFinishReplacement() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Translation requires macOS 15") }
        let coordinator = AppleLocalTranslationCoordinator()
        let old = UUID()
        let first = Task { @MainActor in
            try await coordinator.perform(id: old, texts: ["Cancel me"],
                source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"),
                prepareFirst: true, allowsSystemInteraction: true)
        }
        while coordinator.requestID != old { await Task.yield() }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        let replacement = UUID()
        let second = Task { @MainActor in
            try await coordinator.perform(id: replacement, texts: ["Keep me"],
                source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"),
                prepareFirst: false, allowsSystemInteraction: false)
        }
        while coordinator.requestID != replacement { await Task.yield() }
        coordinator.finish(id: old, result: .success(["late result"]))
        coordinator.cancel(id: old)
        XCTAssertEqual(coordinator.requestID, replacement)
        coordinator.finish(id: replacement, result: .success(["保留"] ))
        let result = try await second.value
        XCTAssertEqual(result, ["保留"])
    }

    @MainActor
    func testNativeSystemCancellationUsesCancellationPathAndPreservesRealErrors() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Native alreadyCancelled requires macOS 26") }
        let coordinator = AppleLocalTranslationCoordinator()
        let errors: [Error] = [
            AppleFrameworkTranslationError.alreadyCancelled,
            AppleFrameworkTranslationError.internalError,
        ]
        for (index, nativeError) in errors.enumerated() {
            let id = UUID()
            let operation = Task { @MainActor in
                try await coordinator.perform(id: id, texts: ["Save this document."],
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "zh-Hans"),
                    prepareFirst: true, allowsSystemInteraction: true)
            }
            while coordinator.requestID != id { await Task.yield() }
            coordinator.finishSessionFailure(id: id, error: nativeError)
            do {
                _ = try await operation.value
                XCTFail("Native error must not return a translation")
            } catch {
                XCTAssertEqual(error is CancellationError, index == 0)
                if index == 1 {
                    XCTAssertTrue(AppleFrameworkTranslationError.internalError ~= error)
                }
            }
            XCTAssertNil(coordinator.requestID)
        }
    }

    @MainActor
    func testShortWordsRemainTranslatableAndAmbiguityUsesSystemDetection() {
        let short = LocalTranslationRouting.pair(for: ["OK"], targetLanguage: .zhHans)
        XCTAssertNotNil(short)
        XCTAssertNil(short?.sourceIdentifier)
        XCTAssertEqual(short?.targetIdentifier, "zh-Hans")
        XCTAssertNotNil(LocalTranslationRouting.pair(for: ["Save"], targetLanguage: .zhHans))
        XCTAssertNotNil(LocalTranslationRouting.pair(for: ["こんにちは"], targetLanguage: .zhHans))
        XCTAssertNil(LocalTranslationRouting.pair(for: ["123 / 45%"], targetLanguage: .zhHans))
        XCTAssertTrue(LanguageClassifier.shouldTranslate("OK", targetLanguage: .zhHans))
        XCTAssertFalse(LanguageClassifier.shouldTranslate("123 / 45%", targetLanguage: .zhHans))
    }

    @MainActor
    func testEndpointPasteNormalizesKnownRootsAndPreservesCustomPaths() throws {
        XCTAssertEqual(try TranslationConfig.normalizedEndpoint(" api.deepseek.com ").absoluteString,
                       "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(try TranslationConfig.normalizedEndpoint("https://api.openai.com/v1/").absoluteString,
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(try TranslationConfig.normalizedEndpoint("https://dashscope.aliyuncs.com").path,
                       "/compatible-mode/v1/chat/completions")
        XCTAssertEqual(try TranslationConfig.normalizedEndpoint("https://custom.example/translate?api-version=7").absoluteString,
                       "https://custom.example/translate?api-version=7")
        XCTAssertThrowsError(try TranslationConfig.normalizedEndpoint("http://api.example/v1"))
        XCTAssertThrowsError(try TranslationConfig.normalizedEndpoint("https://user@api.example.invalid/v1"))
    }

    @MainActor
    func testKnownModelCanBeFilledButUnknownModelIsRequiredAndSecretIsNeverEncoded() throws {
        let known = try TranslationConfig(apiEndpoint: "api.openai.com", apiKey: " key ", modelName: "")
            .normalizedForUse()
        XCTAssertEqual(known.modelName, "gpt-4o-mini")
        XCTAssertEqual(known.apiKey, "key")
        XCTAssertThrowsError(try TranslationConfig(apiEndpoint: "api.openai.com", modelName: "").normalizedForUse())
        XCTAssertThrowsError(try TranslationConfig(apiEndpoint: "https://custom.example", modelName: "").normalizedForUse())
        let custom = try TranslationConfig(apiEndpoint: "https://custom.example", modelName: "actual-model").normalizedForUse()
        XCTAssertFalse(custom.requiresAPIKey)
        let bytes = try JSONEncoder().encode(known)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("key"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("apiKey"))
    }
}
