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

private let managedLogQueue = DispatchQueue(label: cryptBundleID + ".managedlog")

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
    managedLogQueue.sync { roll(now: now) }
  }

  /// Appends one record, honouring `minimumLevel`.
  public static func write(_ level: CryptLogLevel, category: String, _ text: String) {
    guard level >= minimumLevel else { return }
    let record = "[\(managedLogStamp.string(from: Date()))] "
      + "\(level.label.padding(toLength: 5, withPad: " ", startingAt: 0)) \(category): \(text)\n"
    if echoToStandardOutput {
      FileHandle.standardOutput.write(Data(text.utf8) + Data("\n".utf8))
    }
    managedLogQueue.async { append(record) }
  }

  /// Renames the current log when it was last written on an earlier day and
  /// removes rolled files beyond `managedLogGenerations`.
  static func roll(directory: String = managedLogDirectory, name: String = "crypt.log", now: Date = Date()) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o755])
    let path = directory + "/" + name
    guard let attrs = try? fm.attributesOfItem(atPath: path),
          let modified = attrs[.modificationDate] as? Date,
          !Calendar.current.isDate(modified, inSameDayAs: now)
    else { return }

    let base = (name as NSString).deletingPathExtension
    let rolled = "\(directory)/\(base)-\(rolledLogStamp.string(from: modified)).log"
    if fm.fileExists(atPath: rolled) {
      // Two rolls in one day: append the current file to the existing one.
      if let existing = FileHandle(forWritingAtPath: rolled), let old = fm.contents(atPath: path) {
        existing.seekToEndOfFile()
        existing.write(old)
        existing.closeFile()
      }
      try? fm.removeItem(atPath: path)
    } else {
      try? fm.moveItem(atPath: path, toPath: rolled)
    }
    prune(directory: directory, base: base)
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

  private static func append(_ record: String) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: managedLogDirectory) {
      try? fm.createDirectory(atPath: managedLogDirectory, withIntermediateDirectories: true,
                              attributes: [.posixPermissions: 0o755])
    }
    if !fm.fileExists(atPath: managedLogPath) {
      fm.createFile(atPath: managedLogPath, contents: nil, attributes: [.posixPermissions: 0o644])
    }
    guard let handle = FileHandle(forWritingAtPath: managedLogPath) else { return }
    defer { handle.closeFile() }
    handle.seekToEndOfFile()
    handle.write(Data(record.utf8))
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
  let template = "\(message)"
    .replacingOccurrences(of: "%{public}", with: "%")
    .replacingOccurrences(of: "%{private}", with: "%")
  let text = args.isEmpty ? template : String(format: template, arguments: args)
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
