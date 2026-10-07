import ArgumentParser
import CryptCore
import Foundation

/// Manages the login-window authorization mechanisms that make the Crypt
/// plugin run. The package's postinstall calls `auth-mechs install`.
struct AuthMechsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "auth-mechs",
    abstract: "Install, remove or check Crypt's login window mechanisms.",
    subcommands: [Install.self, Uninstall.self, Check.self]
  )

  struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Add Crypt's mechanisms to the authorization database.")

    @OptionGroup var logging: LoggingOptions

    func run() throws {
      requireRoot()
      logging.configureLogging()
      do { try AuthMechs.run(runner: SystemCommandRunner(), install: true) } catch { fail(error) }
    }
  }

  struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Remove Crypt's mechanisms from the authorization database.")

    @OptionGroup var logging: LoggingOptions

    func run() throws {
      requireRoot()
      logging.configureLogging()
      do { try AuthMechs.run(runner: SystemCommandRunner(), install: false) } catch { fail(error) }
    }
  }

  struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Exit 0 when the mechanisms are in place, non-zero when they are not.")

    func run() throws {
      requireRoot()
      do {
        try AuthMechs.check(runner: SystemCommandRunner())
      } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        throw ExitCode(CryptExitCode.authMechanismsMissing.rawValue)
      }
    }
  }
}
