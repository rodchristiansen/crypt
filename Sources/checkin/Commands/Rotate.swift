import ArgumentParser
import CryptCore
import Foundation

/// Discards the key this machine holds so the authorization plugin generates a
/// replacement at the next login, then escrows the new key on the run after.
struct Rotate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rotate",
    abstract: "Discard the current recovery key so a new one is generated at the next login."
  )

  @OptionGroup var logging: LoggingOptions

  @Flag(help: "Rotate even when the key we hold still unlocks the disk.")
  var force = false

  func run() async throws {
    requireRoot()
    logging.configureLogging()

    let useKeychain = prefBool(.StoreRecoveryKeyInKeychain)
    let outputPath = prefString(.OutputPath)
    let escrow = CryptCore.Escrow()

    do {
      if !force {
        guard let key = try escrow.recoveryKey(useKeychain: useKeychain, outputPath: outputPath) else {
          throw CryptError(.noRecoveryKey, "this machine holds no recovery key to rotate")
        }
        if try escrow.validate(recoveryKey: key) {
          cryptLog(.info, escrowLog,
                   "The current key is still valid; pass --force to rotate it anyway")
          return
        }
      }
      try escrow.removeKey(useKeychain: useKeychain, outputPath: outputPath)
      // The plugin only generates a key when it finds none, so clearing the
      // marker lets it make one at the next login.
      _ = setPref(key: .RotatedKey, value: false)
      _ = setPref(key: .LastEscrow, value: Date(timeIntervalSince1970: 0))
      cryptLog(.info, escrowLog, "Removed the recovery key; a new one will be generated at the next login")
    } catch {
      fail(error)
    }
  }
}
