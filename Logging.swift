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

let keychainLog = OSLog(subsystem: cryptBundleID, category: "Keychain")
let filevaultLog = OSLog(subsystem: cryptBundleID, category: "Filevault")
let prefLog = OSLog(subsystem: cryptBundleID, category: "Preferences")
let enablementLog = OSLog(subsystem: cryptBundleID, category: "Enablement")
let coreLog = OSLog(subsystem: cryptBundleID, category: "Core")
let checkLog = OSLog(subsystem: cryptBundleID, category: "Check")

// The management-tool logging convention: beside the unified log, every record
// is appended to /Library/Managed Encryption/logs/crypt.log as
// "[yyyy-MM-dd HH:mm:ss] LEVEL  Category: message", the same file the checkin
// daemon writes and rolls daily. The plugin runs as root at the login window,
// so appending is always possible; a failure to write is ignored rather than
// allowed to interfere with authorization.
let managedLogDirectory = "/Library/Managed Encryption/logs"
let managedLogPath = managedLogDirectory + "/crypt.log"

private let cryptLogCategories: [ObjectIdentifier: String] = [
  ObjectIdentifier(keychainLog): "Keychain",
  ObjectIdentifier(filevaultLog): "Filevault",
  ObjectIdentifier(prefLog): "Preferences",
  ObjectIdentifier(enablementLog): "Enablement",
  ObjectIdentifier(coreLog): "Core",
  ObjectIdentifier(checkLog): "Check",
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

private func managedLogLevel(_ type: OSLogType) -> String {
  switch type {
  case .error, .fault: return "ERROR"
  case .debug: return "DEBUG"
  default: return "INFO"
  }
}

/// Logs to the unified log exactly as os_log would, and appends the same
/// record to the managed log file. Format arguments are the os_log ones.
func cryptLog(_ message: StaticString, log: OSLog = .default, type: OSLogType = .default, _ args: CVarArg...) {
  switch args.count {
  case 0: os_log(message, log: log, type: type)
  case 1: os_log(message, log: log, type: type, args[0])
  case 2: os_log(message, log: log, type: type, args[0], args[1])
  case 3: os_log(message, log: log, type: type, args[0], args[1], args[2])
  default: os_log(message, log: log, type: type, args[0], args[1], args[2], args[3])
  }
  // Debug records stay in the unified log only, as in the checkin's file.
  if type == .debug { return }
  let text = renderManagedLog("\(message)", args)
  let category = cryptLogCategories[ObjectIdentifier(log)] ?? "Crypt"
  let level = managedLogLevel(type)
  // Written synchronously: authorizationhost can exit or crash straight after
  // a record is logged, and a queued write would be lost with it.
  managedLogLock.lock()
  defer { managedLogLock.unlock() }
  let block = managedLogRecords(text, level: level, category: category,
                                stamp: managedLogStamp.string(from: Date()))
  appendManagedLog(block)
}

/// Formats one message as managed-log records, one per non-empty line, each
/// with the "[timestamp] LEVEL Category:" prefix, as the checkin's writer does.
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
/// String(format:). The os_log specifiers here do not match what
/// String(format:) expects: `%{public}s` is given Swift Strings, and
/// String(format:) reads `%s` as a C pointer. At login that crashed the
/// authorization plugin in strlen and locked the user out (2026-09-30). Each
/// specifier is replaced by its argument's description instead, which cannot
/// misread memory whatever the specifier says.
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

/// Appends text to the managed log with POSIX calls only. Every failure (no
/// directory, read-only volume, disk full) is ignored: this runs inside
/// authorizationhost, where a trap or an Objective-C exception from
/// FileHandle would lock the user out of the Mac. The file is opened with
/// O_APPEND for each record, so writes from the plugin and the checkin never
/// overwrite each other, and a file the checkin rolled away is recreated.
func appendManagedLog(_ text: String, path: String = managedLogPath,
                      directory: String = managedLogDirectory) {
  let bytes = Array(text.utf8)
  if bytes.isEmpty { return }
  let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW
  var fd = open(path, flags, mode_t(0o644))
  if fd < 0 && errno == ENOENT {
    makeManagedLogDirectory(directory)
    fd = open(path, flags, mode_t(0o644))
  }
  if fd < 0 { return }
  defer { _ = close(fd) }
  bytes.withUnsafeBytes { buf in
    guard let base = buf.baseAddress else { return }
    var offset = 0
    while offset < buf.count {
      let n = write(fd, base + offset, buf.count - offset)
      if n > 0 {
        offset += n
      } else if n < 0 && errno == EINTR {
        continue
      } else {
        return
      }
    }
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
