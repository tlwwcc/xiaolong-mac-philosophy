import XCTest
@testable import YoumuFeature

@MainActor
final class SharedTranslationClientTests: XCTestCase {
    func testNewInstallationUsesSharedButLegacyAndExplicitChoiceArePreserved() throws {
        XCTAssertEqual(AppSettings().translationBackend, .sharedService)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).translationBackend, .appleLocal)
        for choice in TranslationBackendPreference.allCases {
            var settings = AppSettings()
            settings.translationBackend = choice
            let copy = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(copy.translationBackend, choice)
        }
        XCTAssertEqual(TranslationBackendPolicy.resolve(.sharedService),
                       TranslationBackendPolicy(triesAppleLocal: false, allowsOnline: true))
    }

    func testBatchesKeepOCRBlockOrderAndBoundUnicodeAndEscaping() throws {
        let source = (0..<25).map { "block \($0)" }
        let batches = try SharedTranslationClient.batches(source)
        XCTAssertEqual(batches.map(\.count), [12, 12, 1])
        XCTAssertEqual(batches.flatMap { $0 }, source)
        XCTAssertThrowsError(try SharedTranslationClient.batches([String(repeating: "汉", count: 800)]))
        XCTAssertThrowsError(try SharedTranslationClient.batches([String(repeating: "\\", count: 1500)]))
        XCTAssertThrowsError(try SharedTranslationClient.batches(["  "]))
        XCTAssertThrowsError(try SharedTranslationClient.batches(Array(repeating: "a", count: 73)))
        XCTAssertTrue(try SharedTranslationClient.batches([]).isEmpty)
    }

    func testDedicatedAnonymousIDIsStableAndDoesNotReuseAnotherFeature() {
        let name = "shared-translation-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("personal-telemetry-id", forKey: "usageStatistics.deviceID")
        let value = SharedTranslationClient.deviceID(defaults: defaults)
        XCTAssertNotNil(UUID(uuidString: value))
        XCTAssertEqual(value, SharedTranslationClient.deviceID(defaults: defaults))
        XCTAssertNotEqual(value, "personal-telemetry-id")
    }

    func testClientSendsOnlyTextLanguageAndAnonymousIDWithNoCredential() async throws {
        let name = "shared-translation-request-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0
        let client = SharedTranslationClient(defaults: defaults) { request, config in
            requests += 1
            XCTAssertEqual(request.url, SharedTranslationClient.endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(config.httpCookieStorage)
            XCTAssertNil(config.urlCache)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(Set(body.keys), Set(["texts", "target", "deviceId"]))
            XCTAssertEqual(body["target"] as? String, "zh-Hant")
            let text = try XCTUnwrap(body["texts"] as? [String])
            let data = try JSONSerialization.data(withJSONObject: ["translations": text.map { "译" + $0 }])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let source = (0..<13).map { "word\($0)" }
        let translated = try await client.translate(source, target: .zhHant)
        XCTAssertEqual(translated, source.map { "译" + $0 })
        XCTAssertEqual(requests, 2)
    }

    func testMalformedOutputIsRejectedWithoutReturningMisalignedText() throws {
        for raw in ["{}", "{\"translations\":[]}", "{\"translations\":[\"\"]}", "{\"translations\":[\"a\",\"b\"]}"] {
            XCTAssertThrowsError(try SharedTranslationClient.decode(Data(raw.utf8), expectedCount: 1))
        }
        XCTAssertThrowsError(try SharedTranslationClient.languageCode(.auto))
        XCTAssertEqual(try SharedTranslationClient.languageCode(.ja), "ja")
    }

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
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests, 1)
    }
}
