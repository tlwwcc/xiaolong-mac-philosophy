import AppKit
import Darwin
import Foundation
import Security

private final class TrustedUpdateRedirectDelegate: NSObject, URLSessionTaskDelegate {
  private let allowsURL: (URL) -> Bool
  private let lock = NSLock()
  private var rejectedRedirect = false

  init(allowsURL: @escaping (URL) -> Bool) {
    self.allowsURL = allowsURL
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let originalHost = task.originalRequest?.url?.host?.lowercased()
    guard let url = request.url,
      url.host?.lowercased() == originalHost,
      allowsURL(url)
    else {
      lock.lock()
      rejectedRedirect = true
      lock.unlock()
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  func resetRejectedRedirect() {
    lock.lock()
    rejectedRedirect = false
    lock.unlock()
  }

  func consumeRejectedRedirect() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let rejected = rejectedRedirect
    rejectedRedirect = false
    return rejected
  }
}

private struct AppUpdateInstallerResult: Codable {
  let outcome: String
  let targetBuild: String
  let message: String
}

private struct AppBundleFileIdentity: Equatable {
  let systemNumber: UInt64
  let fileNumber: UInt64
}

private struct SemanticSystemVersion: Equatable, Comparable {
  let major: Int
  let minor: Int
  let patch: Int

  init?(_ text: String) {
    guard !text.isEmpty,
      text == text.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    let components = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(components.count) else { return nil }
    var numbers: [Int] = []
    for component in components {
      guard !component.isEmpty,
        component.utf8.allSatisfy({ (48...57).contains($0) }),
        let number = Int(component)
      else { return nil }
      numbers.append(number)
    }
    while numbers.count < 3 {
      numbers.append(0)
    }
    major = numbers[0]
    minor = numbers[1]
    patch = numbers[2]
  }

  init(_ version: OperatingSystemVersion) {
    major = version.majorVersion
    minor = version.minorVersion
    patch = version.patchVersion
  }

  static func < (lhs: SemanticSystemVersion, rhs: SemanticSystemVersion) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    return lhs.patch < rhs.patch
  }

  var displayString: String {
    "\(major).\(minor).\(patch)"
  }
}

struct AppUpdateManifest: Codable, Equatable {
  let schema: Int
  let app: String
  let bundleIdentifier: String
  let version: String
  let build: String
  let channel: String
  let url: String
  let sha256: String
  let minimumSystemVersion: String
  let publishedAt: String
  let notes: String

  var buildNumber: Int {
    Int(build) ?? 0
  }

  var displayVersion: String {
    CustomerVersionFormatter.appVersion(version: version, build: build)
  }
}

struct StagedAppUpdate {
  let manifest: AppUpdateManifest
  let verifiedReleasePublishedAt: String
  let stagedAppURL: URL
  let workDirectoryURL: URL
  let installerScriptURL: URL
  let downloadEvidence: AppUpdateDownloadEvidence
  let requiredTeamIdentifier: String
  let designatedRequirement: String
}

struct InstalledAppUpdate {
  let manifest: AppUpdateManifest
  let installedAppURL: URL
  let relaunchScriptURL: URL
}

enum AppUpdateInstallEvent: Equatable {
  case requestingAuthorization
  case replacing
}

struct AppUpdateDownloadProgress: Equatable {
  let bytesWritten: Int64
  let expectedBytes: Int64?

  var fractionCompleted: Double? {
    guard let expectedBytes, expectedBytes > 0 else { return nil }
    return min(max(Double(bytesWritten) / Double(expectedBytes), 0), 1)
  }
}

struct AppUpdateDownloadEvidence: Equatable {
  let bytesWritten: Int64
  let expectedBytes: Int64?
  let supportsByteRanges: Bool
}

enum AppUpdateDownloadEvent: Equatable {
  case downloading(AppUpdateDownloadProgress)
  case verifying
}

struct AppUpdateSecurityEvidence: Equatable {
  let isDeveloperIDApplication: Bool
  let teamIdentifier: String?
  let satisfiesDesignatedRequirement: Bool
  let hasNotarizationTicket: Bool
  let passesNotarizedGatekeeperAssessment: Bool
}

enum AppUpdaterError: LocalizedError {
  case disabledForBuildChannel
  case legacyInstallerRetired
  case invalidManifestURL
  case invalidDownloadURL
  case untrustedDownloadHost
  case untrustedDownloadPath
  case untrustedRedirect
  case invalidSHA
  case emptyManifest
  case invalidHTTPStatus(Int)
  case updateAlreadyInProgress
  case updateNotNewer
  case updateNotEntitled
  case emptyDownload
  case downloadTooLarge
  case invalidDownloadResponse
  case downloadLengthMismatch(expected: Int64, actual: Int64)
  case checksumMismatch(expected: String, actual: String)
  case missingAppBundle
  case bundleMismatch(expected: String, actual: String)
  case buildMismatch(expected: String, actual: String)
  case versionMismatch(expected: String, actual: String)
  case invalidMinimumSystemVersion(String)
  case minimumSystemVersionMismatch(expected: String, actual: String)
  case minimumSystemVersionNotSupported(required: String, current: String)
  case formalReleaseRequired
  case releasePublishedAtMismatch(expected: String, actual: String)
  case codeSignatureInvalid
  case developerIDRequired
  case currentCodeIdentityUnavailable
  case designatedRequirementMismatch
  case teamIdentifierMismatch(expected: String, actual: String)
  case notarizationRequired
  case unsupportedInstallLocation
  case installationAuthorizationDenied
  case installationRollbackFailed(recoveryPath: String?)
  case commandTimedOut(String)
  case customerFacingFailure(String)
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .disabledForBuildChannel:
      return "开发版已关闭线上更新与安装。"
    case .legacyInstallerRetired:
      return "当前版本已改用 Sparkle 安全更新，旧更新器已永久停用。"
    case .invalidManifestURL:
      return "更新清单地址无效。"
    case .invalidDownloadURL:
      return "更新包地址无效。"
    case .untrustedDownloadHost:
      return "更新包不在允许的官方精确域名下。"
    case .untrustedDownloadPath:
      return "更新包不在允许的官方版本目录下。"
    case .untrustedRedirect:
      return "更新服务器尝试跳转到未授权地址，已停止下载。"
    case .invalidSHA:
      return "更新清单的完整性校验信息格式无效。"
    case .emptyManifest:
      return "更新清单为空。"
    case .invalidHTTPStatus(let status):
      return "更新服务器返回异常状态：HTTP \(status)。"
    case .updateAlreadyInProgress:
      return "已有更新任务正在进行，请等待当前任务结束。"
    case .updateNotNewer:
      return "更新包构建号不高于当前版本，已拒绝安装。"
    case .updateNotEntitled:
      return "这个版本超出当前许可的更新权范围。"
    case .emptyDownload:
      return "更新包为空，已停止安装。"
    case .downloadTooLarge:
      return "更新包超过 2 GB 安全上限，已停止下载。"
    case .invalidDownloadResponse:
      return "更新服务器未返回可验证的完整 ZIP。"
    case .downloadLengthMismatch(let expected, let actual):
      return "更新包长度校验失败：服务器声明 \(expected) 字节，实际 \(actual) 字节。"
    case .checksumMismatch:
      return "更新包完整性校验未通过，已停止安装。"
    case .missingAppBundle:
      return "更新包里没有找到\(AppRuntimeIdentity.current.appBundleName)。"
    case .bundleMismatch:
      return "更新包不是当前软件的正式安装包，已停止安装。"
    case .buildMismatch:
      return "更新包构建号与更新清单不一致，已停止安装。"
    case .versionMismatch:
      return "更新包版本号与更新清单不一致，已停止安装。"
    case .invalidMinimumSystemVersion:
      return "更新包的最低 macOS 版本信息无效，已停止安装。"
    case .minimumSystemVersionMismatch:
      return "更新包的最低 macOS 版本与更新清单不一致，已停止安装。"
    case .minimumSystemVersionNotSupported(let required, let current):
      return "新版本要求 macOS \(required) 或更高，当前是 macOS \(current)。"
        + "已停止更新，当前版本保持不变。"
    case .formalReleaseRequired:
      return "更新包不是启用正式许可与发行加固的候选，已拒绝安装。"
    case .releasePublishedAtMismatch:
      return "更新包发布日期与更新清单不一致，已停止安装。"
    case .codeSignatureInvalid:
      return "更新包代码签名无效，已拒绝安装。"
    case .developerIDRequired:
      return "更新包不是官网正式签名版本，已停止安装。请从官网下载正式版。"
    case .currentCodeIdentityUnavailable:
      return "无法读取当前 App 的正式签名身份，已停止本次更新。当前版本保持不变。"
    case .designatedRequirementMismatch:
      return "更新包的正式签名身份与当前 App 不一致，已停止安装。请从官网下载正式版覆盖一次。"
    case .teamIdentifierMismatch:
      return "更新包的正式签名团队与当前 App 不一致，已停止安装。请从官网下载正式版。"
    case .notarizationRequired:
      return "正式版只接受已通过 macOS 安全公证校验的更新包。"
    case .unsupportedInstallLocation:
      return "当前 App 不在“应用程序”文件夹中，已停止自动替换。请从官网下载正式版并拖入“应用程序”。"
    case .installationAuthorizationDenied:
      return "没有获得替换“应用程序”中旧版本的授权，当前版本保持不变。"
    case .installationRollbackFailed(let recoveryPath):
      let recoveryDetail = recoveryPath == nil ? "" : "系统已保留一份可恢复的旧版备份。"
      return "更新替换失败，磁盘上的 App 未能自动恢复。当前版本仍在运行，请不要退出。"
        + recoveryDetail + "请从官网下载正式版重新安装。"
    case .commandTimedOut:
      return "更新包处理超时，已停止本次更新。当前版本保持不变，请稍后重试。"
    case .customerFacingFailure(let message):
      return message
    case .commandFailed:
      return "更新包处理失败，已停止本次更新。当前版本保持不变；如仍失败，请从官网下载正式版覆盖一次。"
    }
  }

  static func customerDescription(for error: Error, fallback: String) -> String {
    guard let updaterError = error as? AppUpdaterError else { return fallback }
    return updaterError.localizedDescription
  }
}

