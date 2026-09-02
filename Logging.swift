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

private let managedLogQueue = DispatchQueue(label: cryptBundleID + ".managedlog")

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
  let template = "\(message)"
    .replacingOccurrences(of: "%{public}", with: "%")
    .replacingOccurrences(of: "%{private}", with: "%")
  let text = args.isEmpty ? template : String(format: template, arguments: args)
  let category = cryptLogCategories[ObjectIdentifier(log)] ?? "Crypt"
  let level = managedLogLevel(type).padding(toLength: 5, withPad: " ", startingAt: 0)
  let record = "[\(managedLogStamp.string(from: Date()))] \(level) \(category): \(text)\n"
  managedLogQueue.async { appendManagedLog(record) }
}

private func appendManagedLog(_ record: String) {
  let fm = FileManager.default
  if !fm.fileExists(atPath: managedLogDirectory) {
    try? fm.createDirectory(atPath: managedLogDirectory, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o755])
  }
  if !fm.fileExists(atPath: managedLogPath) {
    fm.createFile(atPath: managedLogPath, contents: nil, attributes: [.posixPermissions: 0o644])
  }
  guard let handle = FileHandle(forWritingAtPath: managedLogPath),
        let data = record.data(using: .utf8) else { return }
  defer { handle.closeFile() }
  handle.seekToEndOfFile()
  handle.write(data)
}
