/*
 Crypt

 Copyright 2025 The Crypt Project.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import Foundation
import os.log

/// Severity written into the file log. Maps from `OSLogType` so the same call
/// site can feed both the unified log and the file.
enum FileLogLevel: String {
  case debug = "DEBUG"
  case info = "INFO"
  case warn = "WARN"
  case error = "ERROR"

  init(_ type: OSLogType) {
    switch type {
    case .debug:
      self = .debug
    case .error, .fault:
      self = .error
    default:
      self = .info
    }
  }

  /// Level name left-padded to five characters so the message column lines up.
  var padded: String {
    return String(repeating: " ", count: max(0, 5 - rawValue.count)) + rawValue
  }
}

/// Appends log lines to a plain text file next to the unified log.
///
/// Lines are written as `[yyyy-MM-dd HH:mm:ss] LEVEL  message` in local time.
/// The file rolls to `crypt-yyyy-MM-dd.log` on the first write of a new day
/// and the newest thirty rolled files are kept. The system location is
/// `/Library/Managed Encryption/logs/crypt.log`; when that directory cannot be
/// written (for example when running as a normal user) the logger falls back
/// to `~/Library/Logs/crypt.log` with the same rules.
///
/// Callers must never pass a recovery key, escrow payload, password or any
/// other secret. Log that an action happened and its outcome, not its inputs.
final class FileLog {

  static let shared = FileLog()

  static let systemDirectory = "/Library/Managed Encryption/logs"
  static let fileName = "crypt.log"
  static let keep = 30

  let directory: URL
  private let queue = DispatchQueue(label: "\(cryptBundleID).filelog")
  private let calendar: Calendar
  private let lineFormatter: DateFormatter
  private let dayFormatter: DateFormatter

  /// - Parameters:
  ///   - directory: Directory to write into. When nil the system directory is
  ///     used, falling back to the user's `~/Library/Logs`.
  ///   - calendar: Calendar used to decide day boundaries and format stamps.
  init(directory: URL? = nil, calendar: Calendar = Calendar.current) {
    self.calendar = calendar
    self.directory = directory ?? FileLog.resolveDirectory()

    let line = DateFormatter()
    line.calendar = calendar
    line.timeZone = calendar.timeZone
    line.locale = Locale(identifier: "en_US_POSIX")
    line.dateFormat = "yyyy-MM-dd HH:mm:ss"
    self.lineFormatter = line

    let day = DateFormatter()
    day.calendar = calendar
    day.timeZone = calendar.timeZone
    day.locale = Locale(identifier: "en_US_POSIX")
    day.dateFormat = "yyyy-MM-dd"
    self.dayFormatter = day

    FileLog.ensureDirectory(self.directory)
  }

  var fileURL: URL {
    return directory.appendingPathComponent(FileLog.fileName, isDirectory: false)
  }

  // MARK: Writing

  func write(_ message: String, level: FileLogLevel, date: Date = Date()) {
    let line = formatLine(message, level: level, date: date)
    queue.sync {
      rotateIfNeeded(now: date)
      append(line)
    }
  }

  func write(_ message: String, type: OSLogType, date: Date = Date()) {
    write(message, level: FileLogLevel(type), date: date)
  }

  /// Builds one log line. Embedded newlines are flattened so every record
  /// stays on a single line.
  func formatLine(_ message: String, level: FileLogLevel, date: Date) -> String {
    let flat = message
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    return "[\(lineFormatter.string(from: date))] \(level.padded)  \(flat)\n"
  }

  private func append(_ line: String) {
    let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else {
      os_log("Unable to open %{public}@ for appending: errno %d", log: coreLog, type: .error, fileURL.path, errno)
      return
    }
    defer { close(fd) }
    var data = Array(line.utf8)
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeMutableBytes { buffer -> Int in
        return Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
      }
      if written <= 0 { break }
      offset += written
    }
  }

  // MARK: Rotation

  /// Rolls `crypt.log` to `crypt-yyyy-MM-dd.log` (dated by its last write)
  /// when the current file was last written on an earlier day, then prunes
  /// rolled files beyond the retention count.
  func rotateIfNeeded(now: Date) {
    let fm = FileManager.default
    guard let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
          let modified = attributes[.modificationDate] as? Date else {
      return
    }
    if calendar.isDate(modified, inSameDayAs: now) || modified > now {
      return
    }

    let rolled = directory.appendingPathComponent("crypt-\(dayFormatter.string(from: modified)).log", isDirectory: false)
    if fm.fileExists(atPath: rolled.path) {
      // Another process already rolled this day. Fold our content into it
      // rather than clobbering what it wrote.
      if let handle = try? FileHandle(forWritingTo: rolled),
         let data = fm.contents(atPath: fileURL.path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
      }
      try? fm.removeItem(at: fileURL)
    } else {
      do {
        try fm.moveItem(at: fileURL, to: rolled)
      } catch {
        os_log("Unable to roll %{public}@: %{public}@", log: coreLog, type: .error, fileURL.path, error.localizedDescription)
        return
      }
    }
    prune()
  }

  /// Names of rolled files in the directory, newest first.
  func rolledFiles() -> [String] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
    return names
      .filter { FileLog.isRolledName($0) }
      .sorted(by: >)
  }

  private func prune() {
    let excess = rolledFiles().dropFirst(FileLog.keep)
    for name in excess {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
    }
  }

  static func isRolledName(_ name: String) -> Bool {
    // crypt-yyyy-MM-dd.log
    guard name.hasPrefix("crypt-"), name.hasSuffix(".log"), name.count == 20 else { return false }
    let stamp = name.dropFirst(6).dropLast(4)
    for (index, character) in stamp.enumerated() {
      if index == 4 || index == 7 {
        if character != "-" { return false }
      } else if !character.isNumber {
        return false
      }
    }
    return true
  }

  // MARK: Location

  private static func resolveDirectory() -> URL {
    let system = URL(fileURLWithPath: systemDirectory, isDirectory: true)
    ensureDirectory(system)
    if FileManager.default.isWritableFile(atPath: system.path) {
      return system
    }
    let user = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Logs", isDirectory: true)
    ensureDirectory(user)
    return user
  }

  private static func ensureDirectory(_ url: URL) {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
      return
    }
    var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
    if geteuid() == 0 {
      attributes[.ownerAccountID] = 0
      attributes[.groupOwnerAccountID] = 0
    }
    try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
  }
}
