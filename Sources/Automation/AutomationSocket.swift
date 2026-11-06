import Darwin
import Foundation
import Security

struct AutomationSocketError: LocalizedError {
  let code: String
  let message: String
  var errorDescription: String? { message }

  static let appNotRunning = AutomationSocketError(
    code: "appNotRunning",
    message: "请先打开已安装的小龙哥 Mac 哲学：open -g '/Applications/小龙哥Mac哲学.app'")
}

struct AutomationSocketConfiguration: Sendable {
  let directory: URL
  let verifyInstalledIdentity: Bool
  let maximumMessageBytes: Int
  let timeout: TimeInterval
  let maximumConnections: Int

  static var installed: AutomationSocketConfiguration {
    AutomationSocketConfiguration(
      directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/aixlg-hotkeys/automation"),
      verifyInstalledIdentity: true)
  }

  /// Non-installed configurations are only for isolated transport fixtures. The CLI always
  /// uses `.installed`; it has no argument or environment override for identity verification.
  init(
    directory: URL,
    verifyInstalledIdentity: Bool = true,
    maximumMessageBytes: Int = AutomationDiscovery.maximumRequestBytes,
    timeout: TimeInterval = 10,
    maximumConnections: Int = 8
  ) {
    // Do not use standardizedFileURL here: Foundation may rewrite an existing
    // /private/tmp path to the /tmp symlink, changing the path after validation.
    self.directory = directory
    self.verifyInstalledIdentity = verifyInstalledIdentity
    self.maximumMessageBytes = max(1, min(maximumMessageBytes, AutomationDiscovery.maximumRequestBytes))
    self.timeout = max(0.1, min(timeout, 30))
    self.maximumConnections = max(1, min(maximumConnections, 16))
  }

  var socketURL: URL { directory.appendingPathComponent("control.sock") }
}

private enum AutomationSocketIO {
  static func failure(_ code: String, _ message: String) -> AutomationSocketError {
    AutomationSocketError(code: code, message: message)
  }

  static func fileStatus(_ path: String) -> stat? {
    var value = stat()
    guard lstat(path, &value) == 0 else { return nil }
    return value
  }

