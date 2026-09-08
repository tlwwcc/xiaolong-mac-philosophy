import Foundation

/// A stable owner for one invocation of one Youmu capture mode.
///
/// Mode answers "which shortcut?" while the UUID prevents a delayed callback from an older
/// invocation closing or reviving a newer invocation of that same shortcut.
struct CaptureCommandOwner: Hashable {
    let mode: TranslateMode
    let sessionID: UUID
}

enum CaptureCommandPhase: Hashable {
    case selecting
    case processing
    case presenting
}

struct CaptureCommandSession: Equatable {
    let owner: CaptureCommandOwner
    var phase: CaptureCommandPhase
}

enum CaptureCommandInvalidationPolicy {
    static func modes(
        affectedBy reason: YoumuCommandSessionInvalidationReason
    ) -> Set<TranslateMode> {
        switch reason {
        case .proEntitlementLost:
            return [
                .longScreenshot,
                .selectionReader,
                .imageTranslate,
                .screenshotTranslate,
            ]
        case .screenRecordingPermissionLost:
            return Set(TranslateMode.allCases).subtracting([.pinClipboard])
        case .inputMonitoringPermissionLost:
            return [.longScreenshot]
        case .globalInputOwnershipYielded:
            return Set(TranslateMode.allCases)
        }
    }

    static func phases(
        affectedBy reason: YoumuCommandSessionInvalidationReason
    ) -> Set<CaptureCommandPhase> {
        switch reason {
        case .screenRecordingPermissionLost, .inputMonitoringPermissionLost:
            // Permission changes stop work that could still produce a late result, but preserve
            // completed editors/results so a transient TCC change cannot discard user work.
            return [.selecting, .processing]
        case .proEntitlementLost, .globalInputOwnershipYielded:
            // Pro loss suspends the host hotkeys, so presenting Pro surfaces must close here.
            // Channel yield/shutdown likewise drains every phase.
            return [.selecting, .processing, .presenting]
        }
    }
}

/// O(1) source of truth for the eight Youmu shortcut invocations.
///
/// Sessions are keyed by mode rather than by "last shortcut". Therefore a second invocation of
/// the same mode can cancel only its own work, while a different mode can never invalidate it.
struct CaptureCommandSessionRegistry {
    private var sessions: [TranslateMode: CaptureCommandSession] = [:]

    var count: Int { sessions.count }

    func session(for mode: TranslateMode) -> CaptureCommandSession? {
        sessions[mode]
    }

    func isCurrent(
        _ owner: CaptureCommandOwner,
        phase: CaptureCommandPhase? = nil
    ) -> Bool {
        guard let session = sessions[owner.mode], session.owner == owner else { return false }
        return phase == nil || session.phase == phase
    }

    @discardableResult
    mutating func begin(
        mode: TranslateMode,
        sessionID: UUID = UUID(),
        phase: CaptureCommandPhase = .selecting
    ) -> CaptureCommandOwner? {
        guard sessions[mode] == nil else { return nil }
        let owner = CaptureCommandOwner(mode: mode, sessionID: sessionID)
        sessions[mode] = CaptureCommandSession(owner: owner, phase: phase)
        return owner
    }

    /// Removes the current invocation for this mode before its UI teardown begins. This makes a
    /// real third key press immediately eligible even though AppKit objects remain retained for
    /// their safety delay.
    mutating func take(mode: TranslateMode) -> CaptureCommandSession? {
        sessions.removeValue(forKey: mode)
    }

    /// Removes only this exact generation. A late callback from an older owner is a no-op.
    mutating func take(owner: CaptureCommandOwner) -> CaptureCommandSession? {
        guard isCurrent(owner) else { return nil }
        return sessions.removeValue(forKey: owner.mode)
    }

    /// Atomically invalidates only modes affected by a host lifecycle loss. Removing all intents
    /// before any AppKit teardown makes every delayed callback fail closed.
    mutating func take(
        modes: Set<TranslateMode>,
        phases: Set<CaptureCommandPhase>
    ) -> [CaptureCommandSession] {
        var removed: [CaptureCommandSession] = []
        removed.reserveCapacity(modes.count)
        for mode in modes {
            guard let session = sessions[mode], phases.contains(session.phase) else { continue }
            sessions.removeValue(forKey: mode)
            removed.append(session)
        }
        return removed
    }

    mutating func takeAll() -> [CaptureCommandSession] {
        let removed = Array(sessions.values)
        sessions.removeAll(keepingCapacity: true)
        return removed
    }

    @discardableResult
    mutating func transition(
        _ owner: CaptureCommandOwner,
        to phase: CaptureCommandPhase
    ) -> Bool {
        guard var session = sessions[owner.mode], session.owner == owner else { return false }
        session.phase = phase
        sessions[owner.mode] = session
        return true
    }

    @discardableResult
    mutating func finish(_ owner: CaptureCommandOwner) -> Bool {
        take(owner: owner) != nil
    }
}
