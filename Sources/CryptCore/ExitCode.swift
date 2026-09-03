/*
 Crypt

 Copyright 2025 The Crypt Project.

 Licensed under the Apache License, Version 2.0 (the "License").
 See LICENSE for the full text.
 */

/// Exit codes the checkin binary returns. Distinct codes let a management
/// system tell a configuration problem from a server problem from a machine
/// that simply has nothing to escrow yet.
public enum CryptExitCode: Int32, Sendable {
  case success = 0
  case generalError = 1
  case notRoot = 2
  case configurationError = 3
  case noRecoveryKey = 4
  case escrowFailed = 5
  case keyInvalid = 6
  case authMechanismsMissing = 7
  case serverUnreachable = 8
}

/// An error carrying the exit code the process should end with.
public struct CryptError: Error, CustomStringConvertible {
  public let code: CryptExitCode
  public let message: String

  public init(_ code: CryptExitCode, _ message: String) {
    self.code = code
    self.message = message
  }

  public var description: String { message }
}
