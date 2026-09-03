/*
 Crypt

 Copyright 2025 The Crypt Project.

 Licensed under the Apache License, Version 2.0 (the "License").
 See LICENSE for the full text.
 */
import ArgumentParser
import CryptCore
import Foundation

@main
enum Entry {
  static func main() async {
    await Checkin.main(LegacyArguments.translate(Array(CommandLine.arguments.dropFirst())))
  }
}

/// The single-dash flags earlier versions of Crypt accepted. The package's
/// postinstall and any administrator's script still use them, so they are
/// rewritten into their subcommand form rather than rejected.
enum LegacyArguments {
  static let map: [String: [String]] = [
    "-install": ["auth-mechs", "install"],
    "-uninstall": ["auth-mechs", "uninstall"],
    "-check-auth-mechs": ["auth-mechs", "check"],
    "-version": ["--version"],
  ]

  static func translate(_ arguments: [String]) -> [String] {
    arguments.flatMap { map[$0] ?? [$0] }
  }
}

struct Checkin: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "checkin",
    abstract: "Escrow this machine's FileVault recovery key to a Crypt server.",
    version: cryptVersion,
    subcommands: [Escrow.self, Rotate.self, Verify.self, Config.self, AuthMechsCommand.self],
    defaultSubcommand: Escrow.self
  )
}

/// Flags every subcommand accepts, controlling what reaches the managed log
/// and the terminal.
struct LoggingOptions: ParsableArguments {
  @Flag(name: [.short, .long], help: "Log debug detail as well as the usual records.")
  var verbose = false

  @Flag(name: [.short, .long], help: "Write only to the log file, not to the terminal.")
  var quiet = false

  /// Applies the flags and prepares the log file. Called at the start of every
  /// subcommand's run.
  func configureLogging() {
    if verbose {
      ManagedLog.minimumLevel = .debug
    } else if let named = prefString(.LogLevel).uppercased().nilIfEmpty {
      switch named {
      case "DEBUG": ManagedLog.minimumLevel = .debug
      case "WARN", "WARNING": ManagedLog.minimumLevel = .warning
      case "ERROR": ManagedLog.minimumLevel = .error
      default: ManagedLog.minimumLevel = .info
      }
    }
    if quiet { ManagedLog.echoToStandardOutput = false }
    ManagedLog.prepare()
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Ends the process with the code the error carries, after recording it.
func fail(_ error: Error) -> Never {
  let code: CryptExitCode
  if let cryptError = error as? CryptError {
    code = cryptError.code
  } else if error is AuthMechs.Failure {
    code = .authMechanismsMissing
  } else {
    code = .generalError
  }
  cryptLog(.error, escrowLog, "\(error)")
  Checkin.exit(withError: ExitCode(code.rawValue))
}

/// Refuses to continue when not running as root, which every command here needs.
func requireRoot() {
  guard geteuid() != 0 else { return }
  FileHandle.standardError.write(Data("checkin must be run as root\n".utf8))
  Checkin.exit(withError: ExitCode(CryptExitCode.notRoot.rawValue))
}
