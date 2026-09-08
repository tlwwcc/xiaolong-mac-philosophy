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
