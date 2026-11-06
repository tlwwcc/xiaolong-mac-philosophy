import Foundation

/// One process-local preparation. Waiting callers cancel independently of preparation.
nonisolated final class OCRWarmup: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var running = false
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]

    func start(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        running = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            work()
            self.finish()
        }
    }

    private func finish() {
        lock.lock()
        running = false
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.finish() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        waiters.removeValue(forKey: id)
        lock.unlock()
    }

    func waitIfRunning() async throws {
        try Task.checkCancellation()
        let id = UUID()
        let stream = AsyncStream<Void> { continuation in
            // Install termination before registration, so cancellation cannot leave a waiter.
            continuation.onTermination = { @Sendable _ in self.remove(id) }
            lock.lock()
            let shouldWait = running
            if shouldWait { waiters[id] = continuation }
            lock.unlock()
            if !shouldWait { continuation.finish() }
        }
        for await _ in stream {}
        try Task.checkCancellation()
    }
}
