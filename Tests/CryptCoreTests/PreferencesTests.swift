import XCTest
import Security
@testable import CryptCore

final class PreferencesTests: XCTestCase {
  func testEnvironmentNamesAreSnakeCased() {
    XCTAssertEqual(environmentName(for: .ServerURL), "CRYPT_SERVER_URL")
    XCTAssertEqual(environmentName(for: .KeyEscrowInterval), "CRYPT_KEY_ESCROW_INTERVAL")
    XCTAssertEqual(environmentName(for: .RemovePlist), "CRYPT_REMOVE_PLIST")
  }

  /// Values from the environment and the configuration file arrive as strings
  /// and have to reach callers as the type the default implies.
  func testCoercionFollowsTheDefaultsType() {
    XCTAssertEqual(coerce("true", like: false) as? Bool, true)
    XCTAssertEqual(coerce("no", like: true) as? Bool, false)
    XCTAssertEqual(coerce("4", like: 1) as? Int, 4)
    XCTAssertEqual(coerce("root, admin", like: [String]()) as? [String], ["root", "admin"])
    XCTAssertEqual(coerce("plain", like: "") as? String, "plain")
  }

  /// A value that is already typed passes through untouched.
  func testCoercionLeavesTypedValuesAlone() {
    XCTAssertEqual(coerce(7, like: 1) as? Int, 7)
    XCTAssertEqual(coerce(true, like: false) as? Bool, true)
  }

  func testEverySettingHasAnEnvironmentName() {
    for key in Preference.allCases {
      XCTAssertTrue(environmentName(for: key).hasPrefix("CRYPT_"))
    }
  }
}

final class PreferencePrecedenceTests: XCTestCase {
  private func layers(
    profile: [String: Any] = [:],
    domain: [String: Any] = [:],
    environment: [String: String] = [:],
    file: [String: Any] = [:]
  ) -> PreferenceLayers {
    PreferenceLayers(
      profile: { profile[$0] },
      domain: { domain[$0] },
      environment: environment,
      file: file
    )
  }

  /// A profile is how a fleet pins the escrow server; nothing below it may
  /// redirect the recovery key elsewhere.
  func testProfileBeatsEveryOtherLayer() {
    let resolved = resolvePref(key: .ServerURL, layers: layers(
      profile: ["ServerURL": "https://profile.example"],
      domain: ["ServerURL": "https://domain.example"],
      environment: ["CRYPT_SERVER_URL": "https://env.example"],
      file: ["ServerURL": "https://file.example"]
    ))
    XCTAssertEqual(resolved.value as? String, "https://profile.example")
    XCTAssertEqual(resolved.source, .profile)
  }

  func testEnvironmentNeverBeatsTheProfile() {
    let resolved = resolvePref(key: .ServerURL, layers: layers(
      profile: ["ServerURL": "https://profile.example"],
      environment: ["CRYPT_SERVER_URL": "https://env.example"]
    ))
    XCTAssertEqual(resolved.source, .profile)
  }

  func testDomainBeatsEnvironment() {
    let resolved = resolvePref(key: .KeyEscrowInterval, layers: layers(
      domain: ["KeyEscrowInterval": 6],
      environment: ["CRYPT_KEY_ESCROW_INTERVAL": "2"]
    ))
    XCTAssertEqual(resolved.value as? Int, 6)
    XCTAssertEqual(resolved.source, .domain)
  }

  func testEnvironmentBeatsTheFile() {
    let resolved = resolvePref(key: .KeyEscrowInterval, layers: layers(
      environment: ["CRYPT_KEY_ESCROW_INTERVAL": "2"],
      file: ["KeyEscrowInterval": "9"]
    ))
    XCTAssertEqual(resolved.value as? Int, 2)
    XCTAssertEqual(resolved.source, .environment)
  }

  func testFileBeatsTheBuiltInDefault() {
    let resolved = resolvePref(key: .KeyEscrowInterval, layers: layers(file: ["KeyEscrowInterval": "9"]))
    XCTAssertEqual(resolved.value as? Int, 9)
    XCTAssertEqual(resolved.source, .file)
  }

  func testAnEmptyEnvironmentValueFallsThrough() {
    let resolved = resolvePref(key: .KeyEscrowInterval, layers: layers(environment: ["CRYPT_KEY_ESCROW_INTERVAL": ""]))
    XCTAssertEqual(resolved.source, .builtIn)
    XCTAssertEqual(resolved.value as? Int, 1)
  }

  func testAKeyWithNoValueAnywhereIsUnset() {
    let resolved = resolvePref(key: .ServerURL, layers: layers())
    XCTAssertNil(resolved.value)
    XCTAssertEqual(resolved.source, .unset)
  }

  func testUntrustedConfigFilesAreIgnored() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("config.plist")
    try Data("<plist/>".utf8).write(to: file)
    // Written by the test user rather than root, so it must not be trusted.
    if getuid() != 0 {
      XCTAssertFalse(isTrustedConfigFile(atPath: file.path))
    }

    let link = dir.appendingPathComponent("link.plist")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertFalse(isTrustedConfigFile(atPath: link.path))

    XCTAssertFalse(isTrustedConfigFile(atPath: dir.appendingPathComponent("missing.plist").path))
  }
}

final class KeychainLookupTests: XCTestCase {
  /// A missing item must read as "not found" and stop there, rather than
  /// logging that it was missing and then that it was found.
  func testStatusesMapToOneOutcome() {
    XCTAssertEqual(KeychainLookup(status: errSecSuccess), .found)
    XCTAssertEqual(KeychainLookup(status: errSecItemNotFound), .notFound)
    XCTAssertEqual(KeychainLookup(status: errSecAuthFailed), .failed)
    XCTAssertEqual(KeychainLookup(status: errSecInteractionNotAllowed), .failed)
  }
}
