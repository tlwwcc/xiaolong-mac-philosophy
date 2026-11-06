import Foundation
import Testing
@testable import YoumuFeature

@MainActor
@Suite(.serialized)
final class SharedTranslationClientTests {
    @Test
    func testPartialBlocksKeepExactSourceAndDoNotPoisonCache() async throws {
        let name = "partial-translation-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var calls = 0
        let client = SharedTranslationClient(defaults: defaults) { request, _ in
            calls += 1
            let data = Data(#"{"translations":["保存","UNSAFE"],"failedIndices":[1]}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        for _ in 0..<2 {
            let result = try await client.translateBlocks(["Save", "Delete %d from %s?"], target: .zhHans)
            #expect(result == [.init(text: "保存", failed: false), .init(text: "Delete %d from %s?", failed: true)])
        }
        #expect(calls == 2)
        do {
            _ = try await client.translate(["Save", "Delete %d from %s?"], target: .zhHans)
            Issue.record("Whole-text translation must not present a partial result as complete")
        } catch SharedTranslationError.invalidResponse {}
        #expect(calls == 3)
        for indices in ["[-1]", "[2]", "[0,0]"] {
            expectThrowsError(try SharedTranslationClient.decodeBlocks(
                Data(("{\"translations\":[\"a\",\"b\"],\"failedIndices\":" + indices + "}").utf8), expectedCount: 2))
        }
    }

    @Test
    func testCacheSeparatesLanguageAndOrderAndExpiresWithinByteBudget() {
        var now: TimeInterval = 0
        let cache = TranslationResponseCache(capacity: 2, byteLimit: 32, lifetime: 2, now: { now })
        let key = TranslationResponseCache.Key(texts: ["a", "b"], target: "en")
        cache.insert(["A", "B"], for: key)
        #expect(cache.value(for: key) == ["A", "B"])
        #expect(cache.value(for: .init(texts: ["b", "a"], target: "en")) == nil)
        #expect(cache.value(for: .init(texts: ["a", "b"], target: "ja")) == nil)
        now = 2
        #expect(cache.value(for: key) == nil)
        #expect(cache.retainedBytes == 0)
        cache.insert([String(repeating: "x", count: 33)], for: key)
        #expect(cache.count == 0)
    }
    @Test
    func testNewInstallationUsesSharedButLegacyAndExplicitChoiceArePreserved() throws {
        #expect((AppSettings().translationBackend) == (.sharedService))
        #expect((try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).translationBackend) == (.appleLocal))
        for choice in TranslationBackendPreference.allCases {
            var settings = AppSettings()
            settings.translationBackend = choice
            let copy = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect((copy.translationBackend) == (choice))
        }
        #expect((TranslationBackendPolicy.resolve(.sharedService)) == (TranslationBackendPolicy(triesAppleLocal: false, allowsOnline: true)))
    }

    @Test
    func testBatchesKeepOCRBlockOrderAndBoundUnicodeAndEscaping() throws {
        let source = (0..<25).map { "block \($0)" }
        let batches = try SharedTranslationClient.batches(source)
        #expect((batches.map(\.count)) == ([12, 12, 1]))
        #expect((batches.flatMap { $0 }) == (source))
        expectThrowsError(try SharedTranslationClient.batches([String(repeating: "汉", count: 800)]))
        expectThrowsError(try SharedTranslationClient.batches([String(repeating: "\\", count: 1500)]))
        expectThrowsError(try SharedTranslationClient.batches(["  "]))
        expectThrowsError(try SharedTranslationClient.batches(Array(repeating: "a", count: 73)))
        #expect(try SharedTranslationClient.batches([]).isEmpty)
    }

    @Test
    func testDedicatedAnonymousIDIsStableAndDoesNotReuseAnotherFeature() {
        let name = "shared-translation-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("personal-telemetry-id", forKey: "usageStatistics.deviceID")
        let value = SharedTranslationClient.deviceID(defaults: defaults)
        #expect((UUID(uuidString: value)) != nil)
        #expect((value) == (SharedTranslationClient.deviceID(defaults: defaults)))
        #expect((value) != ("personal-telemetry-id"))
    }

    @Test
    func testClientSendsOnlyTextLanguageAndAnonymousIDWithNoCredential() async throws {
        let name = "shared-translation-request-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0
        let client = SharedTranslationClient(defaults: defaults) { request, config in
            requests += 1
            #expect((request.url) == (SharedTranslationClient.endpoint))
            #expect((request.httpMethod) == ("POST"))
            #expect((request.value(forHTTPHeaderField: "Authorization")) == nil)
            #expect((config.httpCookieStorage) == nil)
            #expect((config.urlCache) == nil)
            let requestBody = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            #expect((Set(body.keys)) == (Set(["texts", "target", "deviceId"])))
            #expect((body["target"] as? String) == ("zh-Hant"))
            let text = try #require(body["texts"] as? [String])
            let data = try JSONSerialization.data(withJSONObject: ["translations": text.map { "译" + $0 }])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let source = (0..<13).map { "word\($0)" }
        let translated = try await client.translate(source, target: .zhHant)
        #expect((translated) == (source.map { "译" + $0 }))
        #expect((requests) == (2))
    }

    @Test
    func testMalformedOutputIsRejectedWithoutReturningMisalignedText() throws {
        for raw in ["{}", "{\"translations\":[]}", "{\"translations\":[\"\"]}", "{\"translations\":[\"a\",\"b\"]}"] {
            expectThrowsError(try SharedTranslationClient.decode(Data(raw.utf8), expectedCount: 1))
        }
        expectThrowsError(try SharedTranslationClient.languageCode(.auto))
        #expect((try SharedTranslationClient.languageCode(.ja)) == ("ja"))
    }

    @Test
    func testCancelledBatchDoesNotRetryOrContinue() async throws {
        let name = "shared-translation-cancel-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0
        let client = SharedTranslationClient(defaults: defaults) { _, _ in
            requests += 1
            throw CancellationError()
        }
        do {
            _ = try await client.translate(Array(repeating: "word", count: 13), target: .zhHans)
            Issue.record(Comment(rawValue: "Expected cancellation"))
        } catch is CancellationError {} catch { Issue.record(Comment(rawValue: "Unexpected error: \(error)")) }
        #expect((requests) == (1))
    }
}
