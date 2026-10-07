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

public let keychainLog = OSLog(subsystem: cryptBundleID, category: "Keychain")
public let filevaultLog = OSLog(subsystem: cryptBundleID, category: "Filevault")
public let prefLog = OSLog(subsystem: cryptBundleID, category: "Preferences")
public let enablementLog = OSLog(subsystem: cryptBundleID, category: "Enablement")
public let coreLog = OSLog(subsystem: cryptBundleID, category: "Core")
public let checkLog = OSLog(subsystem: cryptBundleID, category: "Check")
public let escrowLog = OSLog(subsystem: cryptBundleID, category: "Escrow")
public let authMechsLog = OSLog(subsystem: cryptBundleID, category: "AuthMechs")
public let serverLog = OSLog(subsystem: cryptBundleID, category: "Server")

// The management-tool logging convention: beside the unified log, every record
// is appended to /Library/Managed Encryption/logs/crypt.log as
// "[yyyy-MM-dd HH:mm:ss] LEVEL  Category: message". The authorization plugin
// and the checkin binary write the same file; checkin owns the daily roll.
// The plugin runs as root at the login window, so appending is always
// possible; a failure to write is ignored rather than allowed to interfere
// with authorization.
public let managedLogDirectory = "/Library/Managed Encryption/logs"
public let managedLogPath = managedLogDirectory + "/crypt.log"

/// How many rolled daily log files are kept.
public let managedLogGenerations = 30

public enum CryptLogLevel: Int, Sendable, Comparable {
  case debug = 0, info, warning, error

  public var label: String {
    switch self {
    case .debug: return "DEBUG"
    case .info: return "INFO"
    case .warning: return "WARN"
    case .error: return "ERROR"
    }
  }

