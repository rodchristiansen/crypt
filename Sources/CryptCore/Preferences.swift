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

public let cryptBundleID = "com.grahamgilbert.crypt"

public enum Preference: String, CaseIterable, Sendable {
  case AppsAllowedToChangeKey
  case AppsAllowedToReadKey
  case GenerateNewKey
  case InvisibleInKeychain
  case KeychainUIPromptDescription
  case LastEscrow
  case OutputPath
  case RemovePlist
  case RotatedKey
  case RotateUsedKey
  case ServerURL
  case SkipUsers
  case StoreRecoveryKeyInKeychain
  case ValidateKey

  // Read by the checkin binary.
  case APIKey
  case APIKeyHeader
  case CommonNameForEscrow
  case KeyEscrowInterval
  case LogLevel
  case ManageAuthMechs
  case PostRunCommand
  case ServerRetryAttempts
  case ServerTimeout

  // Default preferences as a computed property
  public static var defaultPreferences: [Preference: Any] {
    return [
      .AppsAllowedToChangeKey: [],
      .AppsAllowedToReadKey: ["/Library/Crypt/checkin"],
      .GenerateNewKey: false,
      .InvisibleInKeychain: false,
      .KeychainUIPromptDescription: "Crypt FileVault Recovery Key",
      .LastEscrow: Date(timeIntervalSince1970: 0),
      .OutputPath: "/var/root/crypt_output.plist",
      .RemovePlist: true,
      .RotateUsedKey: true,
      .RotatedKey: false,
      .SkipUsers: [],
      .StoreRecoveryKeyInKeychain: true,
      .ValidateKey: true,
      .APIKeyHeader: "X-API-Key",
      .CommonNameForEscrow: "",
      .KeyEscrowInterval: 1,
      .LogLevel: "INFO",
      .ManageAuthMechs: true,
      .ServerRetryAttempts: 3,
      .ServerTimeout: 30
    ]
  }
}

/// The configuration file consulted after the preference domain, so a value can
/// be supplied on a machine that is not managed by a configuration profile.
public let cryptConfigPath = "/Library/Managed Encryption/config.plist"

/// Environment variable name for a preference: `ServerURL` becomes
/// `CRYPT_SERVER_URL`, matching the convention used by the Windows client.
func environmentName(for key: Preference) -> String {
  var out = ""
  for (index, character) in key.rawValue.enumerated() {
    if character.isUppercase, index > 0, !out.hasSuffix("_") {
      let previous = Array(key.rawValue)[index - 1]
      if previous.isLowercase || previous.isNumber { out.append("_") }
    }
    out.append(character)
  }
  return "CRYPT_" + out.uppercased()
}

private let configFileValues: [String: Any] = {
  guard let data = FileManager.default.contents(atPath: cryptConfigPath),
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
        let dictionary = plist as? [String: Any]
  else { return [:] }
  return dictionary
}()

/// Coerces a string drawn from the environment or the configuration file into
/// the type the default for that key implies, so callers can keep casting the
/// result to the type they expect.
public func coerce(_ value: Any, like template: Any?) -> Any {
  guard let text = value as? String else { return value }
  switch template {
  case is Bool:
    return ["1", "true", "yes", "on"].contains(text.lowercased())
  case is Int:
    return Int(text) ?? 0
  case is [String]:
    return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
  case is Date:
    return ISO8601DateFormatter().date(from: text) ?? Date(timeIntervalSince1970: 0)
  default:
    return text
  }
}

/**
 Retrieves a preference value.

 Values are resolved in the order an administrator would expect them to win:
 the process environment, then the preference domain (where a configuration
 profile takes precedence over a locally written value), then the
 configuration file at `/Library/Managed Encryption/config.plist`, and finally
 the built-in default.

 - Parameter key: The preference key to retrieve the value for.
 - Returns: The preference value, or nil if the key has no value at any layer.
 */
