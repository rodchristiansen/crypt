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
import os.log

let keychainLog = OSLog(subsystem: cryptBundleID, category: "Keychain")
let filevaultLog = OSLog(subsystem: cryptBundleID, category: "Filevault")
let prefLog = OSLog(subsystem: cryptBundleID, category: "Preferences")
let enablementLog = OSLog(subsystem: cryptBundleID, category: "Enablement")
let coreLog = OSLog(subsystem: cryptBundleID, category: "Core")
let checkLog = OSLog(subsystem: cryptBundleID, category: "Check")

/// Logs a phase or outcome to both the unified log and the file log.
///
/// Use this for the lines an administrator reads to follow a login through
/// the plugin: mechanism start, FileVault status, enablement, key rotation,
/// where the key was stored, and errors. Keep plain `os_log` for chatter.
/// Never pass a secret; see `FileLog`.
///
/// - Parameters:
///   - message: The fully formatted message.
///   - log: The unified log category to write to.
///   - type: The unified log type; also decides the file level unless
///     `level` is given.
///   - level: Overrides the file level, for example to record a warning
///     where the unified log has no matching type.
func cryptLog(_ message: String, log: OSLog, type: OSLogType = .default, level: FileLogLevel? = nil) {
  os_log("%{public}@", log: log, type: type, message)
  FileLog.shared.write(message, level: level ?? FileLogLevel(type))
}
