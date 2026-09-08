import Foundation
import SQLite3

final class AIPlayerStore {
  private let databaseURL: URL
  private var database: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(baseDirectory: URL) throws {
    databaseURL = baseDirectory.appendingPathComponent("history.sqlite")
    try FileManager.default.createDirectory(
      at: baseDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    guard sqlite3_open_v2(
      databaseURL.path,
      &database,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    ) == SQLITE_OK else {
      throw AIPlayerError.operationFailed("播放器历史数据库无法打开。")
    }
    sqlite3_busy_timeout(database, 2_000)
    try execute("PRAGMA journal_mode=WAL")
    try execute("PRAGMA foreign_keys=ON")
    try migrate()
  }

  deinit {
    sqlite3_close(database)
  }

  func record(
    url: URL,
    duration: Double = 0,
    lastPosition: Double = 0
  ) throws {
    let standardized = url.standardizedFileURL
    guard let kind = AIPlayerFormatting.mediaKind(for: standardized) else {
      throw AIPlayerError.unsupportedFormat(url.pathExtension)
    }
    let sql = """
      INSERT INTO history(path, name, kind, format, duration, last_position, last_played_at, is_favorite)
      VALUES(?, ?, ?, ?, ?, ?, ?, 0)
      ON CONFLICT(path) DO UPDATE SET
        name=excluded.name,
        kind=excluded.kind,
        format=excluded.format,
        duration=CASE WHEN excluded.duration > 0 THEN excluded.duration ELSE history.duration END,
        last_position=CASE
          WHEN excluded.last_position > 0 THEN excluded.last_position
          ELSE history.last_position
        END,
        last_played_at=excluded.last_played_at
      """
    try withStatement(sql) { statement in
      bind(standardized.path, at: 1, in: statement)
      bind(standardized.deletingPathExtension().lastPathComponent, at: 2, in: statement)
      bind(kind.rawValue, at: 3, in: statement)
      bind(standardized.pathExtension.uppercased(), at: 4, in: statement)
      sqlite3_bind_double(statement, 5, duration)
      sqlite3_bind_double(statement, 6, lastPosition)
      sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
      try stepDone(statement)
    }
    try execute("""
      DELETE FROM history WHERE path IN (
        SELECT path FROM history ORDER BY last_played_at DESC LIMIT -1 OFFSET 500
      ) AND is_favorite = 0
      """)
  }

  func playbackProgress(path: String) throws -> (position: Double, duration: Double)? {
    var result: (position: Double, duration: Double)?
    try withStatement(
      "SELECT last_position, duration FROM history WHERE path=? LIMIT 1"
    ) { statement in
      bind(URL(fileURLWithPath: path).standardizedFileURL.path, at: 1, in: statement)
      if sqlite3_step(statement) == SQLITE_ROW {
        result = (
          position: sqlite3_column_double(statement, 0),
          duration: sqlite3_column_double(statement, 1))
      }
    }
    return result
  }

  func updateProgress(path: String, position: Double, duration: Double) throws {
    try withStatement(
      "UPDATE history SET last_position=?, duration=CASE WHEN ?>0 THEN ? ELSE duration END WHERE path=?"
    ) { statement in
      sqlite3_bind_double(statement, 1, position)
      sqlite3_bind_double(statement, 2, duration)
      sqlite3_bind_double(statement, 3, duration)
      bind(URL(fileURLWithPath: path).standardizedFileURL.path, at: 4, in: statement)
      try stepDone(statement)
    }
  }

  func history(limit: Int = 500, favoritesOnly: Bool = false) throws -> [AIPlayerMediaItem] {
    let whereClause = favoritesOnly ? "WHERE is_favorite=1" : ""
    return try queryMedia(
      """
      SELECT path, name, kind, format, duration, last_position, last_played_at, is_favorite
      FROM history \(whereClause)
      ORDER BY last_played_at DESC LIMIT ?
      """,
      bindValues: { statement in sqlite3_bind_int(statement, 1, Int32(limit)) }
    )
  }

  func media(inLibrary id: String) throws -> [AIPlayerMediaItem] {
    try queryMedia(
      """
      SELECT h.path, h.name, h.kind, h.format, h.duration, h.last_position,
             h.last_played_at, h.is_favorite
      FROM library_items li JOIN history h ON h.path=li.path
      WHERE li.library_id=? ORDER BY li.sort_order, h.name COLLATE NOCASE
      """,
      bindValues: { statement in self.bind(id, at: 1, in: statement) }
    )
  }

  func setFavorite(path: String, isFavorite: Bool) throws {
    try withStatement("UPDATE history SET is_favorite=? WHERE path=?") { statement in
      sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
      bind(URL(fileURLWithPath: path).standardizedFileURL.path, at: 2, in: statement)
      try stepDone(statement)
    }
  }

  func removeFromHistory(path: String) throws {
    try withStatement("DELETE FROM history WHERE path=?") { statement in
      bind(URL(fileURLWithPath: path).standardizedFileURL.path, at: 1, in: statement)
      try stepDone(statement)
    }
  }

  func libraries() throws -> [AIPlayerLibrary] {
    var result: [AIPlayerLibrary] = []
    try withStatement(
      "SELECT id, name, sort_order, created_at FROM libraries ORDER BY sort_order, created_at"
    ) { statement in
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(
          AIPlayerLibrary(
            id: text(statement, column: 0),
            name: text(statement, column: 1),
            sortOrder: Int(sqlite3_column_int(statement, 2)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
          )
        )
      }
    }
    return result
  }

  @discardableResult
  func createLibrary(name: String) throws -> AIPlayerLibrary {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AIPlayerError.invalidRequest("媒体库名称不能为空。") }
    let library = AIPlayerLibrary(
      id: UUID().uuidString.lowercased(),
      name: String(trimmed.prefix(80)),
      sortOrder: (try libraries().map(\.sortOrder).max() ?? -1) + 1,
      createdAt: Date()
    )
    try withStatement("INSERT INTO libraries(id,name,sort_order,created_at) VALUES(?,?,?,?)") {
      statement in
      bind(library.id, at: 1, in: statement)
      bind(library.name, at: 2, in: statement)
      sqlite3_bind_int(statement, 3, Int32(library.sortOrder))
      sqlite3_bind_double(statement, 4, library.createdAt.timeIntervalSince1970)
      try stepDone(statement)
    }
    return library
  }