  static func validateDirectory(_ url: URL, create: Bool) throws {
    guard url.isFileURL, url.path.hasPrefix("/"),
      !url.pathComponents.contains("."), !url.pathComponents.contains("..")
    else {
      throw failure("unsafePath", "CLI 服务目录必须是绝对本地路径。")
    }
    var cursor = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.pathComponents.dropFirst() {
      cursor.appendPathComponent(component, isDirectory: true)
      if fileStatus(cursor.path) == nil {
        guard create, errno == ENOENT, mkdir(cursor.path, 0o700) == 0 else {
          throw create ? failure("unsafePath", "CLI 服务目录无法安全创建。") : .appNotRunning
        }
      }
      guard let info = fileStatus(cursor.path),
        (info.st_mode & S_IFMT) == S_IFDIR
      else { throw failure("unsafePath", "CLI 服务路径包含软链或非目录：\(cursor.path)") }
      if cursor.path == url.path {
        guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
          throw failure("unsafePermissions", "CLI 服务目录必须由当前用户持有，且权限为 700。")
        }
      }
    }
  }

  static func validateSocket(_ url: URL) throws -> stat {
    guard let info = fileStatus(url.path) else { throw AutomationSocketError.appNotRunning }
    guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0
    else { throw failure("unsafeSocket", "CLI 连接不是当前用户的私有 socket。") }
    return info
  }

  static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T)
    throws -> T
  {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let encoded = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard encoded.count <= capacity else {
      throw failure("pathTooLong", "用户目录过长，无法建立本机 CLI socket。")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      for (index, byte) in encoded.enumerated() { bytes[index] = UInt8(bitPattern: byte) }
    }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    address.sun_len = UInt8(length)
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
    }
  }

  static func configure(_ descriptor: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
      socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw failure("transportUnavailable", "无法配置本机 CLI 连接。") }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
  }

  static func wait(_ descriptor: Int32, events: Int16, deadline: TimeInterval) throws {
    while true {
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { throw failure("timeout", "CLI 请求超时；请用原 request-id 查询结果。") }
      var item = pollfd(fd: descriptor, events: events, revents: 0)
      let milliseconds = Int32(min(remaining * 1_000, Double(Int32.max)).rounded(.up))
      let result = Darwin.poll(&item, 1, milliseconds)
      if result < 0, errno == EINTR { continue }
      guard result > 0 else { throw failure("timeout", "CLI 请求超时；请用原 request-id 查询结果。") }
      guard item.revents & (Int16(POLLNVAL) | Int16(POLLERR)) == 0 else {
        throw failure("connectionClosed", "CLI 连接已中断；请用原 request-id 查询结果。")
      }
      return
    }
  }

  static func write(_ data: Data, to descriptor: Int32, deadline: TimeInterval) throws {
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
        let count = Darwin.send(descriptor, base.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
        if count < 0, errno == EINTR || errno == EAGAIN { continue }
        guard count > 0 else { throw failure("connectionClosed", "CLI 连接在发送时中断。") }
        offset += count
      }
    }
  }

  static func read(_ count: Int, from descriptor: Int32, deadline: TimeInterval) throws -> Data {
    var result = Data(count: count)
    try result.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < count {
        try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
        let received = Darwin.recv(descriptor, base.advanced(by: offset), count - offset, MSG_DONTWAIT)
        if received < 0, errno == EINTR || errno == EAGAIN { continue }
        guard received > 0 else { throw failure("connectionClosed", "CLI 连接在接收完整消息前中断。") }
        offset += received
      }
    }
    return result
  }

  static func writeFrame(
    _ data: Data, to descriptor: Int32, configuration: AutomationSocketConfiguration,
    maximumBytes: Int? = nil
  )
    throws
  {
    guard !data.isEmpty, data.count <= (maximumBytes ?? configuration.maximumMessageBytes) else {
      throw failure("messageTooLarge", "CLI 消息超过大小限制。")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + configuration.timeout
    var size = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &size) { try write(Data($0), to: descriptor, deadline: deadline) }
    try write(data, to: descriptor, deadline: deadline)
  }

  static func readFrame(
    from descriptor: Int32, configuration: AutomationSocketConfiguration, maximumBytes: Int? = nil
  ) throws -> Data {
    let deadline = ProcessInfo.processInfo.systemUptime + configuration.timeout
    let header = try read(4, from: descriptor, deadline: deadline)
    let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard size > 0, size <= (maximumBytes ?? configuration.maximumMessageBytes) else {
      throw failure("messageTooLarge", "CLI 消息超过大小限制。")
    }
    return try read(Int(size), from: descriptor, deadline: deadline)
  }

  static func requireSameUser(_ descriptor: Int32) throws {
    var user: uid_t = 0
    var group: gid_t = 0
    guard getpeereid(descriptor, &user, &group) == 0, user == getuid() else {
      throw failure("peerRejected", "CLI 连接必须来自当前登录用户。")
    }
  }

  static var requirement: SecRequirement? {
    let text =
      "identifier \"\(AutomationDiscovery.bundleIdentifier)\" and anchor apple generic"
      + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
      + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
      + " and certificate leaf[subject.OU] = \"\(AutomationDiscovery.teamIdentifier)\""
    var result: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, SecCSFlags(rawValue: 0), &result)
      == errSecSuccess else { return nil }
    return result
  }

  static func requireInstalledApplication() throws {
    let appURL = URL(fileURLWithPath: AutomationDiscovery.installedApplicationPath)
    guard appURL.resolvingSymlinksInPath().path == appURL.path,
      let bundle = Bundle(url: appURL),
      bundle.bundleIdentifier == AutomationDiscovery.bundleIdentifier,
      bundle.executableURL?.path == AutomationDiscovery.installedExecutablePath,
      bundle.object(forInfoDictionaryKey: "AIXLGBuildChannel") as? String == "stable",
      let requirement
    else { throw failure("invalidInstalledIdentity", "未找到身份正确的已安装稳定版 App。") }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(rawValue: 0), &code)
      == errSecSuccess, let code,
      SecStaticCodeCheckValidity(
        code,
        SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures)),
        requirement) == errSecSuccess
    else { throw failure("invalidInstalledIdentity", "已安装 App 的开发者签名验证失败。") }
  }

  static func requireInstalledPeer(_ descriptor: Int32) throws {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
      throw failure("peerRejected", "无法核实 CLI 服务进程身份。")
    }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
      String(cString: path) == AutomationDiscovery.installedExecutablePath,
      let requirement
    else { throw failure("peerRejected", "CLI 服务不属于已安装的稳定版 App。") }
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(
      nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary,
      SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code,
      SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement) == errSecSuccess
    else { throw failure("peerRejected", "CLI 服务开发者身份验证失败。") }
  }
}

struct AutomationSocketClient {
  let configuration: AutomationSocketConfiguration

  init(configuration: AutomationSocketConfiguration = .installed) {
    self.configuration = configuration
  }

