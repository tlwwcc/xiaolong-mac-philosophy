import AVFoundation
import Foundation
import XCTest
@testable import YoumuFeature

@MainActor
final class EdgeSpeechRoutingTests: XCTestCase {
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Speech did not reach the expected state")
    }

    func testV2HandshakeMatchesIndependentProtocolVectors() {
        let vectors: [(TimeInterval, String)] = [
            (0, "52BC7A17B50DFEC9-28C4394775C8751CD2F6859C030C06DB1489ACAB3B3A7651831FC26895177ED6"),
            (1760000000, "6D50DDDB91812C33-DD68EFB01898B0750C9797D51A5FF93471DFDAE6888A1039D532CBDCCE54545D"),
            (1792076400, "7ADC1385CCAE395D-41905C8EDC1A18FF249382E1004F183991A8D133F1E2AC38215C4251210E8881"),
        ]
        for (seconds, expected) in vectors {
            XCTAssertEqual(EdgeOnlineSpeechClient.secMSGECToken(at: Date(timeIntervalSince1970: seconds)), expected)
        }
        XCTAssertEqual(
            EdgeOnlineSpeechClient.secMSGECToken(at: Date(timeIntervalSince1970: 1792076400)),
            EdgeOnlineSpeechClient.secMSGECToken(at: Date(timeIntervalSince1970: 1792076401))
        )
    }

    func testEverySelectedChineseVoiceReachesSSMLAndTextStaysEscaped() {
        for voice in EdgeSpeechVoice.allCases {
            let identifier = EdgeOnlineSpeechClient.voiceIdentifier(for: "zh-CN", preferredChineseVoice: voice)
            let frame = EdgeOnlineSpeechClient.ssmlMessage(text: "A < B & C", voice: identifier, locale: "zh-CN")
            XCTAssertEqual(identifier, voice.rawValue)
            XCTAssertTrue(frame.contains("<voice name='\(voice.rawValue)'>"))
            XCTAssertTrue(frame.contains("A &lt; B &amp; C"))
        }
    }

    func testDisplayedVoiceFollowsActualLanguageRoute() {
        for (language, identifier) in [
            ("zh-CN", "zh-CN-XiaoxiaoNeural"),
            ("en-US", "en-US-EmmaMultilingualNeural"),
            ("ja-JP", "ja-JP-NanamiNeural"),
            ("zh-TW", "zh-TW-HsiaoChenNeural"),
        ] {
            let service = SpeechService(
                loadSettings: { var s = AppSettings(); s.speechBackend = .edgeOnline; return s },
                requestConsent: { false },
                synthesize: { _, _, _ in throw URLError(.badURL) },
                reportNotice: { _ in }
            )
            service.speak(text: "Test", language: language, preferredVoice: .xiaoxiao)
            XCTAssertEqual(service.snapshot.voiceIdentifier, identifier)
            XCTAssertEqual(service.snapshot.backendDescription,
                language == "zh-CN" ? "Edge · 晓晓 · 自然温暖" : "Edge 神经声音 · 自然朗读")
            service.stop()
        }
    }

    func testExplicitEdgeFailureNeverStartsLocalSpeechAndCanRetry() async throws {
        var attempts = 0, localStarts = 0
        var notices: [String] = []
        let service = SpeechService(
            loadSettings: { var s = AppSettings(); s.speechBackend = .edgeOnline; s.speechVoice = .xiaoxiao; return s },
            requestConsent: { true },
            synthesize: { _, _, voice in
                XCTAssertEqual(voice, .xiaoxiao)
                attempts += 1
                throw URLError(.badServerResponse)
            },
            reportNotice: { notices.append($0) },
            localSpeechHandler: { _ in localStarts += 1 }
        )
        service.speak(text: "公开的测试句", language: "zh-CN")
        try await waitFor { service.state == .failed }
        XCTAssertEqual(service.backend, .edge)
        XCTAssertEqual(localStarts, 0)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertEqual(service.snapshot.notice, "Edge 声音暂不可用，请重试")
        service.togglePause()
        try await waitFor { service.state == .failed && attempts == 2 }
        XCTAssertEqual(localStarts, 0)
        XCTAssertEqual(notices.count, 2)
        service.stop()
    }

    func testAutomaticFailureAnnouncesActualLocalProvider() async throws {
        var localStarts = 0
        var notices: [String] = []
        let service = SpeechService(
            loadSettings: { var s = AppSettings(); s.speechBackend = .automatic; return s },
            requestConsent: { true },
            synthesize: { _, _, _ in throw URLError(.notConnectedToInternet) },
            reportNotice: { notices.append($0) },
            localSpeechHandler: { _ in localStarts += 1 }
        )
        service.speak(text: "公开的测试句", language: "zh-CN")
        try await waitFor { localStarts == 1 }
        XCTAssertEqual(service.backend, .local)
        XCTAssertEqual(service.state, .playing)
        XCTAssertEqual(service.snapshot.notice, "Edge 暂不可用，已改用 Mac 本机声音")
        XCTAssertEqual(notices.count, 1)
        service.stop()
    }

    func testMacProviderDoesNotRequestConsentOrSendText() async {
        var localStarts = 0
        let service = SpeechService(
            loadSettings: { var s = AppSettings(); s.speechBackend = .macLocal; return s },
            requestConsent: { XCTFail("Local provider must not request online permission"); return false },
            synthesize: { _, _, _ in XCTFail("Local text must stay local"); throw URLError(.badURL) },
            reportNotice: { _ in XCTFail("Local provider should not report Edge failure") },
            localSpeechHandler: { _ in localStarts += 1 }
        )
        service.speak(text: "本机测试", language: "zh-CN")
        XCTAssertEqual(localStarts, 1)
        XCTAssertEqual(service.backend, .local)
        XCTAssertNil(service.snapshot.notice)
        service.stop()
    }

    func testDeniedConsentPreservesBothExplicitAndAutomaticChoices() async throws {
        for preference in [SpeechBackendPreference.edgeOnline, .automatic] {
            var sends = 0, localStarts = 0
            let service = SpeechService(
                loadSettings: { var s = AppSettings(); s.speechBackend = preference; return s },
                requestConsent: { false },
                synthesize: { _, _, _ in sends += 1; throw URLError(.badURL) },
                reportNotice: { _ in },
                localSpeechHandler: { _ in localStarts += 1 }
            )
            service.speak(text: "拒绝后不得发送", language: "zh-CN")
            try await waitFor { service.state != .loading }
            XCTAssertEqual(sends, 0)
            XCTAssertEqual(localStarts, preference == .automatic ? 1 : 0)
            XCTAssertEqual(service.state, preference == .automatic ? .playing : .failed)
            XCTAssertNotNil(service.snapshot.notice)
            service.stop()
        }
    }

    func testInvalidEdgeAudioFailsWithoutSwitchingVoice() async throws {
        var localStarts = 0
        let service = SpeechService(
            loadSettings: { var s = AppSettings(); s.speechBackend = .edgeOnline; return s },
            requestConsent: { true },
            synthesize: { _, _, _ in EdgeSpeechResult(audio: Data("not audio".utf8), wordBoundaries: []) },
            reportNotice: { _ in },
            localSpeechHandler: { _ in localStarts += 1 }
        )
        service.speak(text: "公开的测试句", language: "zh-CN")
        try await waitFor { service.state == .failed }
        XCTAssertEqual(localStarts, 0)
        XCTAssertEqual(service.backend, .edge)
        XCTAssertFalse(service.snapshot.canSeek)
        service.stop()
    }

    func testImmediateStopDoesNotAskForConsentOrSendText() async throws {
        var requests = 0
        let service = SpeechService(
            loadSettings: { AppSettings() },
            requestConsent: { requests += 1; return true },
            synthesize: { _, _, _ in XCTFail("Stopped text must not be sent"); throw URLError(.badURL) },
            reportNotice: { _ in XCTFail("Stopped request must stay silent") }
        )
        service.speak(text: "立即停止", language: "zh-CN")
        service.stop()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(requests, 0)
        XCTAssertNil(service.snapshot.voiceIdentifier)
        XCTAssertEqual(service.snapshot.backendDescription, "声音未启动")
    }

    func testStoppedRequestCannotReportFailureOrFallbackLater() async throws {
        var started = false, localStarts = 0, notices = 0
        let service = SpeechService(
            loadSettings: { AppSettings() },
            requestConsent: { true },
            synthesize: { _, _, _ in
                started = true
                try? await Task.sleep(nanoseconds: 100_000_000)
                throw URLError(.badServerResponse)
            },
            reportNotice: { _ in notices += 1 },
            localSpeechHandler: { _ in localStarts += 1 }
        )
        service.speak(text: "停止后不复活", language: "zh-CN")
        try await waitFor { started }
        service.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.backend)
        XCTAssertEqual(localStarts, 0)
        XCTAssertEqual(notices, 0)
    }
}
