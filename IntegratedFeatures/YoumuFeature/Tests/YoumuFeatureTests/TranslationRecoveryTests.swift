import Foundation
import Translation
import Testing
@testable import YoumuFeature

@Suite(.serialized)
final class TranslationRecoveryTests {
    @MainActor
    @available(macOS 15, *)
    @Test
    func testRepeatedSameLanguageJobsKeepIncreasingConfigurationVersion() async throws {
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
            versions.append(try #require(coordinator.configuration?.version))
            coordinator.finish(id: id, result: .success(["保存文档"]))
            let result = try await task.value
            #expect((result) == (["保存文档"]))
        }
        #expect((versions) == ([0, 1, 2, 3, 4]))
    }

    @MainActor
    @available(macOS 15, *)
    @Test
    func testCancelledOwnerAndLateCompletionCannotFinishReplacement() async throws {
        let coordinator = AppleLocalTranslationCoordinator()
        let old = UUID()
        let first = Task { @MainActor in
            try await coordinator.perform(id: old, texts: ["Cancel me"],
                source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"),
                prepareFirst: true, allowsSystemInteraction: true)
        }
        while coordinator.requestID != old { await Task.yield() }
        first.cancel()
        do { _ = try await first.value; Issue.record(Comment(rawValue: "Cancellation must propagate")) }
        catch { #expect(error is CancellationError) }
        let replacement = UUID()
        let second = Task { @MainActor in
            try await coordinator.perform(id: replacement, texts: ["Keep me"],
                source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"),
                prepareFirst: false, allowsSystemInteraction: false)
        }
        while coordinator.requestID != replacement { await Task.yield() }
        coordinator.finish(id: old, result: .success(["late result"]))
        coordinator.cancel(id: old)
        #expect((coordinator.requestID) == (replacement))
        coordinator.finish(id: replacement, result: .success(["保留"] ))
        let result = try await second.value
        #expect((result) == (["保留"]))
    }

    @MainActor
    @available(macOS 26, *)
    @Test
    func testNativeSystemCancellationUsesCancellationPathAndPreservesRealErrors() async throws {
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
                Issue.record(Comment(rawValue: "Native error must not return a translation"))
            } catch {
                #expect((error is CancellationError) == (index == 0))
                if index == 1 {
                    #expect(AppleFrameworkTranslationError.internalError ~= error)
                }
            }
            #expect((coordinator.requestID) == nil)
        }
    }

    @MainActor
    @Test
    func testShortWordsUseExplicitLanguageWithoutSystemDetection() {
        let short = LocalTranslationRouting.pair(for: ["OK"], targetLanguage: .zhHans)
        #expect((short) != nil)
        #expect((short?.sourceIdentifier) == ("en"))
        #expect((short?.targetIdentifier) == ("zh-Hans"))
        #expect((LocalTranslationRouting.pair(for: ["Save"], targetLanguage: .zhHans)) != nil)
        #expect((LocalTranslationRouting.pair(for: ["こんにちは"], targetLanguage: .zhHans)) != nil)
        #expect((LocalTranslationRouting.pair(for: ["123 / 45%"], targetLanguage: .zhHans)) == nil)
        #expect(LanguageClassifier.shouldTranslate("OK", targetLanguage: .zhHans))
        #expect(!(LanguageClassifier.shouldTranslate("123 / 45%", targetLanguage: .zhHans)))
    }

    @MainActor
    @Test
    func testEndpointPasteNormalizesKnownRootsAndPreservesCustomPaths() throws {
        #expect((try TranslationConfig.normalizedEndpoint(" api.deepseek.com ").absoluteString) == ("https://api.deepseek.com/v1/chat/completions"))
        #expect((try TranslationConfig.normalizedEndpoint("https://api.openai.com/v1/").absoluteString) == ("https://api.openai.com/v1/chat/completions"))
        #expect((try TranslationConfig.normalizedEndpoint("https://dashscope.aliyuncs.com").path) == ("/compatible-mode/v1/chat/completions"))
        #expect((try TranslationConfig.normalizedEndpoint("https://custom.example/translate?api-version=7").absoluteString) == ("https://custom.example/translate?api-version=7"))
        expectThrowsError(try TranslationConfig.normalizedEndpoint("http://api.example/v1"))
        expectThrowsError(try TranslationConfig.normalizedEndpoint("https://user@api.example.invalid/v1"))
    }

    @MainActor
    @Test
    func testKnownModelCanBeFilledButUnknownModelIsRequiredAndSecretIsNeverEncoded() throws {
        let known = try TranslationConfig(apiEndpoint: "api.openai.com", apiKey: " key ", modelName: "")
            .normalizedForUse()
        #expect((known.modelName) == ("gpt-4o-mini"))
        #expect((known.apiKey) == ("key"))
        expectThrowsError(try TranslationConfig(apiEndpoint: "api.openai.com", modelName: "").normalizedForUse())
        expectThrowsError(try TranslationConfig(apiEndpoint: "https://custom.example", modelName: "").normalizedForUse())
        let custom = try TranslationConfig(apiEndpoint: "https://custom.example", modelName: "actual-model").normalizedForUse()
        #expect(!(custom.requiresAPIKey))
        let bytes = try JSONEncoder().encode(known)
        #expect(!(String(decoding: bytes, as: UTF8.self).contains("key")))
        #expect(!(String(decoding: bytes, as: UTF8.self).contains("apiKey")))
    }
}