  public static func < (lhs: CryptLogLevel, rhs: CryptLogLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

private let cryptLogCategories: [ObjectIdentifier: String] = [
  ObjectIdentifier(keychainLog): "Keychain",
  ObjectIdentifier(filevaultLog): "Filevault",
  ObjectIdentifier(prefLog): "Preferences",
  ObjectIdentifier(enablementLog): "Enablement",
  ObjectIdentifier(coreLog): "Core",
  ObjectIdentifier(checkLog): "Check",
  ObjectIdentifier(escrowLog): "Escrow",
  ObjectIdentifier(authMechsLog): "AuthMechs",
  ObjectIdentifier(serverLog): "Server",
]

// Serializes records within this process so a multi-line record reaches the
// file in one write(2); O_APPEND keeps records from other processes whole.
private let managedLogLock = NSLock()

private let managedLogStamp: DateFormatter = {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.dateFormat = "yyyy-MM-dd HH:mm:ss"
  return f
}()

private let rolledLogStamp: DateFormatter = {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.dateFormat = "yyyy-MM-dd"
  return f
}()

/// Runtime configuration of the managed log. `minimumLevel` drops quieter
/// records, and `echoToStandardOutput` mirrors them to the terminal so an
/// administrator running checkin by hand still sees the output.
public enum ManagedLog {
  private static let state = ManagedLogState()

  public static var minimumLevel: CryptLogLevel {
    get { state.minimumLevel }
    set { state.minimumLevel = newValue }
  }

  public static var echoToStandardOutput: Bool {
    get { state.echo }
    set { state.echo = newValue }
  }

  /// Prepares the log directory and rolls yesterday's file. Safe to call more
  /// than once; a directory that cannot be created is not fatal, the records
  /// simply go to the unified log and, when echoing, to stdout.
  public static func prepare(now: Date = Date()) {
    managedLogLock.withLock { roll(now: now) }
  }

  /// Appends one record, honouring `minimumLevel`. Written synchronously:
  /// authorizationhost can exit or crash straight after a record is logged,
  /// and a queued write would be lost with it.
  public static func write(_ level: CryptLogLevel, category: String, _ text: String) {
    guard level >= minimumLevel else { return }
    if echoToStandardOutput {
      FileHandle.standardOutput.write(Data(text.utf8) + Data("\n".utf8))
    }
    let block = managedLogRecords(text, level: level.label, category: category,
                                  stamp: managedLogStamp.string(from: Date()))
    managedLogLock.withLock { appendManagedLog(block) }
  }

  /// Moves records written on earlier days into crypt-yyyy-MM-dd.log and
  /// removes rolled files beyond `managedLogGenerations`. The day comes from
  /// the "[yyyy-MM-dd HH:mm:ss]" that opens each record, not the file's mtime,
  /// which other writers keep moving. The live file is renamed to a private name
  /// before it is read, so writers that append meanwhile recreate it; the
  /// private copy is removed only once all of it reached the rolled files.
  static func roll(directory: String = managedLogDirectory, name: String = "crypt.log", now: Date = Date()) {
    makeManagedLogDirectory(directory)
    let fm = FileManager.default
    let path = directory + "/" + name
    let base = (name as NSString).deletingPathExtension
    let pending = "\(directory)/.\(base).rolling"
    let today = rolledLogStamp.string(from: now)
    if !fm.fileExists(atPath: pending) {
      guard let data = fm.contents(atPath: path),
            let text = String(data: data, encoding: .utf8),
            let first = recordDay(text), first != today,
            rename(path, pending) == 0
      else { return }
    }
    guard let data = fm.contents(atPath: pending), let text = String(data: data, encoding: .utf8) else { return }
    var byDay: [(String, String)] = []
    var day = recordDay(text) ?? today
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
      if let d = recordDay(String(line)) { day = d }
      if let last = byDay.last, last.0 == day {
        byDay[byDay.count - 1].1 += line + "\n"
      } else {
        byDay.append((day, line + "\n"))
      }
    }
    var complete = true
    for (d, chunk) in byDay {
      let target = d == today ? path : "\(directory)/\(base)-\(d).log"
      if !appendManagedLog(chunk, path: target, directory: directory) { complete = false }
    }
    if complete { _ = unlink(pending) }
    prune(directory: directory, base: base)
  }

  /// The yyyy-MM-dd that opens a record line, if the text starts with one.
  static func recordDay(_ text: String) -> String? {
    guard text.hasPrefix("["), text.count >= 11 else { return nil }
    let day = String(text.dropFirst().prefix(10))
    return rolledLogStamp.date(from: day) == nil ? nil : day
  }

  private static func prune(directory: String, base: String) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return }
    let rolled = entries
      .filter { $0.hasPrefix(base + "-") && $0.hasSuffix(".log") }
      .sorted()  // yyyy-MM-dd names sort chronologically
    guard rolled.count > managedLogGenerations else { return }
    for stale in rolled.prefix(rolled.count - managedLogGenerations) {
      try? fm.removeItem(atPath: directory + "/" + stale)
    }
  }

}

/// Formats one message as managed-log records, one per non-empty line, each
/// with the "[timestamp] LEVEL Category:" prefix.
func managedLogRecords(_ text: String, level: String, category: String, stamp: String) -> String {
  let padded = level.padding(toLength: 5, withPad: " ", startingAt: 0)
  var out = ""
  // "\r\n" is one Character in Swift, so it is matched as a separator itself.
  let lines = text.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
  for line in lines {
    out += "[\(stamp)] \(padded) \(category): \(line)\n"
  }
  return out
}

/// Fills an os_log format string for the managed log file without
/// String(format:). String(format:) reads `%s` as a C pointer, so a Swift
/// String logged with `%{public}s` crashed the authorization plugin in strlen
/// at login. Each specifier is replaced by its argument's description instead,
/// which cannot misread memory whatever the specifier says.
func renderManagedLog(_ template: String, _ args: [CVarArg]) -> String {
  var out = ""
  var next = args.makeIterator()
  var chars = template[...]
  while let i = chars.firstIndex(of: "%") {
    out += chars[..<i]
    var j = chars.index(after: i)
    if j < chars.endIndex, chars[j] == "%" {
      out += "%"
      chars = chars[chars.index(after: j)...]
      continue
    }
    if j < chars.endIndex, chars[j] == "{", let close = chars[j...].firstIndex(of: "}") {
      j = chars.index(after: close)
    }
    // Flags, width, precision and length modifiers, then the conversion.
    while j < chars.endIndex, "-+ #0123456789.hlqLzjt".contains(chars[j]) {
      j = chars.index(after: j)
    }
    guard j < chars.endIndex else {
      out += chars[i...]
      chars = chars[chars.endIndex...]
      break
    }
    out += next.next().map { String(describing: $0) } ?? "<missing>"
    chars = chars[chars.index(after: j)...]
  }
  out += chars
  return out
}

