import XCTest
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