final class AppUpdater {
  static let shared = AppUpdater()

  private static let maximumInstallerResultBytes = 64 * 1024
  private static let safeLegacyRelaunchFailureMessage =
    "更新已安装，但自动重启失败。请从“应用程序”手动打开小龙哥Mac哲学。"
  private static let genericInstallerFailureMessage =
    "上次更新没有完成。当前版本仍在运行；请手动重试，如仍失败请从官网下载正式版覆盖一次。"

  private struct FormalUpdateRequirement {
    let teamIdentifier: String
    let designatedRequirement: String
  }

  private struct CodeSigningIdentity {
    let teamIdentifier: String
    let isDeveloperIDApplication: Bool
  }

  private let identity: AppRuntimeIdentity = {
    #if AIXLG_UPDATE_FIXTURE
      return AppRuntimeIdentity(channel: .stable)
    #else
      return AppRuntimeIdentity.current
    #endif
  }()
  private var appName: String { identity.appBundleName }
  private var installURL: URL { identity.installURL }
  private let requestTimeout: TimeInterval = 12
  private let trustedManifestHost = "aixlg.com"
  private let trustedManifestPath = "/updates/bridge-latest.json"
  private let maximumManifestBytes = 262_144
  private let maximumUpdateBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
  private let operationLock = NSLock()
  private var activeOperationID: UUID?
  private var oversizedOperationID: UUID?
  private var progressObservation: NSKeyValueObservation?

  private lazy var trustedDownloadHosts = Set(
    configuredStringArray(
      key: "AIXLGUpdateDownloadHosts",
      fallback: ["download.aixlg.com", "aixlg.com", "www.aixlg.com"]
    ).compactMap(Self.normalizedExactHost))
  private lazy var trustedCOSDownloadHosts = Set(
    configuredStringArray(
      key: "AIXLGUpdateCOSDownloadHosts",
      fallback: ["download.aixlg.com"]
    ).compactMap(Self.normalizedExactHost))
  private lazy var trustedDownloadPathPrefixes = configuredStringArray(
    key: "AIXLGUpdateDownloadPathPrefixes",
    fallback: ["/releases/"]
  ).filter(Self.isSafePathPrefix)

  private lazy var manifestRedirectDelegate = TrustedUpdateRedirectDelegate { [weak self] url in
    self?.isTrustedManifestURL(url) == true
  }
  private lazy var downloadRedirectDelegate = TrustedUpdateRedirectDelegate { [weak self] url in
    (try? self?.validateDownloadURL(url)) != nil
  }
  private lazy var manifestSession = makeSession(delegate: manifestRedirectDelegate)
  private lazy var downloadSession = makeSession(delegate: downloadRedirectDelegate)

  private init() {}

  var manifestURL: URL? {
    guard identity.allowsOnlineUpdates, legacyInstallerAllowed else { return nil }
    let configured = Bundle.main.object(forInfoDictionaryKey: "AIXLGUpdateManifestURL") as? String
    return URL(string: configured ?? "https://aixlg.com/updates/bridge-latest.json")
  }

  func checkForUpdate(
    bypassingCache: Bool = true,
    completion: @escaping (Result<AppUpdateManifest, Error>) -> Void
  ) {
    guard identity.allowsOnlineUpdates else {
      completion(.failure(AppUpdaterError.disabledForBuildChannel))
      return
    }
    guard legacyInstallerAllowed else {
      completion(.failure(AppUpdaterError.legacyInstallerRetired))
      return
    }
    checkForUpdate(
      manifestURL: manifestURL,
      bypassingCache: bypassingCache,
      completion: completion)
  }

  func checkForUpdate(
    manifestURL: URL?,
    bypassingCache: Bool = true,
    completion: @escaping (Result<AppUpdateManifest, Error>) -> Void
  ) {
    guard identity.allowsOnlineUpdates else {
      completion(.failure(AppUpdaterError.disabledForBuildChannel))
      return
    }
    guard legacyInstallerAllowed else {
      completion(.failure(AppUpdaterError.legacyInstallerRetired))
      return
    }
    guard var requestURL = manifestURL else {
      completion(.failure(AppUpdaterError.invalidManifestURL))
      return
    }
    guard isTrustedManifestURL(requestURL) else {
      completion(.failure(AppUpdaterError.invalidManifestURL))
      return
    }
    guard let operationID = beginOperation() else {
      completion(.failure(AppUpdaterError.updateAlreadyInProgress))
      return
    }
    manifestRedirectDelegate.resetRejectedRedirect()

    let finish: (Result<AppUpdateManifest, Error>) -> Void = { result in
      self.finishOperation(operationID)
      completion(result)
    }

    if bypassingCache {
      requestURL = Self.cacheBustedURL(from: requestURL)
    }
    var request = URLRequest(
      url: requestURL,
      cachePolicy: bypassingCache
        ? .reloadIgnoringLocalAndRemoteCacheData : .useProtocolCachePolicy,
      timeoutInterval: requestTimeout)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if bypassingCache {
      request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
      request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    }

    manifestSession.dataTask(with: request) { data, response, error in
      if let error {
        if self.manifestRedirectDelegate.consumeRejectedRedirect() {
          finish(.failure(AppUpdaterError.untrustedRedirect))
        } else {
          finish(.failure(error))
        }
        return
      }
      do {
        if self.manifestRedirectDelegate.consumeRejectedRedirect() {
          throw AppUpdaterError.untrustedRedirect
        }
        if let httpResponse = response as? HTTPURLResponse,
          !(200...299).contains(httpResponse.statusCode)
        {
          throw AppUpdaterError.invalidHTTPStatus(httpResponse.statusCode)
        }
        guard let finalURL = response?.url, self.isTrustedManifestURL(finalURL) else {
          throw AppUpdaterError.invalidManifestURL
        }
        guard let data, !data.isEmpty else {
          throw AppUpdaterError.emptyManifest
        }
        guard data.count <= self.maximumManifestBytes else {
          throw AppUpdaterError.customerFacingFailure("更新清单超过 256 KB，已拒绝。")
        }
        let manifest = try self.decodeAndValidateManifest(data)
        finish(.success(manifest))
      } catch {
        finish(.failure(error))
      }
    }.resume()
  }

