import Foundation

/// Private connection pool. Per-request cancellation never invalidates other requests.
nonisolated final class SharedTranslationConnection: @unchecked Sendable {
    private let session: URLSession
    private let delegate = SharedTranslationPoolDelegate()
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 22
        configuration.timeoutIntervalForResource = 25
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let transfer = SharedTranslationTransfer()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.insert(transfer, id: task.taskIdentifier)
                let id = task.taskIdentifier
                let delegate = delegate
                if transfer.begin(continuation, task: task, cleanup: { delegate.remove(id) }) {
                    task.resume()
                } else {
                    delegate.remove(id)
                    task.cancel()
                }
            }
        } onCancel: { transfer.finish(.failure(CancellationError())) }
    }
}

nonisolated private final class SharedTranslationPoolDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: SharedTranslationTransfer] = [:]
    func insert(_ transfer: SharedTranslationTransfer, id: Int) {
        lock.lock(); transfers[id] = transfer; lock.unlock()
    }
    func remove(_ id: Int) {
        lock.lock(); transfers.removeValue(forKey: id); lock.unlock()
    }
    private func transfer(_ id: Int) -> SharedTranslationTransfer? {
        lock.lock(); defer { lock.unlock() }; return transfers[id]
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never resend source text elsewhere; the fixed endpoint has no legitimate redirect.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(transfer(dataTask.taskIdentifier)?.receive(response) == true ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(dataTask.taskIdentifier)?.receive(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer(task.taskIdentifier)?.complete(error)
    }
}

nonisolated private final class SharedTranslationTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionDataTask?
    private var cleanup: (@Sendable () -> Void)?
    private var response: URLResponse?
    private var data = Data()
    func begin(_ continuation: CheckedContinuation<(Data, URLResponse), Error>,
               task: URLSessionDataTask, cleanup: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock(); continuation.resume(throwing: CancellationError()); return false
        }
        self.continuation = continuation; self.task = task; self.cleanup = cleanup
        lock.unlock()
        return true
    }
    func receive(_ response: URLResponse) -> Bool {
        guard response.expectedContentLength <= 65_536 else {
            finish(.failure(SharedTranslationError.invalidResponse)); return false
        }
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        self.response = response
        return true
    }
    func receive(_ chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard chunk.count <= 65_536 - data.count else {
            lock.unlock(); finish(.failure(SharedTranslationError.invalidResponse)); return
        }
        data.append(chunk); lock.unlock()
    }
    func complete(_ error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock(); let response = response; let data = data; lock.unlock()
        guard let response else { finish(.failure(URLError(.badServerResponse))); return }
        finish(.success((data, response)))
    }
    func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation; self.continuation = nil
        let task = task; self.task = nil
        let cleanup = cleanup; self.cleanup = nil
        data = Data(); response = nil
        lock.unlock()
        cleanup?()
        task?.cancel()
        continuation?.resume(with: result)
    }
}
