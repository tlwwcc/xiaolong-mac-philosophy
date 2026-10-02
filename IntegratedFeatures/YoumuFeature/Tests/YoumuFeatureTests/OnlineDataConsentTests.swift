import Foundation
import XCTest

@testable import YoumuFeature

@MainActor
final class OnlineDataConsentTests: XCTestCase {
  func testHTTPSOriginNormalizesCasePathAndEffectiveDefaultPort() throws {
    let first = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(
        from: "HTTPS://API.Vendor-A.test/v1/chat/completions?token=never-store"
      )
    )
    let sameOrigin = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test:443/other/path")
    )

    XCTAssertEqual(first.scheme, "https")
    XCTAssertEqual(first.host, "api.vendor-a.test")
    XCTAssertEqual(first.port, 443)
    XCTAssertEqual(first, sameOrigin)
    XCTAssertEqual(first.displayValue, "https://api.vendor-a.test:443")
  }

  func testSecureWebSocketNormalizesToHTTPSOriginAndInsecureSchemesFailClosed() throws {
    let edge = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(
        from: "wss://speech.platform.bing.com/readaloud"
      )
    )

    XCTAssertEqual(edge.scheme, "https")
    XCTAssertEqual(edge.host, "speech.platform.bing.com")
    XCTAssertEqual(edge.port, 443)
    XCTAssertNil(OnlineDataOrigin.normalizedHTTPS(from: "http://api.vendor-a.test/v1"))
    XCTAssertNil(OnlineDataOrigin.normalizedHTTPS(from: "ws://api.vendor-a.test/v1"))
    XCTAssertNil(
      OnlineDataOrigin.normalizedHTTPS(from: "https://user:secret@api.vendor-a.test/v1")
    )
  }

  func testAllowedConsentIsBoundToPurposeHostAndEffectivePort() throws {
    let vendorA = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test/v1")
    )
    let vendorB = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-b.test/v1")
    )
    let vendorAAlternatePort = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test:8443/v1")
    )
    let stored = try XCTUnwrap(
      OnlineConsentPolicy.storedValue(
        decision: .allowed,
        purpose: .translation,
        origin: vendorA
      )
    )

    XCTAssertEqual(
      OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .translation,
        origin: vendorA
      ),
      true
    )
    XCTAssertNil(
      OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .translation,
        origin: vendorB
      )
    )
    XCTAssertNil(
      OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .translation,
        origin: vendorAAlternatePort
      )
    )
    XCTAssertNil(
      OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .edgeSpeech,
        origin: vendorA
      )
    )
  }

  func testTranslationRedirectStaysInsideConsentedOrigin() throws {
    let originalOrigin = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test/v1/chat")
    )

    XCTAssertTrue(
      TranslationRedirectPolicy.allows(
        redirectedURL: URL(string: "https://API.vendor-a.test:443/v2/chat"),
        originalOrigin: originalOrigin
      )
    )
    XCTAssertFalse(
      TranslationRedirectPolicy.allows(
        redirectedURL: URL(string: "https://api.vendor-a.test:8443/v2/chat"),
        originalOrigin: originalOrigin
      )
    )
    XCTAssertFalse(
      TranslationRedirectPolicy.allows(
        redirectedURL: URL(string: "https://api.vendor-b.test/v2/chat"),
        originalOrigin: originalOrigin
      )
    )
    XCTAssertFalse(
      TranslationRedirectPolicy.allows(
        redirectedURL: URL(string: "http://api.vendor-a.test/v2/chat"),
        originalOrigin: originalOrigin
      )
    )
  }

  func testEdgeSpeechRedirectStaysInsideConsentedOrigin() throws {
    let originalOrigin = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(from: EdgeOnlineSpeechClient.onlineConsentEndpoint)
    )

    XCTAssertTrue(
      EdgeSpeechRedirectPolicy.allows(
        redirectedURL: URL(string: "wss://SPEECH.platform.bing.com:443/redirected"),
        originalOrigin: originalOrigin
      )
    )
    XCTAssertTrue(
      EdgeSpeechRedirectPolicy.allows(
        redirectedURL: URL(string: "https://speech.platform.bing.com/handshake"),
        originalOrigin: originalOrigin
      )
    )
    XCTAssertFalse(
      EdgeSpeechRedirectPolicy.allows(
        redirectedURL: URL(string: "wss://speech.platform.bing.com:8443/redirected"),
        originalOrigin: originalOrigin
      )
    )
    XCTAssertFalse(
      EdgeSpeechRedirectPolicy.allows(
        redirectedURL: URL(string: "wss://other.example/redirected"),
        originalOrigin: originalOrigin
      )
    )
    XCTAssertFalse(
      EdgeSpeechRedirectPolicy.allows(
        redirectedURL: URL(string: "ws://speech.platform.bing.com/redirected"),
        originalOrigin: originalOrigin
      )
    )
  }

  func testLegacyOriginlessAllowDoesNotCarryForward() throws {
    let origin = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test/v1")
    )

    XCTAssertNil(
      OnlineConsentPolicy.allowsNetwork(
        storedValue: OnlineConsentDecision.allowed.rawValue,
        purpose: .translation,
        origin: origin
      )
    )
    XCTAssertNil(
      OnlineConsentPolicy.allowsNetwork(
        storedValue: #"{"decision":"allowed"}"#,
        purpose: .translation,
        origin: origin
      )
    )
  }

  func testDeniedConsentAppliesOnlyToItsOrigin() throws {
    let deniedOrigin = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test/v1")
    )
    let otherOrigin = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-b.test/v1")
    )
    let stored = try XCTUnwrap(
      OnlineConsentPolicy.storedValue(
        decision: .denied,
        purpose: .translation,
        origin: deniedOrigin
      )
    )

    XCTAssertEqual(
      OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .translation,
        origin: deniedOrigin
      ),
      false
    )
    XCTAssertNil(
      OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .translation,
        origin: otherOrigin
      )
    )
  }

  func testStoredConsentContainsOnlyOriginNotEndpointPathOrSecretQuery() throws {
    var endpoint = try XCTUnwrap(
      URLComponents(string: "https://api.vendor-a.test/v1/chat/completions")
    )
    endpoint.queryItems = [URLQueryItem(name: "api_key", value: "sk-never-store")]
    let origin = try XCTUnwrap(
      OnlineDataOrigin.normalizedHTTPS(from: try XCTUnwrap(endpoint.string))
    )
    let stored = try XCTUnwrap(
      OnlineConsentPolicy.storedValue(
        decision: .allowed,
        purpose: .translation,
        origin: origin
      )
    )

    XCTAssertTrue(stored.contains("api.vendor-a.test"))
    XCTAssertFalse(stored.contains("chat/completions"))
    XCTAssertFalse(stored.contains("api_key"))
    XCTAssertFalse(stored.contains("sk-never-store"))
  }
}


