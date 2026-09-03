import ArgumentParser
import CryptCore
import Foundation

/// The default command, and what the launch daemon runs: escrow the key this
/// machine holds, if the server has not seen it recently.
struct Escrow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "escrow",
    abstract: "Send the recovery key to the Crypt server if it is due."
  )

  @OptionGroup var logging: LoggingOptions

  @Flag(help: "Escrow even when the key was sent inside the escrow interval.")
  var force = false

  func run() async throws {
    requireRoot()
    logging.configureLogging()
    do {
      if force {
        _ = setPref(key: .LastEscrow, value: Date(timeIntervalSince1970: 0))
      }
      let escrowed = try await CryptCore.Escrow().run()
      if !escrowed {
        cryptLog(.debug, escrowLog, "Nothing to escrow on this run")
      }
    } catch {
      fail(error)
    }
  }
}