  func send(_ request: Data) throws -> Data {
    if configuration.verifyInstalledIdentity { try AutomationSocketIO.requireInstalledApplication() }
    try AutomationSocketIO.validateDirectory(configuration.directory, create: false)
    _ = try AutomationSocketIO.validateSocket(configuration.socketURL)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw AutomationSocketError(code: "transportUnavailable", message: "无法建立 CLI 连接。")
    }
    defer { Darwin.close(descriptor) }
    try AutomationSocketIO.configure(descriptor)
    let previousFlags = fcntl(descriptor, F_GETFL)
    guard previousFlags >= 0, fcntl(descriptor, F_SETFL, previousFlags | O_NONBLOCK) == 0 else {
      throw AutomationSocketError(code: "transportUnavailable", message: "无法配置 CLI 连接。")
    }
    let connected = try AutomationSocketIO.withAddress(configuration.socketURL.path) {
      Darwin.connect(descriptor, $0, $1)
    }
    if connected != 0 {
      guard errno == EINPROGRESS else { throw AutomationSocketError.appNotRunning }
      try AutomationSocketIO.wait(
        descriptor, events: Int16(POLLOUT),
        deadline: ProcessInfo.processInfo.systemUptime + configuration.timeout)
      var socketError: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
        socketError == 0 else { throw AutomationSocketError.appNotRunning }
    }
    try AutomationSocketIO.requireSameUser(descriptor)
    if configuration.verifyInstalledIdentity { try AutomationSocketIO.requireInstalledPeer(descriptor) }
    try AutomationSocketIO.writeFrame(request, to: descriptor, configuration: configuration)
    return try AutomationSocketIO.readFrame(
      from: descriptor, configuration: configuration,
      maximumBytes: AutomationDiscovery.maximumResponseBytes)
  }
}

final class AutomationSocketServer: @unchecked Sendable {
  typealias Handler = @MainActor @Sendable (Data) async -> Data

  private let configuration: AutomationSocketConfiguration
  private let state = NSLock()
  private let acceptQueue = DispatchQueue(label: "cn.tlww.aixlg.automation.accept")
  private let clientsQueue = DispatchQueue(
    label: "cn.tlww.aixlg.automation.clients", attributes: .concurrent)
  private var descriptor: Int32 = -1
  private var lockDescriptor: Int32 = -1
  private var clients: Set<Int32> = []
  private var socketIdentity: (dev_t, ino_t)?
  private var handler: Handler?
  private var generation: UInt64 = 0
  private var processing: [Int32: Task<Void, Never>] = [:]

  init(configuration: AutomationSocketConfiguration = .installed) {
    self.configuration = configuration
  }

  deinit { stop() }