@MainActor
private final class ConsentPromptFixture {
  var completions: [(OnlineConsentDecision?) -> Void] = []
  var dismissed: [Int] = []
  var didPresent: (() -> Void)?

  func present(
    _ purpose: OnlineDataPurpose,
    _ origin: OnlineDataOrigin,
    completion: @escaping (OnlineConsentDecision?) -> Void
  ) -> () -> Void {
    let index = completions.count
    completions.append(completion)
    didPresent?()
    return { self.dismissed.append(index) }
  }
}

extension OnlineDataConsentTests {
  private func isolatedDefaults() throws -> UserDefaults {
    let suite = "OnlineDataConsentTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return defaults
  }

  func testStoredDecisionDoesNotShowPromptOrSuspendOverlay() async throws {
    let defaults = try isolatedDefaults()
    let endpoint = try XCTUnwrap(URL(string: "https://api.vendor-a.test/v1"))
    let origin = try XCTUnwrap(OnlineDataOrigin.normalizedHTTPS(from: endpoint))
    let fixture = ConsentPromptFixture()
    let manager = OnlineDataConsentManager(defaults: defaults, presenter: fixture.present)
    var presentation: [Bool] = []
    for decision: OnlineConsentDecision in [.allowed, .denied] {
      defaults.set(OnlineConsentPolicy.storedValue(
        decision: decision, purpose: .translation, origin: origin
      ), forKey: OnlineDataPurpose.translation.defaultsKey)
      let result = try await manager.requestCancellable(
        .translation, endpoint: endpoint, systemPresentation: { presentation.append($0) }
      )
      XCTAssertEqual(result, decision == .allowed)
    }
    XCTAssertTrue(fixture.completions.isEmpty)
    XCTAssertTrue(presentation.isEmpty)
  }

