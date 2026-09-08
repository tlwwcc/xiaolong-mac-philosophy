import Foundation
import OSLog

enum PrivacySafeLog {
    private static let logger = Logger(
        subsystem: "cn.tlww.aixlg.hotkeys.feature.youmu",
        category: "runtime"
    )
    private static let longCaptureLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/aixlg-hotkeys/long-capture.jsonl")
    private static let maximumLongCaptureLogBytes: UInt64 = 1_048_576

    static func event(_ name: String, error: Error? = nil, metadata: [String: Int] = [:]) {
        let safeName = sanitized(name)
        var fields = metadata.keys.sorted().map { "\(sanitized($0))=\(metadata[$0] ?? 0)" }
        var persistedFields = metadata.reduce(into: [String: Int]()) { result, pair in
            result[sanitized(pair.key)] = pair.value
        }
        if let nsError = error as NSError? {
            fields.append("errorDomain=\(sanitized(nsError.domain))")
            fields.append("errorCode=\(nsError.code)")
            persistedFields["errorCode"] = nsError.code
        }
        let suffix = fields.isEmpty ? "" : " " + fields.joined(separator: " ")
        let message = "[YoumuFeature] \(safeName)\(suffix)"
        logger.notice("\(message, privacy: .public)")
        if safeName.hasPrefix("long_capture") {
            appendLongCaptureEvent(name: safeName, metadata: persistedFields)
        }
    }

    /// 长截图是跨窗口、间歇性故障：在 unified log 之外保留一份小型环形真相链。
    /// 只写固定事件名与整数元数据，不写 URL、窗口标题、页面文字或图像。
    static func appendLongCaptureEvent(
        name: String,
        metadata: [String: Int],
        logURL: URL? = nil,
        maximumBytes: UInt64? = nil
    ) {
        let fileManager = FileManager.default
        let resolvedLogURL = logURL ?? longCaptureLogURL
        let directory = resolvedLogURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try rotateLongCaptureLogIfNeeded(
                fileManager: fileManager,
                logURL: resolvedLogURL,
                maximumBytes: maximumBytes ?? maximumLongCaptureLogBytes
            )

            let record: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "event": name,
                "metadata": metadata,
            ]
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0A)
            if !fileManager.fileExists(atPath: resolvedLogURL.path) {
                fileManager.createFile(
                    atPath: resolvedLogURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            let handle = try FileHandle(forWritingTo: resolvedLogURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // 诊断绝不得影响用户的截图主路径。
        }
    }

    private static func rotateLongCaptureLogIfNeeded(
        fileManager: FileManager,
        logURL: URL,
        maximumBytes: UInt64
    ) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: logURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= maximumBytes else { return }

        let firstBackup = logURL.appendingPathExtension("1")
        let secondBackup = logURL.appendingPathExtension("2")
        if fileManager.fileExists(atPath: secondBackup.path) {
            try fileManager.removeItem(at: secondBackup)
        }
        if fileManager.fileExists(atPath: firstBackup.path) {
            try fileManager.moveItem(at: firstBackup, to: secondBackup)
        }
        if fileManager.fileExists(atPath: logURL.path) {
            try fileManager.moveItem(at: logURL, to: firstBackup)
        }
    }

    private static func sanitized(_ value: String) -> String {
        value.unicodeScalars.map {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
                ? String($0) : "_"
        }.joined()
    }
}
