/*
 Crypt

 Copyright 2025 The Crypt Project.

 Licensed under the Apache License, Version 2.0 (the "License").
 See LICENSE for the full text.
 */
import Foundation

/// The keychain label under which the plugin stores the recovery key, and the
/// keychain it stores it in.
public let recoveryKeyLabel = "com.grahamgilbert.crypt.recovery"
public let systemKeychainPath = "/Library/Keychains/System.keychain"

/// The check-in: work out whether the machine has a recovery key that the
/// server has not seen recently, and send it.
public struct Escrow {
  let runner: CommandRunning

  public init(runner: CommandRunning = SystemCommandRunner()) {
    self.runner = runner
  }

  // MARK: - Entry point

  /// Runs one check-in. Returns whether a key was actually escrowed.
  @discardableResult
  public func run() async throws -> Bool {
    if prefBool(.ManageAuthMechs) {
      try AuthMechs.ensure(runner: runner)
    }

    let useKeychain = prefBool(.StoreRecoveryKeyInKeychain)
    let removePlist = prefBool(.RemovePlist)
    let outputPath = prefString(.OutputPath)
    let rotateUsedKey = prefBool(.RotateUsedKey)
    let validateKey = prefBool(.ValidateKey)

    if rotateUsedKey && validateKey && !removePlist {
      cryptLog(.info, escrowLog, "Checking that the current key is valid")
      try rotateInvalidKey(outputPath: outputPath, useKeychain: useKeychain)
    }

    guard var data = try loadCryptData(useKeychain: useKeychain, outputPath: outputPath) else {
      cryptLog(.info, escrowLog, "No recovery key is held on this machine, nothing to escrow")
      return false
    }

    guard escrowRequired(lastRun: data.lastRun) else { return false }

    let response = try await sendKey(data)
    let keyRotated = try handleServerRotation(response,
                                              useKeychain: useKeychain,
                                              outputPath: outputPath)

    if useKeychain {
      if !keyRotated {
        _ = setPref(key: .LastEscrow, value: Date())
      }
      return true
    }

    if !keyRotated {
      data.lastRun = Date()
      data.escrowSuccess = true
      try data.write(to: outputPath)
    }

    if removePlist {
      try? FileManager.default.removeItem(atPath: outputPath)
    }

    return true
  }

  // MARK: - Gathering the key

  /// Builds the record to escrow, either from the keychain plus live system
  /// information, or from the plist fdesetup wrote.
  public func loadCryptData(useKeychain: Bool, outputPath: String) throws -> CryptData? {
    if useKeychain {
      cryptLog(.info, escrowLog, "Configured to read the recovery key from the keychain")
      guard let key = getPasswordFromKeychain(label: recoveryKeyLabel), !key.isEmpty else {
        return nil
      }
      var data = try buildCryptData()
      data.recoveryKey = key
      return data
    }

    guard FileManager.default.fileExists(atPath: outputPath) else { return nil }
    return try CryptData.read(from: outputPath)
  }

  /// The system information that accompanies a key held in the keychain, where
  /// there is no plist to read it from.
  func buildCryptData() throws -> CryptData {
    var data = CryptData()
    data.serialNumber = DeviceInfo.serialNumber
    data.hardwareUUID = DeviceInfo.hardwareUUID

    var user = DeviceInfo.consoleUser ?? ""
    if user.isEmpty || DeviceInfo.neverEnabledUsers.contains(user) {
      user = try enabledUser()
    }
    data.enabledUser = user

    let lastEscrow = prefDate(.LastEscrow)
    if lastEscrow.timeIntervalSince1970 > 0 {
      data.lastRun = lastEscrow
    }
    return data
  }

  /// The first FileVault-enabled user that is not on the skip list.
  public func enabledUser() throws -> String {
    let skip = Set(prefArray(.SkipUsers)).union(DeviceInfo.neverEnabledUsers)
    let listed = try runner.check("/usr/bin/fdesetup", ["list"])
    for line in listed.split(separator: "\n") {
      let user = line.split(separator: ",").first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? ""
      if !user.isEmpty, !skip.contains(user) { return user }
    }
    return ""
  }

  // MARK: - Interval

  /// Whether enough time has passed since the last successful escrow.
  func escrowRequired(lastRun: Date?, now: Date = Date()) -> Bool {
    guard let lastRun, lastRun.timeIntervalSince1970 > 0 else { return true }
    let interval = TimeInterval(prefInt(.KeyEscrowInterval)) * 3600
    guard now.timeIntervalSince(lastRun) < interval else { return true }
    cryptLog(.info, escrowLog,
             "The key was escrowed less than \(prefInt(.KeyEscrowInterval)) hour(s) ago, skipping")
    return false
  }