public func getPref(key: Preference) -> Any? {
  let fallback = Preference.defaultPreferences[key]

  if let fromEnvironment = ProcessInfo.processInfo.environment[environmentName(for: key)],
     !fromEnvironment.isEmpty {
    return coerce(fromEnvironment, like: fallback)
  }

  if let value = CFPreferencesCopyAppValue(key.rawValue as CFString, cryptBundleID as CFString) {
    return value
  }

  if let fromFile = configFileValues[key.rawValue] {
    return coerce(fromFile, like: fallback)
  }

  if let fallback {
    return fallback
  }

  cryptLog("Did not find a default for key: %{public}@, returning nil", log: prefLog, type: .debug, key.rawValue)
  return nil
}

/// Where the value for a key came from. Used by `checkin config` to explain a
/// resolved configuration rather than only printing it.
public enum PreferenceSource: String, Sendable {
  case environment = "environment"
  case profile = "configuration profile"
  case domain = "preference domain"
  case file = "configuration file"
  case builtIn = "built-in default"
  case unset = "unset"
}

/// Resolves a key the same way `getPref` does, reporting which layer answered.
public func getPrefWithSource(key: Preference) -> (value: Any?, source: PreferenceSource) {
  let fallback = Preference.defaultPreferences[key]

  if let fromEnvironment = ProcessInfo.processInfo.environment[environmentName(for: key)],
     !fromEnvironment.isEmpty {
    return (coerce(fromEnvironment, like: fallback), .environment)
  }
  if let value = CFPreferencesCopyAppValue(key.rawValue as CFString, cryptBundleID as CFString) {
    let forced = CFPreferencesAppValueIsForced(key.rawValue as CFString, cryptBundleID as CFString)
    return (value, forced ? .profile : .domain)
  }
  if let fromFile = configFileValues[key.rawValue] {
    return (coerce(fromFile, like: fallback), .file)
  }
  if let fallback {
    return (fallback, .builtIn)
  }
  return (nil, .unset)
}

// MARK: - Typed accessors

public func prefString(_ key: Preference) -> String {
  getPref(key: key) as? String ?? ""
}

public func prefBool(_ key: Preference) -> Bool {
  if let value = getPref(key: key) as? Bool { return value }
  if let number = getPref(key: key) as? NSNumber { return number.boolValue }
  return false
}

public func prefInt(_ key: Preference) -> Int {
  if let value = getPref(key: key) as? Int { return value }
  if let number = getPref(key: key) as? NSNumber { return number.intValue }
  return 0
}

public func prefArray(_ key: Preference) -> [String] {
  getPref(key: key) as? [String] ?? []
}

public func prefDate(_ key: Preference) -> Date {
  getPref(key: key) as? Date ?? Date(timeIntervalSince1970: 0)
}

/**
 Retrieves a managed preference.
 
 This function checks the specified preference domain for a managed preference.
 If a preference is found, it logs the preference and checks if it is enforced.
 
 - Parameter key: The preference key to check.
 - Returns: A tuple containing the preference value and a boolean indicating if it is enforced, or nil if no preference is found.
 */
public func getManagedPref(key: Preference) -> (Any?, Bool?) {

  cryptLog("Checking %{public}@ preference domain for managed preference.", type: .info, cryptBundleID)

  if let preference = getPref(key: key) as Any? {
    cryptLog("Found preference: %{public}@ with value: %{public}@", log: prefLog, type: .info, key.rawValue, String(describing: preference))

    if CFPreferencesAppValueIsForced(key.rawValue as CFString, cryptBundleID as CFString) {
      cryptLog("Preference %{public}@ is enforced.", log: prefLog, type: .info, key.rawValue)
      return (preference, true)
    }

    cryptLog("Preference %{public}@ is not enforced.", log: prefLog, type: .info, key.rawValue)
    return (preference, false)
  }

  cryptLog("No preference found for key: %{public}@", log: prefLog, type: .info, key.rawValue)
  return (nil, nil)
}

/// Sets a preference in the com.grahamgilbert.crypt domain
///
///
/// - Parameters:
///   - key: The string name of the key you want to set
///   - value: The value in Any that you want to set
///
/// - Returns: A Boolean of success.
public func setPref(key: Preference, value: Any) -> Bool {
  Foundation.CFPreferencesSetValue(key.rawValue as CFString, value as CFPropertyList, cryptBundleID as CFString, kCFPreferencesAnyUser, kCFPreferencesCurrentHost)

  let syncStatus = CFPreferencesAppSynchronize(cryptBundleID as CFString)

  return syncStatus
}
