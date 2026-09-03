/*
 Crypt

 Copyright 2025 The Crypt Project.

 Licensed under the Apache License, Version 2.0 (the "License").
 See LICENSE for the full text.
 */
import Foundation

/// Management of the `system.login.console` authorization right, which is what
/// makes the Crypt authorization plugin run at the login window.
public enum AuthMechs {
  /// The mechanisms Crypt installs, in the order they must appear.
  public static let required = ["Crypt:Check,privileged"]

  /// Everything Crypt has ever installed. All of it is removed before the
  /// required mechanisms are re-inserted, so an upgrade from an older version
  /// does not leave a mechanism behind that no longer exists in the bundle.
  static let obsolete = ["Crypt:Check,privileged", "Crypt:CryptGUI", "Crypt:Enablement,privileged"]

  /// The mechanism Crypt's own entries are positioned relative to.
  static let anchor = "loginwindow:done"
  static let anchorOffset = 0

  static let securityPath = "/usr/bin/security"
  static let right = "system.login.console"

  public enum Failure: Error, CustomStringConvertible {
    case notRoot
    case unreadableDatabase(String)
    case malformedDatabase
    case mechanismsMissing

    public var description: String {
      switch self {
      case .notRoot: return "only root can change the authorization database"
      case let .unreadableDatabase(detail): return "could not read \(right): \(detail)"
      case .malformedDatabase: return "the authorization database is not a property list"
      case .mechanismsMissing: return "mechanisms are not set correctly"
      }
    }
  }

  /// Reads `system.login.console` as a dictionary.
  static func read(_ runner: CommandRunning) throws -> [String: Any] {
    let result = try runner.run(securityPath, ["authorizationdb", "read", right])
    guard result.status == 0 else {
      throw Failure.unreadableDatabase(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard let plist = try? PropertyListSerialization.propertyList(
            from: result.standardOutput, options: [], format: nil),
          let dictionary = plist as? [String: Any]
    else { throw Failure.malformedDatabase }
    return dictionary
  }

  /// Removes every mechanism Crypt has ever added, then inserts the required
  /// ones immediately before the anchor. Pure, so it can be tested directly.
  static func apply(to mechanisms: [String]) -> [String] {
    var result = mechanisms.filter { !obsolete.contains($0) }
    let anchorIndex = result.firstIndex(of: anchor) ?? result.count
    result.insert(contentsOf: required, at: min(anchorIndex + anchorOffset, result.count))
    return result
  }

  /// Whether the required mechanisms already sit in the right place, which is
  /// immediately before the anchor.
  static func areCorrect(_ mechanisms: [String]) -> Bool {
    guard let anchorIndex = mechanisms.firstIndex(of: anchor) else { return false }
    let start = anchorIndex - required.count
    guard start >= 0 else { return false }
    return Array(mechanisms[start..<anchorIndex]) == required
  }

  static func mechanisms(in database: [String: Any]) -> [String] {
    database["mechanisms"] as? [String] ?? []
  }

  static func write(_ database: [String: Any], runner: CommandRunning) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: database, format: .xml, options: 0)
    let result = try runner.run(securityPath, ["authorizationdb", "write", right], stdin: data)
    guard result.status == 0 else {
      throw Failure.unreadableDatabase(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  static func requireRoot() throws {
    guard geteuid() == 0 else { throw Failure.notRoot }
  }

  /// Installs or removes Crypt's mechanisms.
  public static func run(runner: CommandRunning, install: Bool) throws {
    try requireRoot()
    var database = try read(runner)
    let current = mechanisms(in: database)
    database["mechanisms"] = install ? apply(to: current) : current.filter { !obsolete.contains($0) }
    try write(database, runner: runner)
    cryptLog(.info, authMechsLog, install ? "Installed Crypt authorization mechanisms" : "Removed Crypt authorization mechanisms")
  }

  /// Throws when the mechanisms are not in place. Used by `checkin auth-mechs check`.
  public static func check(runner: CommandRunning) throws {
    try requireRoot()
    guard areCorrect(mechanisms(in: try read(runner))) else { throw Failure.mechanismsMissing }
  }

  /// Installs the mechanisms only when they are not already correct.
  public static func ensure(runner: CommandRunning) throws {
    let database = try read(runner)
    if areCorrect(mechanisms(in: database)) { return }
    cryptLog(.info, authMechsLog, "Mechanisms are not set correctly, adding to the authorization database")
    try run(runner: runner, install: true)
  }
}