  func start(handler: @escaping Handler) throws {
    state.lock()
    defer { state.unlock() }
    guard descriptor < 0 else { return }
    if configuration.verifyInstalledIdentity { try AutomationSocketIO.requireInstalledApplication() }
    try AutomationSocketIO.validateDirectory(configuration.directory, create: true)
    let lockPath = configuration.directory.appendingPathComponent("service.lock").path
    let lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lockFD >= 0 else {
      throw AutomationSocketError(code: "unsafeLock", message: "CLI 服务锁无法安全打开。")
    }
    var lockInfo = stat()
    guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == getuid(),
      lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_mode & 0o077 == 0,
      flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(lockFD)
      throw AutomationSocketError(code: "serviceBusy", message: "已有 CLI 服务占用或服务锁不安全。")
    }
    var success = false
    defer { if !success { Darwin.close(lockFD) } }
    if AutomationSocketIO.fileStatus(configuration.socketURL.path) != nil {
      _ = try AutomationSocketIO.validateSocket(configuration.socketURL)
      let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard probe >= 0 else { throw AutomationSocketError.appNotRunning }
      let result: Int32
      let error: Int32
      do {
        defer { Darwin.close(probe) }
        let flags = fcntl(probe, F_GETFL)
        guard flags >= 0, fcntl(probe, F_SETFL, flags | O_NONBLOCK) == 0 else {
          throw AutomationSocketError(code: "serviceBusy", message: "无法安全检查旧 CLI 服务。")
        }
        result = try AutomationSocketIO.withAddress(configuration.socketURL.path) {
          Darwin.connect(probe, $0, $1)
        }
        error = errno
      }
      guard result != 0, error == ECONNREFUSED else {
        throw AutomationSocketError(code: "serviceBusy", message: "已有可连接的 CLI 服务，未替换。")
      }
      guard unlink(configuration.socketURL.path) == 0 else {
        throw AutomationSocketError(code: "unsafeSocket", message: "无法清理已停止的 CLI 服务 socket。")
      }
    }
    let server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else { throw AutomationSocketError.appNotRunning }
    defer { if !success { Darwin.close(server) } }
    try AutomationSocketIO.configure(server)
    let result = try AutomationSocketIO.withAddress(configuration.socketURL.path) {
      Darwin.bind(server, $0, $1)
    }
    guard result == 0 else {
      throw AutomationSocketError(code: "bindFailed", message: "CLI 服务无法绑定本机 socket。")
    }
    guard chmod(configuration.socketURL.path, 0o600) == 0,
      Darwin.listen(server, Int32(configuration.maximumConnections)) == 0,
      let info = AutomationSocketIO.fileStatus(configuration.socketURL.path)
    else {
      unlink(configuration.socketURL.path)
      throw AutomationSocketError(code: "listenFailed", message: "CLI 服务无法开始监听。")
    }
    socketIdentity = (info.st_dev, info.st_ino)
    self.handler = handler
    lockDescriptor = lockFD
    descriptor = server
    generation &+= 1
    let serverGeneration = generation
    success = true
    acceptQueue.async { [weak self] in self?.acceptLoop(server, generation: serverGeneration) }
  }

  func stop() {
    state.lock()
    let server = descriptor
    let serviceLock = lockDescriptor
    let activeClients = clients
    let activeTasks = Array(processing.values)
    let identity = socketIdentity
    descriptor = -1
    lockDescriptor = -1
    handler = nil
    socketIdentity = nil
    generation &+= 1
    processing.removeAll()
    state.unlock()
    if server >= 0 {
      Darwin.shutdown(server, SHUT_RDWR)
      Darwin.close(server)
    }
    for client in activeClients { Darwin.shutdown(client, SHUT_RDWR) }
    for task in activeTasks { task.cancel() }
    if let identity, let current = AutomationSocketIO.fileStatus(configuration.socketURL.path),
      current.st_dev == identity.0, current.st_ino == identity.1
    {
      unlink(configuration.socketURL.path)
    }
    if serviceLock >= 0 { Darwin.close(serviceLock) }
  }

  private func acceptLoop(_ server: Int32, generation: UInt64) {
    while true {
      state.lock()
      let running = descriptor == server && self.generation == generation
      state.unlock()
      guard running else { return }
      let client = Darwin.accept(server, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        return
      }
      state.lock()
      let admitted =
        descriptor == server && self.generation == generation
        && clients.count < configuration.maximumConnections
      if admitted { clients.insert(client) }
      state.unlock()
      guard admitted else { Darwin.close(client); continue }
      clientsQueue.async { [weak self] in
        guard let self else { Darwin.close(client); return }
        self.handle(client, generation: generation)
        self.state.lock()
        self.clients.remove(client)
        self.state.unlock()
        Darwin.close(client)
      }
    }
  }

  private func handle(_ client: Int32, generation: UInt64) {
    do {
      try AutomationSocketIO.configure(client)
      try AutomationSocketIO.requireSameUser(client)
      let request = try AutomationSocketIO.readFrame(from: client, configuration: configuration)
      guard (try JSONSerialization.jsonObject(with: request)) is [String: Any] else {
        throw AutomationSocketError(code: "invalidJSON", message: "CLI 请求必须是 JSON 对象。")
      }
      state.lock()
      let requestHandler = handler
      let running = self.generation == generation && descriptor >= 0
      state.unlock()
      guard running, let requestHandler else { return }
      let responseBox = AutomationResponseBox()
      let task = Task { @MainActor [weak self] in
        // stop() can run after this task is created but before it is registered below.
        // Recheck on the main actor, immediately before the synchronous app adapter runs.
        guard let self, !Task.isCancelled, self.acceptsRequests(generation: generation) else { return }
        responseBox.complete(await requestHandler(request))
      }
      state.lock()
      if self.generation == generation && descriptor >= 0 {
        processing[client] = task
      } else {
        task.cancel()
      }
      state.unlock()
      defer {
        state.lock()
        processing.removeValue(forKey: client)
        state.unlock()
      }
      guard responseBox.ready.wait(timeout: .now() + configuration.timeout) == .success else {
        task.cancel()
        throw AutomationSocketError(code: "timeout", message: "处理超时；请用原 request-id 查询结果。")
      }
      guard let response = responseBox.value else { return }
      try AutomationSocketIO.writeFrame(
        response, to: client, configuration: configuration,
        maximumBytes: AutomationDiscovery.maximumResponseBytes)
    } catch {
      let error = error as? AutomationSocketError
        ?? AutomationSocketError(code: "invalidRequest", message: "CLI 请求未能处理。")
      try? AutomationSocketIO.writeFrame(
        AutomationDiscovery.failure(code: error.code, message: error.message),
        to: client, configuration: configuration)
    }
  }

  private func acceptsRequests(generation: UInt64) -> Bool {
    state.lock()
    defer { state.unlock() }
    return self.generation == generation && descriptor >= 0 && handler != nil
  }
}

private final class AutomationResponseBox: @unchecked Sendable {
  let ready = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var stored: Data?
  var value: Data? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func complete(_ data: Data) {
    lock.lock()
    stored = data
    lock.unlock()
    ready.signal()
  }
}