  func renameLibrary(id: String, name: String) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AIPlayerError.invalidRequest("媒体库名称不能为空。") }
    try withStatement("UPDATE libraries SET name=? WHERE id=?") { statement in
      bind(String(trimmed.prefix(80)), at: 1, in: statement)
      bind(id, at: 2, in: statement)
      try stepDone(statement)
    }
  }

  func add(path: String, toLibrary id: String) throws {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    try withStatement(
      """
      INSERT OR IGNORE INTO library_items(library_id,path,sort_order)
      VALUES(?,?,COALESCE((SELECT MAX(sort_order)+1 FROM library_items WHERE library_id=?),0))
      """
    ) { statement in
      bind(id, at: 1, in: statement)
      bind(standardized, at: 2, in: statement)
      bind(id, at: 3, in: statement)
      try stepDone(statement)
    }
  }

  func remove(path: String, fromLibrary id: String) throws {
    try withStatement("DELETE FROM library_items WHERE library_id=? AND path=?") { statement in
      bind(id, at: 1, in: statement)
      bind(URL(fileURLWithPath: path).standardizedFileURL.path, at: 2, in: statement)
      try stepDone(statement)
    }
  }

  private func migrate() throws {
    try execute("""
      CREATE TABLE IF NOT EXISTS history(
        path TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        format TEXT NOT NULL,
        duration REAL NOT NULL DEFAULT 0,
        last_position REAL NOT NULL DEFAULT 0,
        last_played_at REAL NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0
      )
      """)
    try execute("""
      CREATE TABLE IF NOT EXISTS libraries(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL
      )
      """)
    try execute("""
      CREATE TABLE IF NOT EXISTS library_items(
        library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
        path TEXT NOT NULL REFERENCES history(path) ON DELETE CASCADE,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(library_id,path)
      )
      """)
  }

  private func queryMedia(
    _ sql: String,
    bindValues: (OpaquePointer?) -> Void
  ) throws -> [AIPlayerMediaItem] {
    var result: [AIPlayerMediaItem] = []
    try withStatement(sql) { statement in
      bindValues(statement)
      while sqlite3_step(statement) == SQLITE_ROW {
        let path = text(statement, column: 0)
        result.append(
          AIPlayerMediaItem(
            id: AIPlayerFormatting.stableID(for: path),
            path: path,
            name: text(statement, column: 1),
            kind: AIPlayerMediaKind(rawValue: text(statement, column: 2)) ?? .audio,
            format: text(statement, column: 3),
            duration: sqlite3_column_double(statement, 4),
            lastPosition: sqlite3_column_double(statement, 5),
            lastPlayedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            isFavorite: sqlite3_column_int(statement, 7) == 1,
            isMissing: !FileManager.default.fileExists(atPath: path)
          )
        )
      }
    }
    return result
  }

  private func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? "SQLite error"
      sqlite3_free(error)
      throw AIPlayerError.operationFailed(message)
    }
  }

  private func withStatement(_ sql: String, body: (OpaquePointer?) throws -> Void) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw AIPlayerError.operationFailed(lastError())
    }
    defer { sqlite3_finalize(statement) }
    try body(statement)
  }

  private func stepDone(_ statement: OpaquePointer?) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw AIPlayerError.operationFailed(lastError())
    }
  }

  private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
    sqlite3_bind_text(statement, index, value, -1, transient)
  }

  private func text(_ statement: OpaquePointer?, column: Int32) -> String {
    guard let value = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: value)
  }

  private func lastError() -> String {
    database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "SQLite error"
  }
}
