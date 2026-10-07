import ArgumentParser
import CryptCore
import Foundation

/// Reports what an administrator would otherwise have to work out by hand:
/// whether FileVault is on, whether Crypt holds a key, whether that key still
/// unlocks the disk, and when it was last escrowed.
struct Verify: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify",
    abstract: "Report the FileVault and escrow state of this machine."
  )

  @OptionGroup var logging: LoggingOptions

  @Flag(help: "Print the report as JSON.")
  var json = false

  func run() async throws {
    requireRoot()
    logging.quiet ? logging.configureLogging() : ManagedLog.prepare()

    let status = getFVEnabled()
    let useKeychain = prefBool(.StoreRecoveryKeyInKeychain)
    let outputPath = prefString(.OutputPath)
    let escrow = CryptCore.Escrow()

    var heldKey: String?
    var keyValid: Bool?
    do {
      heldKey = try escrow.recoveryKey(useKeychain: useKeychain, outputPath: outputPath)
    } catch {
      heldKey = nil
    }
    if let heldKey, !heldKey.isEmpty {
      keyValid = try? escrow.validate(recoveryKey: heldKey)
    }

    let lastEscrow = prefDate(.LastEscrow)
    let report = Report(
      serialNumber: DeviceInfo.serialNumber,
      computerName: DeviceInfo.computerName,
      osVersion: DeviceInfo.osVersionString,
      fileVaultEnabled: status.encrypted,
      decrypting: status.decrypting,
      keyStoredIn: useKeychain ? "keychain" : outputPath,
      keyPresent: !(heldKey ?? "").isEmpty,
      keyValid: keyValid,
      lastEscrow: lastEscrow.timeIntervalSince1970 > 0 ? lastEscrow : nil,
      serverURL: prefString(.ServerURL).nilIfEmpty,
      authMechanismsInstalled: (try? AuthMechs.check(runner: SystemCommandRunner())) != nil
    )

    print(json ? report.jsonText : report.text)

    if !report.keyPresent { throw ExitCode(CryptExitCode.noRecoveryKey.rawValue) }
    if report.keyValid == false { throw ExitCode(CryptExitCode.keyInvalid.rawValue) }
    if !report.authMechanismsInstalled { throw ExitCode(CryptExitCode.authMechanismsMissing.rawValue) }
  }
}

struct Report: Encodable {
  let serialNumber: String
  let computerName: String
  let osVersion: String
  let fileVaultEnabled: Bool
  let decrypting: Bool
  let keyStoredIn: String
  let keyPresent: Bool
  let keyValid: Bool?
  let lastEscrow: Date?
  let serverURL: String?
  let authMechanismsInstalled: Bool

  var text: String {
    let stamp = lastEscrow.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
    let validity = keyValid.map { $0 ? "valid" : "invalid" } ?? "not checked"
    return """
    Serial number:        \(serialNumber)
    Computer name:        \(computerName)
    macOS:                \(osVersion)
    FileVault:            \(fileVaultEnabled ? (decrypting ? "decrypting" : "on") : "off")
    Recovery key:         \(keyPresent ? "held in \(keyStoredIn)" : "none held")
    Key validity:         \(validity)
    Last escrow:          \(stamp)
    Server:               \(serverURL ?? "not configured")
    Login mechanisms:     \(authMechanismsInstalled ? "installed" : "missing")
    """
  }

  var jsonText: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(self) else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
  }
}