  func decodeAndValidateManifest(_ data: Data) throws -> AppUpdateManifest {
    let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: data)
    try validateManifest(manifest)
    return manifest
  }

  func isNewer(_ manifest: AppUpdateManifest, thanCurrentBuild currentBuild: Int) -> Bool {
    manifest.buildNumber > currentBuild
  }

  func downloadAndStage(
    manifest: AppUpdateManifest,
    eligibilityCheck: @escaping (String) -> Bool,
    eventHandler: @escaping (AppUpdateDownloadEvent) -> Void = { _ in },
    completion: @escaping (Result<StagedAppUpdate, Error>) -> Void
  ) {
    guard identity.allowsOnlineUpdates else {
      completion(.failure(AppUpdaterError.disabledForBuildChannel))
      return
    }
    guard legacyInstallerAllowed else {
      completion(.failure(AppUpdaterError.legacyInstallerRetired))
      return
    }
    guard let downloadURL = URL(string: manifest.url) else {
      completion(.failure(AppUpdaterError.invalidDownloadURL))
      return
    }

    do {
      try validateManifest(manifest)
      guard isNewer(manifest, thanCurrentBuild: currentBuildNumber) else {
        throw AppUpdaterError.updateNotNewer
      }
      guard eligibilityCheck(manifest.publishedAt) else {
        throw AppUpdaterError.updateNotEntitled
      }
    } catch {
      completion(.failure(error))
      return
    }
    guard let operationID = beginOperation() else {
      completion(.failure(AppUpdaterError.updateAlreadyInProgress))
      return
    }
    downloadRedirectDelegate.resetRejectedRedirect()

    let request: URLRequest
    do {
      request = try makeDownloadRequest(for: downloadURL)
    } catch {
      finishOperation(operationID)
      completion(.failure(error))
      return
    }

    let task = downloadSession.downloadTask(with: request) { temporaryURL, response, error in
      if let error {
        let resultError: Error
        if self.downloadRedirectDelegate.consumeRejectedRedirect() {
          resultError = AppUpdaterError.untrustedRedirect
        } else if self.operationExceededSizeLimit(operationID) {
          resultError = AppUpdaterError.downloadTooLarge
        } else {
          resultError = error
        }
        self.finishOperation(operationID)
        completion(.failure(resultError))
        return
      }
      guard let temporaryURL else {
        self.finishOperation(operationID)
        completion(.failure(AppUpdaterError.customerFacingFailure("更新包下载失败。")))
        return
      }

      do {
        if self.downloadRedirectDelegate.consumeRejectedRedirect() {
          throw AppUpdaterError.untrustedRedirect
        }
        guard let httpResponse = response as? HTTPURLResponse,
          let finalURL = httpResponse.url
        else {
          throw AppUpdaterError.invalidDownloadURL
        }
        try self.validateDownloadURL(finalURL)
        let fileSize = try self.fileSize(at: temporaryURL)
        guard fileSize <= self.maximumUpdateBytes else {
          throw AppUpdaterError.downloadTooLarge
        }
        let downloadEvidence = try Self.validateDownloadResponse(
          httpResponse,
          fileSize: fileSize)
        eventHandler(
          .downloading(
            AppUpdateDownloadProgress(
              bytesWritten: downloadEvidence.bytesWritten,
              expectedBytes: downloadEvidence.expectedBytes)))
        eventHandler(.verifying)
        guard eligibilityCheck(manifest.publishedAt) else {
          throw AppUpdaterError.updateNotEntitled
        }
        let staged = try self.stageDownloadedUpdate(
          temporaryURL,
          manifest: manifest,
          downloadEvidence: downloadEvidence)
        guard eligibilityCheck(staged.verifiedReleasePublishedAt) else {
          try? FileManager.default.removeItem(at: staged.workDirectoryURL)
          throw AppUpdaterError.updateNotEntitled
        }
        self.finishOperation(operationID)
        completion(.success(staged))
      } catch {
        self.finishOperation(operationID)
        completion(.failure(error))
      }
    }
    observeProgress(
      of: task,
      operationID: operationID,
      eventHandler: eventHandler)
    task.resume()
  }

  #if AIXLG_UPDATE_FIXTURE
    func launchInstaller(
      _ staged: StagedAppUpdate,
      eligibilityCheck: (String) -> Bool
    ) throws {
      guard identity.allowsOnlineUpdates else {
        throw AppUpdaterError.disabledForBuildChannel
      }
      guard eligibilityCheck(staged.verifiedReleasePublishedAt) else {
        throw AppUpdaterError.updateNotEntitled
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = [staged.installerScriptURL.path]
      try process.run()
    }
  #endif

  /// Replaces the installed bundle before the current process exits. A standard account receives
  /// the native macOS replace-file authorization prompt instead of silently reopening the old app.
  func installStagedUpdate(
    _ staged: StagedAppUpdate,
    eligibilityCheck: @escaping (String) -> Bool,
    eventHandler: @escaping (AppUpdateInstallEvent) -> Void = { _ in },
    completion: @escaping (Result<InstalledAppUpdate, Error>) -> Void
  ) {
    guard identity.allowsOnlineUpdates else {
      try? FileManager.default.removeItem(at: staged.workDirectoryURL)
      completion(.failure(AppUpdaterError.disabledForBuildChannel))
      return
    }
    guard legacyInstallerAllowed else {
      try? FileManager.default.removeItem(at: staged.workDirectoryURL)
      completion(.failure(AppUpdaterError.legacyInstallerRetired))
      return
    }
    guard eligibilityCheck(staged.verifiedReleasePublishedAt) else {
      try? FileManager.default.removeItem(at: staged.workDirectoryURL)
      completion(.failure(AppUpdaterError.updateNotEntitled))
      return
    }

    let targetURL: URL
    do {
      targetURL = try resolvedUpdateTargetURL()
    } catch {
      try? FileManager.default.removeItem(at: staged.workDirectoryURL)
      completion(.failure(error))
      return
    }
    guard let operationID = beginOperation() else {
      try? FileManager.default.removeItem(at: staged.workDirectoryURL)
      completion(.failure(AppUpdaterError.updateAlreadyInProgress))
      return
    }

    let finish: (Result<InstalledAppUpdate, Error>) -> Void = { result in
      self.finishOperation(operationID)
      completion(result)
    }
    let replace: (FileManager) -> Void = { manager in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          guard eligibilityCheck(staged.verifiedReleasePublishedAt) else {
            throw AppUpdaterError.updateNotEntitled
          }
          eventHandler(.replacing)
          let installed = try self.replaceStagedUpdate(
            staged,
            at: targetURL,
            fileManager: manager)
          finish(.success(installed))
        } catch {
          if case AppUpdaterError.installationRollbackFailed = error {
            // Keep staging evidence if even the rollback could not restore a verified App.
          } else {
            try? FileManager.default.removeItem(at: staged.workDirectoryURL)
          }
          finish(.failure(error))
        }
      }
    }

    if Self.canReplaceWithoutAuthorization(targetURL, fileManager: .default) {
      replace(.default)
      return
    }

    eventHandler(.requestingAuthorization)
    DispatchQueue.main.async {
      NSWorkspace.shared.requestAuthorization(to: .replaceFile) { authorization, _ in
        guard let authorization else {
          try? FileManager.default.removeItem(at: staged.workDirectoryURL)
          finish(.failure(AppUpdaterError.installationAuthorizationDenied))
          return
        }
        replace(FileManager(authorization: authorization))
      }
    }
  }

  func launchRelaunchAfterInstall(_ installed: InstalledAppUpdate) throws {
    guard legacyInstallerAllowed else { throw AppUpdaterError.legacyInstallerRetired }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [installed.relaunchScriptURL.path]
    try process.run()
  }

  func validateManifest(_ manifest: AppUpdateManifest) throws {
    guard manifest.schema == 1 else {
      throw AppUpdaterError.customerFacingFailure("更新清单版本暂不支持。")
    }
    let expectedBundleID = Bundle.main.bundleIdentifier ?? identity.bundleIdentifier
    guard manifest.bundleIdentifier == expectedBundleID else {
      throw AppUpdaterError.bundleMismatch(
        expected: expectedBundleID,
        actual: manifest.bundleIdentifier
      )
    }
    guard let url = URL(string: manifest.url) else {
      throw AppUpdaterError.invalidDownloadURL
    }
    try validateDownloadURL(url)
    let shaPattern = #"^[a-fA-F0-9]{64}$"#
    guard manifest.sha256.range(of: shaPattern, options: .regularExpression) != nil else {
      throw AppUpdaterError.invalidSHA
    }
    guard manifest.buildNumber > 0 else {
      throw AppUpdaterError.customerFacingFailure("更新清单构建号无效。")
    }
    let minimumSystemVersion = try semanticSystemVersion(manifest.minimumSystemVersion)
    try validateCurrentSystemSupports(minimumSystemVersion)
    let expectedReleasePrefix = "/releases/\(manifest.version)-\(manifest.build)/"
    guard url.path.hasPrefix(expectedReleasePrefix) else {
      throw AppUpdaterError.untrustedDownloadPath
    }
  }

  func validateDownloadURL(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https",
      url.user == nil,
      url.password == nil,
      url.fragment == nil,
      url.query == nil,
      url.port == nil || url.port == 443
    else {
      throw AppUpdaterError.invalidDownloadURL
    }
    guard let host = url.host?.lowercased(), trustedDownloadHosts.contains(host) else {
      throw AppUpdaterError.untrustedDownloadHost
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw AppUpdaterError.invalidDownloadURL
    }
    let encodedPath = components.percentEncodedPath.lowercased()
    guard !encodedPath.contains("%2f"),
      !encodedPath.contains("%5c"),
      !encodedPath.contains("%2e"),
      !url.path.contains("//"),
      !url.path.contains("\\"),
      !url.path.split(separator: "/").contains("..")
    else {
      throw AppUpdaterError.untrustedDownloadPath
    }
    let allowedPrefixes =
      trustedCOSDownloadHosts.contains(host)
      ? trustedDownloadPathPrefixes.filter { $0 == "/releases/" }
      : trustedDownloadPathPrefixes
    guard allowedPrefixes.contains(where: { url.path.hasPrefix($0) }),
      url.pathExtension.lowercased() == "zip"
    else {
      throw AppUpdaterError.untrustedDownloadPath
    }
  }

  private func resolvedUpdateTargetURL() throws -> URL {
    let fileManager = FileManager.default
    let currentURL = Bundle.main.bundleURL.standardizedFileURL
    let systemURL = installURL.standardizedFileURL
    let userURL = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Applications", isDirectory: true)
      .appendingPathComponent(appName, isDirectory: true)
      .standardizedFileURL
    let allowedURLs = [systemURL, userURL]

    guard allowedURLs.contains(currentURL), isSafeInstalledApp(at: currentURL) else {
      throw AppUpdaterError.unsupportedInstallLocation
    }
    return currentURL
  }

  private func isSafeInstalledApp(at url: URL) -> Bool {
    guard url.lastPathComponent == appName,
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
      values.isDirectory == true,
      values.isSymbolicLink != true
    else { return false }
    return true
  }

  static func canReplaceWithoutAuthorization(
    _ targetURL: URL,
    fileManager: FileManager
  ) -> Bool {
    let parentURL = targetURL.deletingLastPathComponent()
    return fileManager.isWritableFile(atPath: parentURL.path)
  }

  private func replaceStagedUpdate(
    _ staged: StagedAppUpdate,
    at targetURL: URL,
    fileManager: FileManager,
    formalSecurityValidator: ((URL) throws -> Void)? = nil,
    postReplacementValidator: ((URL) throws -> Void)? = nil,
    replacementOperation: ((FileManager, URL, URL) throws -> Void)? = nil,
    rollbackOperation: ((FileManager, URL, URL) throws -> Void)? = nil,
    recoveryDirectoryURL: URL? = nil,
    recordsInstallerResult: Bool = true
  ) throws -> InstalledAppUpdate {
    guard isSafeInstalledApp(at: targetURL) else {
      throw AppUpdaterError.unsupportedInstallLocation
    }
    let required = FormalUpdateRequirement(
      teamIdentifier: staged.requiredTeamIdentifier,
      designatedRequirement: staged.designatedRequirement)
    try validatePreparedApp(
      staged.stagedAppURL,
      manifest: staged.manifest,
      formalRequirement: required,
      formalSecurityValidator: formalSecurityValidator)
    try validateInstalledAppIdentity(
      targetURL,
      formalRequirement: required,
      formalSecurityValidator: formalSecurityValidator)

    let originalTargetIdentity = try appBundleFileIdentity(at: targetURL)
    let backupURL = staged.workDirectoryURL
      .appendingPathComponent("previous-version.app", isDirectory: true)
    try? FileManager.default.removeItem(at: backupURL)
    _ = try runProcess(
      "/usr/bin/ditto",
      arguments: [targetURL.path, backupURL.path])
    try validateInstalledAppIdentity(
      backupURL,
      formalRequirement: required,
      formalSecurityValidator: formalSecurityValidator)

    do {
      if let replacementOperation {
        try replacementOperation(fileManager, targetURL, staged.stagedAppURL)
      } else {
        _ = try fileManager.replaceItemAt(targetURL, withItemAt: staged.stagedAppURL)
      }
      try validatePreparedApp(
        targetURL,
        manifest: staged.manifest,
        formalRequirement: required,
        formalSecurityValidator: formalSecurityValidator)
      try postReplacementValidator?(targetURL)
      let relaunchScriptURL = try writeRelaunchScript(
        installedAppURL: targetURL,
        workURL: staged.workDirectoryURL)
      if recordsInstallerResult {
        try writeInstallerResult(
          outcome: "success",
          targetBuild: staged.manifest.build,
          message: "更新已安装并完成安全校验。")
      }
      try? FileManager.default.removeItem(at: backupURL)
      return InstalledAppUpdate(
        manifest: staged.manifest,
        installedAppURL: targetURL,
        relaunchScriptURL: relaunchScriptURL)
    } catch let updateError {
      if originalTargetIsIntact(
        at: targetURL,
        identity: originalTargetIdentity,
        formalRequirement: required,
        formalSecurityValidator: formalSecurityValidator)
      {
        throw updateError
      }
      let recoveryCopyURL = staged.workDirectoryURL
        .appendingPathComponent("rollback-recovery.app", isDirectory: true)
      do {
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
          throw AppUpdaterError.installationRollbackFailed(recoveryPath: nil)
        }
        try validateInstalledAppIdentity(
          backupURL,
          formalRequirement: required,
          formalSecurityValidator: formalSecurityValidator)
        try? FileManager.default.removeItem(at: recoveryCopyURL)
        _ = try runProcess(
          "/usr/bin/ditto",
          arguments: [backupURL.path, recoveryCopyURL.path])
        try validateInstalledAppIdentity(
          recoveryCopyURL,
          formalRequirement: required,
          formalSecurityValidator: formalSecurityValidator)
        if let rollbackOperation {
          try rollbackOperation(fileManager, targetURL, backupURL)
        } else {
          _ = try fileManager.replaceItemAt(targetURL, withItemAt: backupURL)
        }
        try validateInstalledAppIdentity(
          targetURL,
          formalRequirement: required,
          formalSecurityValidator: formalSecurityValidator)
        try? FileManager.default.removeItem(at: recoveryCopyURL)
      } catch {
        let recoveryURL = preserveRecoveryBackup(
          candidates: [recoveryCopyURL, backupURL],
          recoveryDirectoryURL: recoveryDirectoryURL,
          formalRequirement: required,
          formalSecurityValidator: formalSecurityValidator)
        if let recoveryURL {
          AppDiagnostics.log(
            "update_rollback_recovery_preserved",
            ["path": recoveryURL.path])
        }
        let rollbackError = AppUpdaterError.installationRollbackFailed(
          recoveryPath: recoveryURL?.path)
        if recordsInstallerResult {
          try? writeInstallerResult(
            outcome: "failure",
            targetBuild: staged.manifest.build,
            message: rollbackError.localizedDescription)
        }
        throw rollbackError
      }
      throw updateError
    }
  }

  private func appBundleFileIdentity(at url: URL) throws -> AppBundleFileIdentity {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
      let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    else {
      throw AppUpdaterError.customerFacingFailure("无法识别当前 App 文件。")
    }
    return AppBundleFileIdentity(systemNumber: systemNumber, fileNumber: fileNumber)
  }

  private func originalTargetIsIntact(
    at targetURL: URL,
    identity: AppBundleFileIdentity,
    formalRequirement: FormalUpdateRequirement,
    formalSecurityValidator: ((URL) throws -> Void)?
  ) -> Bool {
    guard (try? appBundleFileIdentity(at: targetURL)) == identity else { return false }
    return
      (try? validateInstalledAppIdentity(
        targetURL,
        formalRequirement: formalRequirement,
        formalSecurityValidator: formalSecurityValidator)) != nil
  }

  private func validateInstalledAppIdentity(
    _ appURL: URL,
    formalRequirement: FormalUpdateRequirement,
    formalSecurityValidator: ((URL) throws -> Void)? = nil
  ) throws {
    let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
    guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
      throw AppUpdaterError.missingAppBundle
    }
    let expectedBundleID = Bundle.main.bundleIdentifier ?? identity.bundleIdentifier
    let actualBundleID = info["CFBundleIdentifier"] as? String ?? ""
    guard actualBundleID == expectedBundleID else {
      throw AppUpdaterError.bundleMismatch(expected: expectedBundleID, actual: actualBundleID)
    }
    guard info["AIXLGFormalReleaseCompiled"] as? Bool == true,
      info["AIXLGReleaseHardeningEnabled"] as? Bool == true,
      !(info["AIXLGReleasePublishedAt"] as? String ?? "").isEmpty
    else {
      throw AppUpdaterError.formalReleaseRequired
    }
    do {
      _ = try runProcess(
        "/usr/bin/codesign",
        arguments: ["--verify", "--deep", "--strict", appURL.path])
    } catch {
      throw AppUpdaterError.codeSignatureInvalid
    }
    if let formalSecurityValidator {
      try formalSecurityValidator(appURL)
    } else {
      _ = try validateFormalUpdateSecurity(appURL, required: formalRequirement)
    }
  }

  private func preserveRecoveryBackup(
    candidates: [URL],
    recoveryDirectoryURL: URL?,
    formalRequirement: FormalUpdateRequirement,
    formalSecurityValidator: ((URL) throws -> Void)?
  ) -> URL? {
    let recoveryRoot =
      recoveryDirectoryURL
      ?? identity.applicationSupportURL.appendingPathComponent("Update Recovery", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: recoveryRoot.path)
    } catch {
      return nil
    }

    for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
      do {
        try validateInstalledAppIdentity(
          candidate,
          formalRequirement: formalRequirement,
          formalSecurityValidator: formalSecurityValidator)
        let recoveryURL = recoveryRoot.appendingPathComponent(
          "previous-version-\(UUID().uuidString).app",
          isDirectory: true)
        _ = try runProcess(
          "/usr/bin/ditto",
          arguments: [candidate.path, recoveryURL.path])
        try validateInstalledAppIdentity(
          recoveryURL,
          formalRequirement: formalRequirement,
          formalSecurityValidator: formalSecurityValidator)
        return recoveryURL
      } catch {
        continue
      }
    }
    return nil
  }

  private func validatePreparedApp(
    _ appURL: URL,
    manifest: AppUpdateManifest,
    formalRequirement: FormalUpdateRequirement,
    formalSecurityValidator: ((URL) throws -> Void)? = nil
  ) throws {
    do {
      _ = try runProcess(
        "/usr/bin/codesign",
        arguments: ["--verify", "--deep", "--strict", appURL.path])
    } catch {
      throw AppUpdaterError.codeSignatureInvalid
    }
    _ = try validateExtractedApp(appURL, manifest: manifest)
    if let formalSecurityValidator {
      try formalSecurityValidator(appURL)
    } else {
      _ = try validateFormalUpdateSecurity(appURL, required: formalRequirement)
    }
  }

  private func stageDownloadedUpdate(
    _ temporaryURL: URL,
    manifest: AppUpdateManifest,
    downloadEvidence: AppUpdateDownloadEvidence,
    formalSecurityValidator: ((URL) throws -> FormalUpdateRequirement)? = nil
  ) throws -> StagedAppUpdate {
    let fileManager = FileManager.default
    let workURL = fileManager.temporaryDirectory
      .appendingPathComponent("aixlg-update-\(UUID().uuidString)", isDirectory: true)
    let archiveURL = workURL.appendingPathComponent("update.zip")
    let extractURL = workURL.appendingPathComponent("extract", isDirectory: true)
    var keepsWorkDirectory = false
    defer {
      if !keepsWorkDirectory {
        try? fileManager.removeItem(at: workURL)
      }
    }

    do {
      try fileManager.createDirectory(at: extractURL, withIntermediateDirectories: true)
      try fileManager.copyItem(at: temporaryURL, to: archiveURL)

      let checksumOutput = try runProcess(
        "/usr/bin/shasum",
        arguments: ["-a", "256", archiveURL.path]
      )
      let actualSHA =
        checksumOutput
        .split(separator: " ")
        .first
        .map(String.init) ?? ""
      guard actualSHA.lowercased() == manifest.sha256.lowercased() else {
        throw AppUpdaterError.checksumMismatch(expected: manifest.sha256, actual: actualSHA)
      }

      _ = try runProcess(
        "/usr/bin/ditto",
        arguments: ["-x", "-k", archiveURL.path, extractURL.path]
      )
      let appURL = extractURL.appendingPathComponent(appName, isDirectory: true)
      guard fileManager.fileExists(atPath: appURL.path) else {
        throw AppUpdaterError.missingAppBundle
      }

      do {
        _ = try runProcess(
          "/usr/bin/codesign",
          arguments: ["--verify", "--deep", "--strict", appURL.path]
        )
      } catch {
        throw AppUpdaterError.codeSignatureInvalid
      }
      let verifiedReleasePublishedAt = try validateExtractedApp(appURL, manifest: manifest)
      let requirement: FormalUpdateRequirement
      if let formalSecurityValidator {
        requirement = try formalSecurityValidator(appURL)
      } else {
        requirement = try validateFormalUpdateSecurity(appURL)
      }
      let installerScriptURL: URL
      #if AIXLG_UPDATE_FIXTURE
        installerScriptURL = try writeInstallerScript(
          stagedAppURL: appURL,
          workURL: workURL,
          formalRequirement: requirement)
      #else
        installerScriptURL = workURL.appendingPathComponent("legacy-installer-disabled")
      #endif
      keepsWorkDirectory = true
      return StagedAppUpdate(
        manifest: manifest,
        verifiedReleasePublishedAt: verifiedReleasePublishedAt,
        stagedAppURL: appURL,
        workDirectoryURL: workURL,
        installerScriptURL: installerScriptURL,
        downloadEvidence: downloadEvidence,
        requiredTeamIdentifier: requirement.teamIdentifier,
        designatedRequirement: requirement.designatedRequirement)
    } catch {
      throw error
    }
  }

  private func validateExtractedApp(
    _ appURL: URL,
    manifest: AppUpdateManifest
  ) throws -> String {
    let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
    guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
      throw AppUpdaterError.missingAppBundle
    }
    let bundleID = info["CFBundleIdentifier"] as? String ?? ""
    guard bundleID == manifest.bundleIdentifier else {
      throw AppUpdaterError.bundleMismatch(expected: manifest.bundleIdentifier, actual: bundleID)
    }
    let build = info["CFBundleVersion"] as? String ?? ""
    guard build == manifest.build else {
      throw AppUpdaterError.buildMismatch(expected: manifest.build, actual: build)
    }
    let version = info["CFBundleShortVersionString"] as? String ?? ""
    guard version == manifest.version else {
      throw AppUpdaterError.versionMismatch(expected: manifest.version, actual: version)
    }
    let manifestMinimumSystemVersion = try semanticSystemVersion(manifest.minimumSystemVersion)
    let candidateMinimumSystemVersionText = info["LSMinimumSystemVersion"] as? String ?? ""
    let candidateMinimumSystemVersion = try semanticSystemVersion(
      candidateMinimumSystemVersionText)
    guard candidateMinimumSystemVersion == manifestMinimumSystemVersion else {
      throw AppUpdaterError.minimumSystemVersionMismatch(
        expected: manifest.minimumSystemVersion,
        actual: candidateMinimumSystemVersionText)
    }
    try validateCurrentSystemSupports(candidateMinimumSystemVersion)
    guard info["AIXLGFormalReleaseCompiled"] as? Bool == true,
      info["AIXLGReleaseHardeningEnabled"] as? Bool == true
    else {
      throw AppUpdaterError.formalReleaseRequired
    }
    let releasePublishedAt = info["AIXLGReleasePublishedAt"] as? String ?? ""
    guard releasePublishedAt == manifest.publishedAt else {
      throw AppUpdaterError.releasePublishedAtMismatch(
        expected: manifest.publishedAt,
        actual: releasePublishedAt)
    }
    return releasePublishedAt
  }

  private func semanticSystemVersion(_ text: String) throws -> SemanticSystemVersion {
    guard let version = SemanticSystemVersion(text) else {
      throw AppUpdaterError.invalidMinimumSystemVersion(text)
    }
    return version
  }

  private func validateCurrentSystemSupports(_ required: SemanticSystemVersion) throws {
    let current = SemanticSystemVersion(ProcessInfo.processInfo.operatingSystemVersion)
    guard current >= required else {
      throw AppUpdaterError.minimumSystemVersionNotSupported(
        required: required.displayString,
        current: current.displayString)
    }
  }

  #if AIXLG_UPDATE_FIXTURE
    private func writeInstallerScript(
      stagedAppURL: URL,
      workURL: URL,
      formalRequirement: FormalUpdateRequirement
    ) throws -> URL {
      let scriptURL = workURL.appendingPathComponent("install-update.sh")
      let pid = ProcessInfo.processInfo.processIdentifier
      let app = shellQuote(installURL.path)
      let currentApp = shellQuote(Bundle.main.bundleURL.path)
      let staged = shellQuote(stagedAppURL.path)
      let work = shellQuote(workURL.path)
      let requiredTeam = shellQuote(formalRequirement.teamIdentifier)
      let designatedRequirement = shellQuote(formalRequirement.designatedRequirement)
      let script = """
        #!/bin/zsh
        set -u
        LOG_DIR=\(shellQuote(identity.logDirectoryURL.path))
        /bin/mkdir -p "$LOG_DIR"
        LOG="$LOG_DIR/update.log"
        exec >> "$LOG" 2>&1
        echo "== update $(/bin/date) =="
        APP=\(app)
        CURRENT_APP=\(currentApp)
        NEW_APP=\(staged)
        WORK_DIR=\(work)
        PID=\(pid)
        REQUIRED_TEAM=\(requiredTeam)
        DESIGNATED_REQUIREMENT=\(designatedRequirement)
        RESULT_DIR=\(shellQuote(identity.applicationSupportURL.path))
        RESULT_FILE="$RESULT_DIR/update-result.txt"

        write_result() {
          /bin/mkdir -p "$RESULT_DIR"
          /usr/bin/printf '%s\n' "$1" > "$RESULT_FILE"
        }

        verify_app() {
          local candidate="$1"
          /usr/bin/codesign --verify --deep --strict "$candidate" || return 1
          local details
          details="$(/usr/bin/codesign -dv --verbose=4 "$candidate" 2>&1)" || return 1
          /usr/bin/grep -Fq "Authority=Developer ID Application:" <<<"$details" || return 1
          /usr/bin/grep -Fq "TeamIdentifier=$REQUIRED_TEAM" <<<"$details" || return 1
          /usr/bin/codesign --verify --deep --strict "-R=$DESIGNATED_REQUIREMENT" "$candidate" || return 1
        }

        /bin/rm -f "$RESULT_FILE"

        for _ in {1..100}; do
          if ! /bin/kill -0 "$PID" 2>/dev/null; then
            break
          fi
          /bin/sleep 0.1
        done
        if /bin/kill -0 "$PID" 2>/dev/null; then
          echo "terminating old process $PID"
          /bin/kill "$PID" 2>/dev/null || true
          for _ in {1..50}; do
            if ! /bin/kill -0 "$PID" 2>/dev/null; then
              break
            fi
            /bin/sleep 0.1
          done
        fi
        if /bin/kill -0 "$PID" 2>/dev/null; then
          echo "force terminating old process $PID"
          /bin/kill -9 "$PID" 2>/dev/null || true
        fi

        BACKUP="${APP}.backup.$(/bin/date +%s)"
        if [[ -d "$APP" ]]; then
          if ! /bin/mv "$APP" "$BACKUP"; then
            write_result "更新安装失败：无法备份当前版本，未执行替换。当前版本未受影响，可稍后重试。"
            /usr/bin/open "$CURRENT_APP"
            exit 1
          fi
        fi
        /bin/mkdir -p "/Applications"
        if /usr/bin/ditto "$NEW_APP" "$APP" && verify_app "$APP"; then
          /bin/rm -rf "$BACKUP"
          write_result "更新已安装并完成安全校验。"
          /usr/bin/open "$APP"
          /bin/rm -rf "$WORK_DIR"
          echo "update installed"
          exit 0
        fi

        echo "direct install failed"
        if [[ -d "$BACKUP" ]]; then
          /bin/rm -rf "$APP"
          if /bin/mv "$BACKUP" "$APP"; then
            write_result "更新安装失败：新版本未通过安装后安全校验，已恢复旧版本。当前版本未受影响，可稍后重试。"
            /usr/bin/open "$APP"
          else
            write_result "更新安装失败：旧版本备份仍保留，但自动恢复未完成。请从官网下载正式公证版。"
            /usr/bin/open "$BACKUP"
          fi
        else
          /bin/rm -rf "$APP"
          write_result "更新安装失败：新版本未通过安装后安全校验。未找到旧版备份，请从官网下载正式公证版。"
        fi
        exit 1
        """
      try script.write(to: scriptURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: scriptURL.path)
      return scriptURL
    }
  #endif

  private func writeRelaunchScript(
    installedAppURL: URL,
    workURL: URL
  ) throws -> URL {
    let scriptURL = workURL.appendingPathComponent("relaunch-update.sh")
    let script = """
      #!/bin/zsh
      set -u
      LOG_DIR=\(shellQuote(identity.logDirectoryURL.path))
      /bin/mkdir -p "$LOG_DIR"
      LOG="$LOG_DIR/update.log"
      exec >> "$LOG" 2>&1
      APP=\(shellQuote(installedAppURL.path))
      WORK_DIR=\(shellQuote(workURL.path))
      PID=\(ProcessInfo.processInfo.processIdentifier)
      RESULT_DIR=\(shellQuote(identity.applicationSupportURL.path))
      RESULT_FILE="$RESULT_DIR/update-result.txt"

      for _ in {1..100}; do
        if ! /bin/kill -0 "$PID" 2>/dev/null; then
          break
        fi
        /bin/sleep 0.1
      done
      if /bin/kill -0 "$PID" 2>/dev/null; then
        /bin/kill "$PID" 2>/dev/null || true
        for _ in {1..50}; do
          if ! /bin/kill -0 "$PID" 2>/dev/null; then
            break
          fi
          /bin/sleep 0.1
        done
      fi
      if /bin/kill -0 "$PID" 2>/dev/null; then
        /bin/kill -9 "$PID" 2>/dev/null || true
        for _ in {1..50}; do
          if ! /bin/kill -0 "$PID" 2>/dev/null; then
            break
          fi
          /bin/sleep 0.1
        done
      fi
      if /bin/kill -0 "$PID" 2>/dev/null; then
        /bin/mkdir -p "$RESULT_DIR"
        /usr/bin/printf '%s\n' \
          "更新已安装，但旧进程未能完全退出。请手动退出 App，再从“应用程序”重新打开。" > "$RESULT_FILE"
        echo "old process still alive after SIGKILL"
        exit 1
      fi

      if /usr/bin/open -a "$APP"; then
        echo "update relaunched"
        /bin/rm -rf "$WORK_DIR"
        exit 0
      fi
      /bin/mkdir -p "$RESULT_DIR"
      /usr/bin/printf '%s\n' \
        "更新已安装，但自动重启失败。请从“应用程序”手动打开小龙哥Mac哲学。" > "$RESULT_FILE"
      echo "update relaunch failed"
      exit 1
      """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
  }

  private var installerResultURL: URL {
    identity.applicationSupportURL.appendingPathComponent("update-result.txt")
  }

  private func writeInstallerResult(
    outcome: String,
    targetBuild: String,
    message: String
  ) throws {
    let result = AppUpdateInstallerResult(
      outcome: outcome,
      targetBuild: targetBuild,
      message: message)
    let data = try JSONEncoder().encode(result)
    try FileManager.default.createDirectory(
      at: installerResultURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try data.write(to: installerResultURL, options: .atomic)
  }

  private func runProcess(
    _ executable: String,
    arguments: [String],
    timeout: TimeInterval = 120
  ) throws -> String {
    let result = try runProcessCapturingOutput(
      executable,
      arguments: arguments,
      timeout: timeout)
    guard result.status == 0 else {
      AppDiagnostics.log(
        "update_command_failed",
        [
          "command": URL(fileURLWithPath: executable).lastPathComponent,
          "status": String(result.status),
          "detail": result.error.isEmpty ? result.output : result.error,
        ])
      throw AppUpdaterError.commandFailed(
        result.error.isEmpty ? result.output : result.error)
    }
    return result.output
  }

  private func runProcessCombined(
    _ executable: String,
    arguments: [String],
    timeout: TimeInterval = 30
  ) throws -> String {
    let result = try runProcessCapturingOutput(
      executable,
      arguments: arguments,
      timeout: timeout)
    let combined = result.output + result.error
    guard result.status == 0 else {
      AppDiagnostics.log(
        "update_command_failed",
        [
          "command": URL(fileURLWithPath: executable).lastPathComponent,
          "status": String(result.status),
          "detail": combined,
        ])
      throw AppUpdaterError.commandFailed(combined)
    }
    return combined
  }

  private func runProcessCapturingOutput(
    _ executable: String,
    arguments: [String],
    timeout: TimeInterval
  ) throws -> (output: String, error: String, status: Int32) {
    let fileManager = FileManager.default
    let captureDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("aixlg-update-command-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: captureDirectory) }

    let outputURL = captureDirectory.appendingPathComponent("stdout")
    let errorURL = captureDirectory.appendingPathComponent("stderr")
    guard fileManager.createFile(atPath: outputURL.path, contents: nil),
      fileManager.createFile(atPath: errorURL.path, contents: nil)
    else {
      throw AppUpdaterError.commandFailed("无法创建更新校验日志。")
    }
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer {
      try? outputHandle.close()
      try? errorHandle.close()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var processEnvironment = ProcessInfo.processInfo.environment
    processEnvironment["LC_ALL"] = "C"
    processEnvironment["LANG"] = "C"
    process.environment = processEnvironment
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()

    var timedOut = false
    if finished.wait(timeout: .now() + timeout) == .timedOut {
      timedOut = true
      process.terminate()
      if finished.wait(timeout: .now() + 2) == .timedOut {
        Darwin.kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 2)
      }
    }
    try? outputHandle.synchronize()
    try? errorHandle.synchronize()
    let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
    let error = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
    if timedOut {
      let command = URL(fileURLWithPath: executable).lastPathComponent
      AppDiagnostics.log("update_command_timed_out", ["command": command])
      throw AppUpdaterError.commandTimedOut(command)
    }
    return (output, error, process.terminationStatus)
  }

  private func validateFormalUpdateSecurity(
    _ appURL: URL,
    required: FormalUpdateRequirement? = nil
  ) throws -> FormalUpdateRequirement {
    let requirement: FormalUpdateRequirement
    if let required {
      requirement = required
    } else {
      requirement = try currentFormalUpdateRequirement()
    }
    guard isSafeCodeSigningToken(requirement.teamIdentifier) else {
      throw AppUpdaterError.customerFacingFailure("当前 App 的正式签名信息无效，已停止本次更新。")
    }
    let candidateIdentity = try codeSigningIdentity(
      for: appURL,
      invalidCodeError: .codeSignatureInvalid)
    guard candidateIdentity.isDeveloperIDApplication else {
      throw AppUpdaterError.developerIDRequired
    }
    guard candidateIdentity.teamIdentifier == requirement.teamIdentifier else {
      throw AppUpdaterError.teamIdentifierMismatch(
        expected: requirement.teamIdentifier,
        actual: candidateIdentity.teamIdentifier)
    }
    try validateDesignatedRequirement(
      requirement.designatedRequirement,
      appURL: appURL)
    let assessment =
      (try? runProcessCombined(
        "/usr/sbin/spctl",
        arguments: ["--assess", "--type", "execute", "--verbose=4", appURL.path])) ?? ""
    let evidence = AppUpdateSecurityEvidence(
      isDeveloperIDApplication: true,
      teamIdentifier: candidateIdentity.teamIdentifier,
      satisfiesDesignatedRequirement: true,
      // Gatekeeper recognizes a stapled ticket without requiring Xcode or Command Line Tools.
      hasNotarizationTicket: assessment.localizedCaseInsensitiveContains(
        "source=Notarized Developer ID"),
      passesNotarizedGatekeeperAssessment: assessment.localizedCaseInsensitiveContains(
        "source=Notarized Developer ID"))
    try Self.validateFormalSecurityEvidence(
      evidence,
      expectedTeamID: requirement.teamIdentifier)
    return requirement
  }

  static func validateFormalSecurityEvidence(
    _ evidence: AppUpdateSecurityEvidence,
    expectedTeamID: String
  ) throws {
    guard evidence.isDeveloperIDApplication else {
      throw AppUpdaterError.developerIDRequired
    }
    let actualTeamID = evidence.teamIdentifier ?? ""
    guard actualTeamID == expectedTeamID else {
      throw AppUpdaterError.teamIdentifierMismatch(
        expected: expectedTeamID,
        actual: actualTeamID)
    }
    guard evidence.satisfiesDesignatedRequirement else {
      throw AppUpdaterError.designatedRequirementMismatch
    }
    guard evidence.hasNotarizationTicket,
      evidence.passesNotarizedGatekeeperAssessment
    else {
      throw AppUpdaterError.notarizationRequired
    }
  }

  private func currentFormalUpdateRequirement() throws -> FormalUpdateRequirement {
    let requirementText = stableUpdateDesignatedRequirement
    let requirement = try codeRequirement(
      requirementText,
      invalidCodeError: .currentCodeIdentityUnavailable)
    try validateCurrentCode(requirement: requirement)
    return FormalUpdateRequirement(
      teamIdentifier: AppRuntimeIdentity.stableDeveloperTeamIdentifier,
      designatedRequirement: requirementText)
  }

  private var stableUpdateDesignatedRequirement: String {
    "identifier \"\(AppRuntimeIdentity.stableBundleIdentifier)\""
      + " and anchor apple generic"
      + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
      + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
      + " and certificate leaf[subject.OU] = \(AppRuntimeIdentity.stableDeveloperTeamIdentifier)"
  }

  private func designatedRequirement(for appURL: URL) throws -> String {
    let staticCode = try validatedStaticCode(
      for: appURL,
      invalidCodeError: .currentCodeIdentityUnavailable)
    return try designatedRequirement(
      for: staticCode,
      invalidCodeError: .currentCodeIdentityUnavailable)
  }

  private func designatedRequirement(
    for staticCode: SecStaticCode,
    invalidCodeError: AppUpdaterError
  ) throws -> String {

    var requirement: SecRequirement?
    let requirementStatus = SecCodeCopyDesignatedRequirement(
      staticCode,
      SecCSFlags(rawValue: 0),
      &requirement)
    guard requirementStatus == errSecSuccess, let requirement else {
      throw invalidCodeError
    }

    var requirementText: CFString?
    let textStatus = SecRequirementCopyString(
      requirement,
      SecCSFlags(rawValue: 0),
      &requirementText)
    guard textStatus == errSecSuccess, let requirementText else {
      throw invalidCodeError
    }
    let text = requirementText as String
    guard !text.isEmpty,
      text.utf8.count <= 4_096,
      !text.contains("\0")
    else {
      throw invalidCodeError
    }
    return text
  }

  private func validateCurrentCode(requirement: SecRequirement) throws {
    var dynamicCode: SecCode?
    guard
      SecCodeCopySelf(
        SecCSFlags(rawValue: 0),
        &dynamicCode) == errSecSuccess,
      let dynamicCode,
      SecCodeCheckValidityWithErrors(
        dynamicCode,
        SecCSFlags(rawValue: 0),
        requirement,
        nil) == errSecSuccess
    else { throw AppUpdaterError.currentCodeIdentityUnavailable }

    var staticCode: SecStaticCode?
    guard
      SecCodeCopyStaticCode(
        dynamicCode,
        SecCSFlags(rawValue: kSecCSUseAllArchitectures),
        &staticCode) == errSecSuccess,
      let staticCode,
      SecStaticCodeCheckValidityWithErrors(
        staticCode,
        strictCodeValidationFlags,
        requirement,
        nil) == errSecSuccess
    else { throw AppUpdaterError.currentCodeIdentityUnavailable }
  }

  private func validatedStaticCode(
    for appURL: URL,
    invalidCodeError: AppUpdaterError
  ) throws -> SecStaticCode {
    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(
        appURL as CFURL,
        SecCSFlags(rawValue: 0),
        &staticCode) == errSecSuccess,
      let staticCode
    else { throw invalidCodeError }

    guard
      SecStaticCodeCheckValidityWithErrors(
        staticCode,
        strictCodeValidationFlags,
        nil,
        nil) == errSecSuccess
    else { throw invalidCodeError }
    return staticCode
  }

  private var strictCodeValidationFlags: SecCSFlags {
    SecCSFlags(
      rawValue: UInt32(
        kSecCSCheckAllArchitectures
          | kSecCSCheckNestedCode
          | kSecCSStrictValidate))
  }

  private func codeSigningIdentity(
    for appURL: URL,
    invalidCodeError: AppUpdaterError
  ) throws -> CodeSigningIdentity {
    let staticCode = try validatedStaticCode(
      for: appURL,
      invalidCodeError: invalidCodeError)
    return try codeSigningIdentity(
      for: staticCode,
      invalidCodeError: invalidCodeError)
  }

  private func codeSigningIdentity(
    for staticCode: SecStaticCode,
    invalidCodeError: AppUpdaterError
  ) throws -> CodeSigningIdentity {
    var signingInformation: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &signingInformation) == errSecSuccess,
      let signingInformation,
      let teamIdentifier = (signingInformation as NSDictionary)[
        kSecCodeInfoTeamIdentifier as String] as? String,
      isSafeCodeSigningToken(teamIdentifier)
    else { throw invalidCodeError }

    let developerIDRequirementText =
      "anchor apple generic"
      + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
      + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    var developerIDRequirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        developerIDRequirementText as CFString,
        SecCSFlags(rawValue: 0),
        &developerIDRequirement) == errSecSuccess,
      let developerIDRequirement
    else { throw invalidCodeError }

    let isDeveloperIDApplication =
      SecStaticCodeCheckValidityWithErrors(
        staticCode,
        strictCodeValidationFlags,
        developerIDRequirement,
        nil) == errSecSuccess
    return CodeSigningIdentity(
      teamIdentifier: teamIdentifier,
      isDeveloperIDApplication: isDeveloperIDApplication)
  }

  private func validateDesignatedRequirement(
    _ requirementText: String,
    appURL: URL
  ) throws {
    let requirement = try codeRequirement(
      requirementText,
      invalidCodeError: .currentCodeIdentityUnavailable)

    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(
        appURL as CFURL,
        SecCSFlags(rawValue: 0),
        &staticCode) == errSecSuccess,
      let staticCode
    else { throw AppUpdaterError.codeSignatureInvalid }

    let status = SecStaticCodeCheckValidityWithErrors(
      staticCode,
      strictCodeValidationFlags,
      requirement,
      nil)
    if status == errSecSuccess { return }
    if status == errSecCSReqFailed {
      throw AppUpdaterError.designatedRequirementMismatch
    }
    throw AppUpdaterError.codeSignatureInvalid
  }

  private func codeRequirement(
    _ text: String,
    invalidCodeError: AppUpdaterError
  ) throws -> SecRequirement {
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        text as CFString,
        SecCSFlags(rawValue: 0),
        &requirement) == errSecSuccess,
      let requirement
    else { throw invalidCodeError }
    return requirement
  }

  private func satisfiesDesignatedRequirement(
    _ requirementText: String,
    appURL: URL
  ) -> Bool {
    (try? validateDesignatedRequirement(requirementText, appURL: appURL)) != nil
  }

  private func isSafeCodeSigningToken(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
  }

  func isTrustedManifestURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
      url.host?.lowercased() == trustedManifestHost,
      url.port == nil || url.port == 443,
      url.user == nil,
      url.password == nil,
      url.fragment == nil,
      url.path == trustedManifestPath
    else { return false }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    let queryItems = components.queryItems ?? []
    return queryItems.isEmpty
      || (queryItems.count == 1
        && queryItems[0].name == "_t"
        && !(queryItems[0].value ?? "").isEmpty)
  }

  private func makeSession(delegate: TrustedUpdateRedirectDelegate) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = 120
    return URLSession(
      configuration: configuration,
      delegate: delegate,
      delegateQueue: nil)
  }

  func makeDownloadRequest(for url: URL) throws -> URLRequest {
    try validateDownloadURL(url)
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: requestTimeout)
    request.setValue("application/zip, application/octet-stream", forHTTPHeaderField: "Accept")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue("bytes=0-", forHTTPHeaderField: "Range")
    return request
  }

  static func validateDownloadResponse(
    _ response: HTTPURLResponse,
    fileSize: Int64
  ) throws -> AppUpdateDownloadEvidence {
    guard fileSize > 0 else {
      throw AppUpdaterError.emptyDownload
    }
    guard response.statusCode == 200 || response.statusCode == 206 else {
      throw AppUpdaterError.invalidHTTPStatus(response.statusCode)
    }
    if let contentEncoding = response.value(forHTTPHeaderField: "Content-Encoding"),
      !contentEncoding.isEmpty,
      contentEncoding.lowercased() != "identity"
    {
      throw AppUpdaterError.invalidDownloadResponse
    }

    let contentLength = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
    if let contentLength, contentLength != fileSize {
      throw AppUpdaterError.downloadLengthMismatch(expected: contentLength, actual: fileSize)
    }

    let contentRange = response.value(forHTTPHeaderField: "Content-Range")
    let rangeTotal = try contentRange.map { try parseCompleteContentRange($0, fileSize: fileSize) }
    if response.statusCode == 206, rangeTotal == nil {
      throw AppUpdaterError.invalidDownloadResponse
    }
    let acceptsRanges =
      response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
    return AppUpdateDownloadEvidence(
      bytesWritten: fileSize,
      expectedBytes: rangeTotal ?? contentLength,
      supportsByteRanges: response.statusCode == 206 || acceptsRanges)
  }

  private static func parseCompleteContentRange(_ value: String, fileSize: Int64) throws -> Int64 {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.hasPrefix("bytes ") else {
      throw AppUpdaterError.invalidDownloadResponse
    }
    let body = normalized.dropFirst("bytes ".count)
    let sections = body.split(separator: "/", omittingEmptySubsequences: false)
    guard sections.count == 2,
      let total = Int64(sections[1])
    else {
      throw AppUpdaterError.invalidDownloadResponse
    }
    let bounds = sections[0].split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2,
      let start = Int64(bounds[0]),
      let end = Int64(bounds[1]),
      start == 0,
      end >= start,
      end + 1 == fileSize,
      total == fileSize
    else {
      throw AppUpdaterError.invalidDownloadResponse
    }
    return total
  }

  private var currentBuildNumber: Int {
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    return Int(build) ?? 0
  }

  private var legacyInstallerAllowed: Bool {
    currentBuildNumber < 182
  }

  private func beginOperation() -> UUID? {
    operationLock.lock()
    defer { operationLock.unlock() }
    guard activeOperationID == nil else { return nil }
    let operationID = UUID()
    activeOperationID = operationID
    oversizedOperationID = nil
    return operationID
  }

  private func finishOperation(_ operationID: UUID) {
    operationLock.lock()
    guard activeOperationID == operationID else {
      operationLock.unlock()
      return
    }
    let observation = progressObservation
    progressObservation = nil
    oversizedOperationID = nil
    activeOperationID = nil
    operationLock.unlock()
    observation?.invalidate()
  }

  private func operationExceededSizeLimit(_ operationID: UUID) -> Bool {
    operationLock.lock()
    defer { operationLock.unlock() }
    return oversizedOperationID == operationID
  }

  private func observeProgress(
    of task: URLSessionDownloadTask,
    operationID: UUID,
    eventHandler: @escaping (AppUpdateDownloadEvent) -> Void
  ) {
    let observation = task.progress.observe(\.completedUnitCount, options: [.initial, .new]) {
      [weak self, weak task] progress, _ in
      guard let self else { return }
      let expectedBytes = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
      let bytesWritten = max(progress.completedUnitCount, 0)
      if bytesWritten > self.maximumUpdateBytes
        || (expectedBytes ?? 0) > self.maximumUpdateBytes
      {
        self.operationLock.lock()
        if self.activeOperationID == operationID {
          self.oversizedOperationID = operationID
        }
        self.operationLock.unlock()
        task?.cancel()
        return
      }
      eventHandler(
        .downloading(
          AppUpdateDownloadProgress(
            bytesWritten: bytesWritten,
            expectedBytes: expectedBytes)))
    }
    operationLock.lock()
    if activeOperationID == operationID {
      progressObservation = observation
      operationLock.unlock()
    } else {
      operationLock.unlock()
      observation.invalidate()
    }
  }

  private func fileSize(at url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values.fileSize else {
      throw AppUpdaterError.invalidDownloadResponse
    }
    return Int64(size)
  }

  private func configuredStringArray(key: String, fallback: [String]) -> [String] {
    guard let values = Bundle.main.object(forInfoDictionaryKey: key) as? [String], !values.isEmpty
    else { return fallback }
    return values
  }

  private static func normalizedExactHost(_ value: String) -> String? {
    let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !host.isEmpty,
      !host.contains("*"),
      !host.contains("/"),
      !host.contains(":"),
      host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
    else { return nil }
    return host
  }

  private static func isSafePathPrefix(_ value: String) -> Bool {
    value.hasPrefix("/")
      && value.hasSuffix("/")
      && !value.contains("..")
      && !value.contains("\\")
      && !value.lowercased().contains("%2f")
  }

  func consumeInstallerResult() -> String? {
    guard identity.allowsOnlineUpdates, legacyInstallerAllowed else { return nil }
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: installerResultURL.path) else { return nil }
    defer { try? fileManager.removeItem(at: installerResultURL) }

    guard
      let values = try? installerResultURL.resourceValues(forKeys: [.fileSizeKey]),
      let byteCount = values.fileSize,
      byteCount > 0,
      byteCount <= Self.maximumInstallerResultBytes,
      let data = try? Data(contentsOf: installerResultURL),
      data.count == byteCount
    else {
      AppDiagnostics.log(
        "update_installer_result_rejected",
        ["reason": "missing-unreadable-or-oversized"])
      return Self.genericInstallerFailureMessage
    }

    let currentBuild =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    let sanitized = Self.sanitizeInstallerResult(data, currentBuild: currentBuild)
    if let diagnostic = sanitized.diagnostic {
      AppDiagnostics.log(
        "update_installer_result_sanitized",
        ["detail": diagnostic])
    }
    return sanitized.message
  }

  private static func sanitizeInstallerResult(
    _ data: Data,
    currentBuild: String
  ) -> (message: String, diagnostic: String?) {
    guard !data.isEmpty, data.count <= maximumInstallerResultBytes else {
      return (genericInstallerFailureMessage, "empty-or-oversized-result")
    }

    if let result = try? JSONDecoder().decode(AppUpdateInstallerResult.self, from: data) {
      guard result.targetBuild.count <= 9,
        result.targetBuild.allSatisfy(\.isNumber),
        let targetBuildNumber = Int(result.targetBuild),
        let currentBuildNumber = Int(currentBuild),
        ["success", "failure"].contains(result.outcome)
      else {
        return (
          genericInstallerFailureMessage,
          "invalid-structured-result outcome=\(result.outcome) target=\(result.targetBuild)"
        )
      }
      guard result.outcome == "success" else {
        return (
          genericInstallerFailureMessage,
          "structured-failure target=\(result.targetBuild) message=\(result.message)"
        )
      }
      guard currentBuildNumber >= targetBuildNumber else {
        return (
          "更新未完成：重启后仍是旧版本。当前版本未被替换，可手动重试。",
          "success-build-mismatch target=\(result.targetBuild) current=\(currentBuild)"
        )
      }
      return ("更新已安装并完成安全校验。", nil)
    }

    let legacy = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard legacy == safeLegacyRelaunchFailureMessage else {
      return (
        genericInstallerFailureMessage,
        "untrusted-legacy-result=\(legacy ?? "non-utf8")"
      )
    }
    return (safeLegacyRelaunchFailureMessage, nil)
  }

  #if AIXLG_UPDATE_FIXTURE
    func customerInstallerResultMessageForFixture(
      _ data: Data,
      currentBuild: String
    ) -> String {
      Self.sanitizeInstallerResult(data, currentBuild: currentBuild).message
    }

    func allowsDownloadRedirectForFixture(from originalURL: URL, to targetURL: URL) -> Bool {
      guard originalURL.host?.lowercased() == targetURL.host?.lowercased() else { return false }
      return (try? validateDownloadURL(targetURL)) != nil
    }

    func beginOperationForFixture() -> UUID? {
      beginOperation()
    }

    func finishOperationForFixture(_ operationID: UUID) {
      finishOperation(operationID)
    }

    func runProcessCombinedForFixture(
      _ executable: String,
      arguments: [String],
      timeout: TimeInterval
    ) throws -> String {
      try runProcessCombined(executable, arguments: arguments, timeout: timeout)
    }

    func designatedRequirementForFixture(at appURL: URL) throws -> String {
      try designatedRequirement(for: appURL)
    }

    func satisfiesDesignatedRequirementForFixture(
      _ requirement: String,
      appURL: URL
    ) -> Bool {
      satisfiesDesignatedRequirement(requirement, appURL: appURL)
    }

    func validateDesignatedRequirementForFixture(
      _ requirement: String,
      appURL: URL
    ) throws {
      try validateDesignatedRequirement(requirement, appURL: appURL)
    }

    func validateCurrentFormalUpdateRequirementForFixture() throws -> (String, String) {
      let requirement = try currentFormalUpdateRequirement()
      return (requirement.teamIdentifier, requirement.designatedRequirement)
    }

    func validateFormalUpdateSecurityForFixture(
      currentAppURL: URL,
      candidateAppURL: URL
    ) throws {
      let currentIdentity = try codeSigningIdentity(
        for: currentAppURL,
        invalidCodeError: .currentCodeIdentityUnavailable)
      guard currentIdentity.isDeveloperIDApplication,
        isSafeCodeSigningToken(currentIdentity.teamIdentifier)
      else { throw AppUpdaterError.currentCodeIdentityUnavailable }
      let required = FormalUpdateRequirement(
        teamIdentifier: currentIdentity.teamIdentifier,
        designatedRequirement: try designatedRequirement(for: currentAppURL))
      _ = try validateFormalUpdateSecurity(candidateAppURL, required: required)
    }

    func stageDownloadedUpdateForFixture(
      _ archiveURL: URL,
      manifest: AppUpdateManifest,
      downloadEvidence: AppUpdateDownloadEvidence,
      securityEvidence: AppUpdateSecurityEvidence,
      expectedTeamID: String,
      designatedRequirement: String
    ) throws -> StagedAppUpdate {
      try stageDownloadedUpdate(
        archiveURL,
        manifest: manifest,
        downloadEvidence: downloadEvidence
      ) { _ in
        try Self.validateFormalSecurityEvidence(
          securityEvidence,
          expectedTeamID: expectedTeamID)
        return FormalUpdateRequirement(
          teamIdentifier: expectedTeamID,
          designatedRequirement: designatedRequirement)
      }
    }

    func replaceStagedUpdateForFixture(
      _ staged: StagedAppUpdate,
      targetURL: URL,
      failAfterReplacement: Bool = false,
      failDuringReplacementAfterRemovingTarget: Bool = false,
      failRollback: Bool = false
    ) throws -> InstalledAppUpdate {
      try replaceStagedUpdate(
        staged,
        at: targetURL,
        fileManager: .default,
        formalSecurityValidator: { _ in
          try Self.validateFormalSecurityEvidence(
            AppUpdateSecurityEvidence(
              isDeveloperIDApplication: true,
              teamIdentifier: staged.requiredTeamIdentifier,
              satisfiesDesignatedRequirement: true,
              hasNotarizationTicket: true,
              passesNotarizedGatekeeperAssessment: true),
            expectedTeamID: staged.requiredTeamIdentifier)
        },
        postReplacementValidator: { _ in
          if failAfterReplacement {
            throw AppUpdaterError.commandFailed("fixture post-replacement failure")
          }
        },
        replacementOperation: failDuringReplacementAfterRemovingTarget
          ? { fileManager, targetURL, _ in
            try fileManager.removeItem(at: targetURL)
            throw AppUpdaterError.commandFailed("fixture partial replacement failure")
          }
          : nil,
        rollbackOperation: failRollback
          ? { _, _, _ in
            throw AppUpdaterError.commandFailed("fixture rollback failure")
          }
          : nil,
        recoveryDirectoryURL: staged.workDirectoryURL.appendingPathComponent(
          "fixture-recovery",
          isDirectory: true),
        recordsInstallerResult: false)
    }
  #endif

  private func shellQuote(_ text: String) -> String {
    "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private static func cacheBustedURL(from url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    var items = components.queryItems ?? []
    items.removeAll { $0.name == "_t" }
    let token = String(Int(Date().timeIntervalSince1970 * 1000))
    items.append(URLQueryItem(name: "_t", value: token))
    components.queryItems = items
    return components.url ?? url
  }
}
