import Foundation

/// Session memory only. Keys retain the complete ordered batch and target language.
/// Expiration governs reuse; retained bytes are bounded independently of expiry.
@MainActor
final class TranslationResponseCache {
    struct Key: Hashable {
        let texts: [String]
        let target: String
    }
    private struct Entry {
        let translations: [String]
        let expires: TimeInterval
        let cost: Int
    }
    private let capacity: Int
    private let byteLimit: Int
    private let lifetime: TimeInterval
    private let now: () -> TimeInterval
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private(set) var retainedBytes = 0
    var count: Int { entries.count }

    init(capacity: Int = 64, byteLimit: Int = 262_144, lifetime: TimeInterval = 120,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = max(0, capacity)
        self.byteLimit = max(0, byteLimit)
        self.lifetime = max(0, lifetime)
        self.now = now
    }

    private func remove(_ key: Key) {
        if let previous = entries.removeValue(forKey: key) { retainedBytes -= previous.cost }
        order.removeAll { $0 == key }
    }

    private func expire(at time: TimeInterval) {
        for key in order where entries[key].map({ $0.expires <= time }) == true { remove(key) }
    }

    func value(for key: Key) -> [String]? {
        expire(at: now())
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.translations
    }

    func insert(_ translations: [String], for key: Key) {
        let time = now()
        expire(at: time)
        remove(key)
        let cost = key.target.utf8.count
            + key.texts.reduce(0) { $0 + $1.utf8.count }
            + translations.reduce(0) { $0 + $1.utf8.count }
        guard capacity > 0, lifetime > 0, cost <= byteLimit else { return }
        while entries.count >= capacity || retainedBytes + cost > byteLimit {
            guard let oldest = order.first else { return }
            remove(oldest)
        }
        entries[key] = Entry(translations: translations, expires: time + lifetime, cost: cost)
        retainedBytes += cost
        order.append(key)
    }
}
