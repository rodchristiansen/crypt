/*
 Crypt

 Copyright 2025 The Crypt Project.

 Licensed under the Apache License, Version 2.0 (the "License").
 See LICENSE for the full text.
 */
import Foundation

/// The record Crypt keeps about the key it holds: what fdesetup wrote when the
/// key was created, plus what checkin learned when it last escrowed.
public struct CryptData: Codable, Equatable, Sendable {
  public var serialNumber: String
  public var recoveryKey: String
  public var enabledUser: String
  public var hardwareUUID: String
  public var enabledDate: String
  public var lastRun: Date?
  public var escrowSuccess: Bool

  enum CodingKeys: String, CodingKey {
    case serialNumber = "SerialNumber"
    case recoveryKey = "RecoveryKey"
    case enabledUser = "EnabledUser"
    case hardwareUUID = "HardwareUUID"
    case enabledDate = "EnabledDate"
    case lastRun = "last_run"
    case escrowSuccess = "escrow_success"
  }

  public init(serialNumber: String = "", recoveryKey: String = "", enabledUser: String = "",
              hardwareUUID: String = "", enabledDate: String = "", lastRun: Date? = nil,
              escrowSuccess: Bool = false) {
    self.serialNumber = serialNumber
    self.recoveryKey = recoveryKey
    self.enabledUser = enabledUser
    self.hardwareUUID = hardwareUUID
    self.enabledDate = enabledDate
    self.lastRun = lastRun
    self.escrowSuccess = escrowSuccess
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber) ?? ""
    recoveryKey = try container.decodeIfPresent(String.self, forKey: .recoveryKey) ?? ""
    enabledUser = try container.decodeIfPresent(String.self, forKey: .enabledUser) ?? ""
    hardwareUUID = try container.decodeIfPresent(String.self, forKey: .hardwareUUID) ?? ""
    enabledDate = try container.decodeIfPresent(String.self, forKey: .enabledDate) ?? ""
    lastRun = try container.decodeIfPresent(Date.self, forKey: .lastRun)
    escrowSuccess = try container.decodeIfPresent(Bool.self, forKey: .escrowSuccess) ?? false
  }

  /// Reads the record fdesetup wrote at the given path.
  public static func read(from path: String) throws -> CryptData {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try PropertyListDecoder().decode(CryptData.self, from: data)
  }

  /// Writes the record back as an XML property list, readable only by root.
  public func write(to path: String) throws {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    let data = try encoder.encode(self)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }
}