  func testPromptCancelRestoresOverlayAndDoesNotPersistRefusal() async throws {
    let defaults = try isolatedDefaults()
    let fixture = ConsentPromptFixture()
    let appeared = expectation(description: "Consent visible")
    fixture.didPresent = { appeared.fulfill() }
    let manager = OnlineDataConsentManager(defaults: defaults, presenter: fixture.present)
    var presentation: [Bool] = []
    let task = Task { @MainActor in
      try await manager.requestCancellable(
        .translation, endpoint: URL(string: "https://api.vendor-a.test/v1")!,
        systemPresentation: { presentation.append($0) }
      )
    }
    await fulfillment(of: [appeared], timeout: 1)
    XCTAssertEqual(presentation, [true])
    fixture.completions[0](nil) // Esc, 取消 and window close share this result.
    do { _ = try await task.value; XCTFail("Prompt cancellation must end the translation") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(presentation, [true, false])
    XCTAssertEqual(fixture.dismissed, [0])
    XCTAssertNil(defaults.string(forKey: OnlineDataPurpose.translation.defaultsKey))
  }

  func testTaskCancellationDismissesOnlyItsOwnPromptAndIgnoresLateDecision() async throws {
    let defaults = try isolatedDefaults()
    let fixture = ConsentPromptFixture()
    let appeared = expectation(description: "Both confirmations visible")
    appeared.expectedFulfillmentCount = 2
    fixture.didPresent = { appeared.fulfill() }
    let manager = OnlineDataConsentManager(defaults: defaults, presenter: fixture.present)
    var firstPresentation: [Bool] = []
    var secondPresentation: [Bool] = []
    let first = Task { @MainActor in
      try await manager.requestCancellable(
        .translation, endpoint: URL(string: "https://api.vendor-a.test/v1")!,
        systemPresentation: { firstPresentation.append($0) }
      )
    }
    // Ensure the fixture's first completion belongs to the first task.
    while fixture.completions.isEmpty { await Task.yield() }
    let second = Task { @MainActor in
      try await manager.requestCancellable(
        .translation, endpoint: URL(string: "https://api.vendor-b.test/v1")!,
        systemPresentation: { secondPresentation.append($0) }
      )
    }
    await fulfillment(of: [appeared], timeout: 1)
    first.cancel()
    do { _ = try await first.value; XCTFail("Task cancellation must end its confirmation") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.dismissed, [0])
    XCTAssertEqual(firstPresentation, [true, false])
    XCTAssertEqual(secondPresentation, [true])
    fixture.completions[0](.denied)
    XCTAssertNil(defaults.string(forKey: OnlineDataPurpose.translation.defaultsKey))
    XCTAssertEqual(secondPresentation, [true])
    fixture.completions[1](.allowed)
    let allowed = try await second.value
    XCTAssertTrue(allowed)
    XCTAssertEqual(fixture.dismissed, [0, 1])
    XCTAssertEqual(secondPresentation, [true, false])
    let secondOrigin = try XCTUnwrap(OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-b.test"))
    XCTAssertEqual(OnlineConsentPolicy.allowsNetwork(
      storedValue: defaults.string(forKey: OnlineDataPurpose.translation.defaultsKey),
      purpose: .translation, origin: secondOrigin
    ), true)
  }

  func testAlreadyCancelledTaskDoesNotShowOrSaveConsent() async throws {
    let defaults = try isolatedDefaults()
    let fixture = ConsentPromptFixture()
    let manager = OnlineDataConsentManager(defaults: defaults, presenter: fixture.present)
    var presentation: [Bool] = []
    let task = Task { @MainActor in
      try await manager.requestCancellable(
        .translation, endpoint: URL(string: "https://api.vendor-a.test/v1")!,
        systemPresentation: { presentation.append($0) }
      )
    }
    task.cancel()
    do { _ = try await task.value; XCTFail("Precancelled task must fail immediately") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(fixture.completions.isEmpty)
    XCTAssertTrue(presentation.isEmpty)
    XCTAssertNil(defaults.string(forKey: OnlineDataPurpose.translation.defaultsKey))
  }

  func testOnlyExplicitDenialPersistsDeniedAndSynchronousCompletionCleansUp() async throws {
    let defaults = try isolatedDefaults()
    var dismissals = 0
    var presentation: [Bool] = []
    let manager = OnlineDataConsentManager(defaults: defaults) { _, _, completion in
      completion(.denied)
      return { dismissals += 1 }
    }
    let endpoint = try XCTUnwrap(URL(string: "https://api.vendor-a.test/v1"))
    let allowed = try await manager.requestCancellable(
      .translation, endpoint: endpoint, systemPresentation: { presentation.append($0) }
    )
    XCTAssertFalse(allowed)
    XCTAssertEqual(dismissals, 1)
    XCTAssertEqual(presentation, [true, false])
    let origin = try XCTUnwrap(OnlineDataOrigin.normalizedHTTPS(from: endpoint))
    XCTAssertEqual(OnlineConsentPolicy.allowsNetwork(
      storedValue: defaults.string(forKey: OnlineDataPurpose.translation.defaultsKey),
      purpose: .translation, origin: origin
    ), false)
  }
}
