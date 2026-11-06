import Foundation
import Testing

@testable import YoumuFeature

@MainActor
@Suite(.serialized)
final class OnlineDataConsentTests {
  @Test
  func testSharedRecipientChangeRequiresNewChoiceButOtherPurposesKeepConsent() throws {
    let origin = try #require(OnlineDataOrigin.normalizedHTTPS(from: "https://aixlg.com"))
    for purpose in OnlineDataPurpose.allCases {
      let old = StoredOnlineConsent(version: 1, purpose: purpose, origin: origin, decision: .allowed)
      let raw = String(data: try JSONEncoder().encode(old), encoding: .utf8)!
      let expected: Bool? = purpose == .sharedTranslation ? nil : true
      #expect(OnlineConsentPolicy.allowsNetwork(storedValue: raw, purpose: purpose, origin: origin) == expected)
      let fresh = OnlineConsentPolicy.storedValue(decision: .allowed, purpose: purpose, origin: origin)
      #expect(OnlineConsentPolicy.allowsNetwork(storedValue: fresh, purpose: purpose, origin: origin) == true)
    }
    #expect(OnlineDataPurpose.sharedTranslation.sharedTranslationNotice.contains("阿里云百炼"))
    #expect(OnlineDataPurpose.sharedTranslation.sharedTranslationNotice.contains("截图留在本机"))
  }
  private var defaultsSuites: [String] = []

  deinit {
    for suite in defaultsSuites {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
  }

  @Test
  func testHTTPSOriginNormalizesCasePathAndEffectiveDefaultPort() throws {
    let first = try #require(OnlineDataOrigin.normalizedHTTPS(
        from: "HTTPS://API.Vendor-A.test/v1/chat/completions?token=never-store"
      ))
    let sameOrigin = try #require(OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test:443/other/path"))

