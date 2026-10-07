/*
 Crypt

 Copyright 2025 The Crypt Project.

 Licensed under the Apache License, Version 2.0 (the "License").
 See LICENSE for the full text.
 */
import Foundation

/// The result of running an external command.
public struct CommandResult: Sendable {
  public let status: Int32
  public let standardOutput: Data
  public let standardError: Data

  public var output: String {
    String(data: standardOutput, encoding: .utf8) ?? ""
  }

  public var error: String {
    String(data: standardError, encoding: .utf8) ?? ""
  }

  public var trimmedOutput: String {
    output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum CommandError: Error, CustomStringConvertible {
  case failed(command: String, status: Int32, standardError: String)

  public var description: String {
    switch self {
    case let .failed(command, status, standardError):
      let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      return "\(command) exited \(status)" + (detail.isEmpty ? "" : ": \(detail)")
    }
  }
}

/// Runs external commands. The protocol exists so the escrow and auth-mechanism
/// code can be exercised in tests without touching the system.
public protocol CommandRunning: Sendable {
  func run(_ path: String, _ arguments: [String], stdin: Data?) throws -> CommandResult
}

extension CommandRunning {
  /// Runs a command and returns its output, treating a non-zero exit as an error.
  public func check(_ path: String, _ arguments: [String], stdin: Data? = nil) throws -> String {
    let result = try run(path, arguments, stdin: stdin)
    guard result.status == 0 else {
      throw CommandError.failed(command: path, status: result.status, standardError: result.error)
    }
    return result.output
  }

  public func run(_ path: String, _ arguments: [String]) throws -> CommandResult {
    try run(path, arguments, stdin: nil)
  }
}

/// The real runner, backed by `Process`.
public struct SystemCommandRunner: CommandRunning {
  public init() {}

  public func run(_ path: String, _ arguments: [String], stdin: Data?) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    let inPipe: Pipe? = stdin.map { _ in Pipe() }
    if let inPipe { process.standardInput = inPipe }

    try process.run()

    if let inPipe, let stdin {
      inPipe.fileHandleForWriting.write(stdin)
      inPipe.fileHandleForWriting.closeFile()
    }

    // Read before waiting so a large output cannot fill the pipe and deadlock.
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return CommandResult(status: process.terminationStatus, standardOutput: outData, standardError: errData)
  }
}