  // MARK: - Sending

  func sendKey(_ data: CryptData) async throws -> CheckinResponse {
    cryptLog(.info, escrowLog, "Attempting to escrow the recovery key")
    let client = ServerClient(configuration: try ServerConfiguration.fromPreferences())
    let response = try await client.escrow(data)
    cryptLog(.info, escrowLog, "Key escrow successful")
    return response
  }

  // MARK: - Rotation

  /// Acts on a rotation the server asked for: the held key is discarded so the
  /// plugin generates a new one at the next login.
  func handleServerRotation(_ response: CheckinResponse,
                            useKeychain: Bool,
                            outputPath: String) throws -> Bool {
    guard prefBool(.RotateUsedKey), !prefBool(.RemovePlist) else { return false }
    if !useKeychain, !FileManager.default.fileExists(atPath: outputPath) { return false }

    var rotated = false
    if response.rotationRequired {
      cryptLog(.info, escrowLog, "The server asked for a key rotation, removing the used key")
      try removeKey(useKeychain: useKeychain, outputPath: outputPath)
      rotated = true
    }
    try runPostRunCommand(outputPath: outputPath)
    return rotated
  }

  /// Validates the key we hold and discards it when it no longer unlocks the
  /// disk, so the plugin can generate a replacement at the next login.
  func rotateInvalidKey(outputPath: String, useKeychain: Bool) throws {
    // A machine sitting at the login window has no console user; validating
    // there produced spurious failures (grahamgilbert/crypt#68).
    guard DeviceInfo.consoleUser != nil else { return }

    guard !useKeychain || getPasswordFromKeychain(label: recoveryKeyLabel) != nil else { return }
    if !useKeychain, !FileManager.default.fileExists(atPath: outputPath) { return }

    guard let key = try recoveryKey(useKeychain: useKeychain, outputPath: outputPath) else { return }
    if try validate(recoveryKey: key) { return }

    cryptLog(.warning, escrowLog, "The recovery key we hold is not valid, removing it")
    try removeKey(useKeychain: useKeychain, outputPath: outputPath)
    try runPostRunCommand(outputPath: outputPath)
    throw CryptError(.keyInvalid, "removed an invalid recovery key")
  }

  /// Asks fdesetup whether a key still unlocks the disk.
  public func validate(recoveryKey: String) throws -> Bool {
    let request = ["Password": recoveryKey]
    let plist = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
    let result = try runner.run("/usr/bin/fdesetup",
                                ["validaterecovery", "-inputplist"],
                                stdin: plist)
    let answer = result.trimmedOutput
    if answer == "true" { return true }
    if answer == "false" { return false }
    throw CryptError(.keyInvalid, "could not validate the recovery key: \(result.error)")
  }

  public func recoveryKey(useKeychain: Bool, outputPath: String) throws -> String? {
    if useKeychain {
      guard let key = getPasswordFromKeychain(label: recoveryKeyLabel), !key.isEmpty else {
        throw CryptError(.noRecoveryKey, "the recovery key is not in the keychain")
      }
      return key
    }
    return try CryptData.read(from: outputPath).recoveryKey
  }

  public func removeKey(useKeychain: Bool, outputPath: String) throws {
    if useKeychain {
      guard let keychain = getSecKeychain(path: systemKeychainPath),
            deletePasswordByLabel(inKeychain: keychain, withLabel: recoveryKeyLabel)
      else { throw CryptError(.generalError, "failed to remove the recovery key from the keychain") }
      return
    }
    try FileManager.default.removeItem(atPath: outputPath)
  }

  // MARK: - Post-run command

  /// Runs the administrator's command once the key has gone, so a machine that
  /// needs a new key can be told to log the user out or show a notification.
  func runPostRunCommand(outputPath: String) throws {
    let command: String
    switch getPref(key: .PostRunCommand) {
    case let text as String: command = text
    case let parts as [String]: command = parts.joined(separator: " ")
    default: return
    }
    guard !command.isEmpty else { return }
    guard !FileManager.default.fileExists(atPath: outputPath) else { return }

    cryptLog(.info, escrowLog, "Running the post-run command")
    _ = try runner.check(command, [outputPath])
    cryptLog(.info, escrowLog, "Post-run command successful")
  }
}