    #expect((first.scheme) == ("https"))
    #expect((first.host) == ("api.vendor-a.test"))
    #expect((first.port) == (443))
    #expect((first) == (sameOrigin))
    #expect((first.displayValue) == ("https://api.vendor-a.test:443"))
  }

  @Test
  func testSecureWebSocketNormalizesToHTTPSOriginAndInsecureSchemesFailClosed() throws {
    let edge = try #require(OnlineDataOrigin.normalizedHTTPS(
        from: "wss://speech.platform.bing.com/readaloud"
      ))

    #expect((edge.scheme) == ("https"))
    #expect((edge.host) == ("speech.platform.bing.com"))
    #expect((edge.port) == (443))
    #expect((OnlineDataOrigin.normalizedHTTPS(from: "http://api.vendor-a.test/v1")) == nil)
    #expect((OnlineDataOrigin.normalizedHTTPS(from: "ws://api.vendor-a.test/v1")) == nil)
    #expect((OnlineDataOrigin.normalizedHTTPS(from: "https://user:secret@api.vendor-a.test/v1")) == nil)
  }

  @Test
  func testAllowedConsentIsBoundToPurposeHostAndEffectivePort() throws {
    let vendorA = try #require(OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test/v1"))
    let vendorB = try #require(OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-b.test/v1"))
    let vendorAAlternatePort = try #require(OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test:8443/v1"))
    let stored = try #require(OnlineConsentPolicy.storedValue(
        decision: .allowed,
        purpose: .translation,
        origin: vendorA
      ))

    #expect((OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .translation,
        origin: vendorA
      )) == (true))
    #expect((OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .translation,
        origin: vendorB
      )) == nil)
    #expect((OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .translation,
        origin: vendorAAlternatePort
      )) == nil)
    #expect((OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .edgeSpeech,
        origin: vendorA
      )) == nil)
  }

  @Test
  func testTranslationRedirectStaysInsideConsentedOrigin() throws {
    let originalOrigin = try #require(OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test/v1/chat"))

    #expect(TranslationRedirectPolicy.allows(
        redirectedURL: URL(string: "https://API.vendor-a.test:443/v2/chat"),
        originalOrigin: originalOrigin
      ))
    #expect(!(TranslationRedirectPolicy.allows(
        redirectedURL: URL(string: "https://api.vendor-a.test:8443/v2/chat"),
        originalOrigin: originalOrigin
      )))
    #expect(!(TranslationRedirectPolicy.allows(
        redirectedURL: URL(string: "https://api.vendor-b.test/v2/chat"),
        originalOrigin: originalOrigin
      )))
    #expect(!(TranslationRedirectPolicy.allows(
        redirectedURL: URL(string: "http://api.vendor-a.test/v2/chat"),
        originalOrigin: originalOrigin
      )))
  }

  @Test
  func testEdgeSpeechRedirectStaysInsideConsentedOrigin() throws {
    let originalOrigin = try #require(OnlineDataOrigin.normalizedHTTPS(from: EdgeOnlineSpeechClient.onlineConsentEndpoint))

    #expect(EdgeSpeechRedirectPolicy.allows(
        redirectedURL: URL(string: "wss://SPEECH.platform.bing.com:443/redirected"),
        originalOrigin: originalOrigin
      ))
    #expect(EdgeSpeechRedirectPolicy.allows(
        redirectedURL: URL(string: "https://speech.platform.bing.com/handshake"),
        originalOrigin: originalOrigin
      ))
    #expect(!(EdgeSpeechRedirectPolicy.allows(
        redirectedURL: URL(string: "wss://speech.platform.bing.com:8443/redirected"),
        originalOrigin: originalOrigin
      )))
    #expect(!(EdgeSpeechRedirectPolicy.allows(
        redirectedURL: URL(string: "wss://other.example/redirected"),
        originalOrigin: originalOrigin
      )))
    #expect(!(EdgeSpeechRedirectPolicy.allows(
        redirectedURL: URL(string: "ws://speech.platform.bing.com/redirected"),
        originalOrigin: originalOrigin
      )))
  }

  @Test
  func testLegacyOriginlessAllowDoesNotCarryForward() throws {
    let origin = try #require(OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test/v1"))

    #expect((OnlineConsentPolicy.allowsNetwork(
        storedValue: OnlineConsentDecision.allowed.rawValue,
        purpose: .translation,
        origin: origin
      )) == nil)
    #expect((OnlineConsentPolicy.allowsNetwork(
        storedValue: #"{"decision":"allowed"}"#,
        purpose: .translation,
        origin: origin
      )) == nil)
  }

  @Test
  func testDeniedConsentAppliesOnlyToItsOrigin() throws {
    let deniedOrigin = try #require(OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-a.test/v1"))
    let otherOrigin = try #require(OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-b.test/v1"))
    let stored = try #require(OnlineConsentPolicy.storedValue(
        decision: .denied,
        purpose: .translation,
        origin: deniedOrigin
      ))

    #expect((OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .translation,
        origin: deniedOrigin
      )) == (false))
    #expect((OnlineConsentPolicy.allowsNetwork(
        storedValue: stored,
        purpose: .translation,
        origin: otherOrigin
      )) == nil)
  }

  @Test
  func testStoredConsentContainsOnlyOriginNotEndpointPathOrSecretQuery() throws {
    var endpoint = try #require(URLComponents(string: "https://api.vendor-a.test/v1/chat/completions"))
    endpoint.queryItems = [URLQueryItem(name: "api_key", value: "sk-never-store")]
    let endpointString = try #require(endpoint.string)
    let origin = try #require(OnlineDataOrigin.normalizedHTTPS(from: endpointString))
    let stored = try #require(OnlineConsentPolicy.storedValue(
        decision: .allowed,
        purpose: .translation,
        origin: origin
      ))

    #expect(stored.contains("api.vendor-a.test"))
    #expect(!(stored.contains("chat/completions")))
    #expect(!(stored.contains("api_key")))
    #expect(!(stored.contains("sk-never-store")))
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
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaultsSuites.append(suite)
    return defaults
  }

  @Test
  func testStoredDecisionDoesNotShowPromptOrSuspendOverlay() async throws {
    let defaults = try isolatedDefaults()
    let endpoint = try #require(URL(string: "https://api.vendor-a.test/v1"))
    let origin = try #require(OnlineDataOrigin.normalizedHTTPS(from: endpoint))
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
      #expect((result) == (decision == .allowed))
    }
    #expect(fixture.completions.isEmpty)
    #expect(presentation.isEmpty)
  }

  @Test
  func testPromptCancelRestoresOverlayAndDoesNotPersistRefusal() async throws {
    let defaults = try isolatedDefaults()
    let fixture = ConsentPromptFixture()
    let appeared = TestSignal(description: "Consent visible")
    fixture.didPresent = { appeared.fulfill() }
    let manager = OnlineDataConsentManager(defaults: defaults, presenter: fixture.present)
    var presentation: [Bool] = []
    let task = Task { @MainActor in
      try await manager.requestCancellable(
        .translation, endpoint: URL(string: "https://api.vendor-a.test/v1")!,
        systemPresentation: { presentation.append($0) }
      )
    }
    await awaitTestSignals(of: [appeared], timeout: 1)
    #expect((presentation) == ([true]))
    fixture.completions[0](nil) // Esc, 取消 and window close share this result.
    do { _ = try await task.value; Issue.record(Comment(rawValue: "Prompt cancellation must end the translation")) }
    catch { #expect(error is CancellationError) }
    #expect((presentation) == ([true, false]))
    #expect((fixture.dismissed) == ([0]))
    #expect((defaults.string(forKey: OnlineDataPurpose.translation.defaultsKey)) == nil)
  }

  @Test
  func testTaskCancellationDismissesOnlyItsOwnPromptAndIgnoresLateDecision() async throws {
    let defaults = try isolatedDefaults()
    let fixture = ConsentPromptFixture()
    let appeared = TestSignal(description: "Both confirmations visible")
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
    await awaitTestSignals(of: [appeared], timeout: 1)
    first.cancel()
    do { _ = try await first.value; Issue.record(Comment(rawValue: "Task cancellation must end its confirmation")) }
    catch { #expect(error is CancellationError) }
    #expect((fixture.dismissed) == ([0]))
    #expect((firstPresentation) == ([true, false]))
    #expect((secondPresentation) == ([true]))
    fixture.completions[0](.denied)
    #expect((defaults.string(forKey: OnlineDataPurpose.translation.defaultsKey)) == nil)
    #expect((secondPresentation) == ([true]))
    fixture.completions[1](.allowed)
    let allowed = try await second.value
    #expect(allowed)
    #expect((fixture.dismissed) == ([0, 1]))
    #expect((secondPresentation) == ([true, false]))
    let secondOrigin = try #require(OnlineDataOrigin.normalizedHTTPS(from: "https://api.vendor-b.test"))
    #expect((OnlineConsentPolicy.allowsNetwork(
      storedValue: defaults.string(forKey: OnlineDataPurpose.translation.defaultsKey),
      purpose: .translation, origin: secondOrigin
    )) == (true))
  }

  @Test
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
    do { _ = try await task.value; Issue.record(Comment(rawValue: "Precancelled task must fail immediately")) }
    catch { #expect(error is CancellationError) }
    #expect(fixture.completions.isEmpty)
    #expect(presentation.isEmpty)
    #expect((defaults.string(forKey: OnlineDataPurpose.translation.defaultsKey)) == nil)
  }

  @Test
  func testOnlyExplicitDenialPersistsDeniedAndSynchronousCompletionCleansUp() async throws {
    let defaults = try isolatedDefaults()
    var dismissals = 0
    var presentation: [Bool] = []
    let manager = OnlineDataConsentManager(defaults: defaults) { _, _, completion in
      completion(.denied)
      return { dismissals += 1 }
    }
    let endpoint = try #require(URL(string: "https://api.vendor-a.test/v1"))
    let allowed = try await manager.requestCancellable(
      .translation, endpoint: endpoint, systemPresentation: { presentation.append($0) }
    )
    #expect(!(allowed))
    #expect((dismissals) == (1))
    #expect((presentation) == ([true, false]))
    let origin = try #require(OnlineDataOrigin.normalizedHTTPS(from: endpoint))
    #expect((OnlineConsentPolicy.allowsNetwork(
      storedValue: defaults.string(forKey: OnlineDataPurpose.translation.defaultsKey),
      purpose: .translation, origin: origin
    )) == (false))
  }
}