/// Appends text to the managed log with POSIX calls only, returning whether
/// all of it was written. Every failure is otherwise ignored: this runs inside
/// authorizationhost, where a trap or an Objective-C exception from FileHandle
/// would lock the user out of the Mac. The file is opened with O_APPEND for
/// each record, so the plugin and the checkin never overwrite each other, and
/// a file the checkin rolled away is recreated.
@discardableResult
func appendManagedLog(_ text: String, path: String = managedLogPath,
                      directory: String = managedLogDirectory) -> Bool {
  let bytes = Array(text.utf8)
  if bytes.isEmpty { return true }
  let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW
  var fd = open(path, flags, mode_t(0o644))
  if fd < 0 && errno == ENOENT {
    makeManagedLogDirectory(directory)
    fd = open(path, flags, mode_t(0o644))
  }
  if fd < 0 { return false }
  defer { _ = close(fd) }
  return bytes.withUnsafeBytes { buf -> Bool in
    guard let base = buf.baseAddress else { return false }
    var offset = 0
    while offset < buf.count {
      let n = Darwin.write(fd, base + offset, buf.count - offset)
      if n > 0 {
        offset += n
      } else if n < 0 && errno == EINTR {
        continue
      } else {
        return false
      }
    }
    return true
  }
}

/// mkdir -p with mkdir(2), ignoring every error; the open that follows is
/// what decides whether the record can be written.
private func makeManagedLogDirectory(_ directory: String) {
  var partial = ""
  for component in directory.split(separator: "/", omittingEmptySubsequences: true) {
    partial += "/" + component
    _ = mkdir(partial, mode_t(0o755))
  }
}

/// Mutable configuration behind a lock, so the log can be reconfigured from the
/// command line while records are being written from any queue.
private final class ManagedLogState: @unchecked Sendable {
  private let lock = NSLock()
  private var level: CryptLogLevel = .info
  private var echoOut: Bool = isatty(STDOUT_FILENO) == 1

  var minimumLevel: CryptLogLevel {
    get { lock.withLock { level } }
    set { lock.withLock { level = newValue } }
  }

  var echo: Bool {
    get { lock.withLock { echoOut } }
    set { lock.withLock { echoOut = newValue } }
  }
}

private func managedLogLevel(_ type: OSLogType) -> CryptLogLevel {
  switch type {
  case .error, .fault: return .error
  case .debug: return .debug
  default: return .info
  }
}

/// Logs to the unified log exactly as os_log would, and appends the same
/// record to the managed log file. Format arguments are the os_log ones.
public func cryptLog(_ message: StaticString, log: OSLog = .default, type: OSLogType = .default, _ args: CVarArg...) {
  switch args.count {
  case 0: os_log(message, log: log, type: type)
  case 1: os_log(message, log: log, type: type, args[0])
  case 2: os_log(message, log: log, type: type, args[0], args[1])
  case 3: os_log(message, log: log, type: type, args[0], args[1], args[2])
  default: os_log(message, log: log, type: type, args[0], args[1], args[2], args[3])
  }
  let text = renderManagedLog("\(message)", args)
  let category = cryptLogCategories[ObjectIdentifier(log)] ?? "Crypt"
  ManagedLog.write(managedLogLevel(type), category: category, text)
}

/// Records one line at the given level. The string form is what the checkin
/// binary uses; the plugin keeps the os_log-shaped `cryptLog` above.
public func cryptLog(_ level: CryptLogLevel, _ log: OSLog, _ text: String) {
  let osType: OSLogType
  switch level {
  case .debug: osType = .debug
  case .info: osType = .default
  case .warning: osType = .default
  case .error: osType = .error
  }
  os_log("%{public}@", log: log, type: osType, text)
  ManagedLog.write(level, category: cryptLogCategories[ObjectIdentifier(log)] ?? "Crypt", text)
}
